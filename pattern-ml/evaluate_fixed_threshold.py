"""Evaluate a pooled, one-attempt threshold for a fixed pattern and device."""

from __future__ import annotations

import argparse
import io
import json
import sys
import zipfile
from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.linear_model import LogisticRegression
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import RobustScaler

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sensor_preprocessing import preprocess_trial


AXES = ("lax", "lay", "laz", "fgx", "fgy", "fgz")


def read_trials(archive: Path) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    parts = []
    with zipfile.ZipFile(archive) as outer:
        for name in outer.namelist():
            if not name.endswith(".zip"):
                continue
            with zipfile.ZipFile(io.BytesIO(outer.read(name))) as inner:
                frames = [pd.read_csv(inner.open(file), dtype={"trial_id": str})
                          for file in ("trials.csv", "fixed_window_metadata.csv", "sensor_events.csv")]
                parts.append(frames)
    if len(parts) < 2:
        raise ValueError("Expected multiple participant exports")
    return tuple(pd.concat([item[i] for item in parts], ignore_index=True) for i in range(3))


def features_for_trial(raw: pd.DataFrame, down: float, up: float) -> dict[str, float]:
    frame = preprocess_trial(raw)
    row: dict[str, float] = {}
    for label, start, end in (("all", down, up),
                              ("early", down, down + (up-down)/3),
                              ("middle", down + (up-down)/3, down + 2*(up-down)/3),
                              ("late", down + 2*(up-down)/3, up)):
        window = frame[(frame.timestamp >= start) & (frame.timestamp <= end)]
        if len(window) < 5:
            raise ValueError("Too few sensor events during touch")
        for axis in AXES:
            values = window[axis].to_numpy(float)
            row[f"{label}_{axis}_mean"] = float(values.mean())
            row[f"{label}_{axis}_std"] = float(values.std())
            row[f"{label}_{axis}_delta"] = float(values[-1]-values[0])
        for prefix, axes in (("acc", AXES[:3]), ("gyro", AXES[3:])):
            mag = np.linalg.norm(window[list(axes)].to_numpy(float), axis=1)
            row[f"{label}_{prefix}_mag_mean"] = float(mag.mean())
            row[f"{label}_{prefix}_mag_std"] = float(mag.std())
    row["duration"] = float(up-down)
    return row


def eer(scores: np.ndarray, genuine: np.ndarray) -> dict:
    highest_impostor = float(np.max(scores[~genuine]))
    lowest_genuine = float(np.min(scores[genuine]))
    if highest_impostor < lowest_genuine:
        threshold = (highest_impostor + lowest_genuine) / 2
        return {"threshold": threshold, "fpr": 0.0, "fnr": 0.0,
                "eer_midpoint": 0.0, "zero_error_interval":
                [highest_impostor, lowest_genuine]}
    thresholds = np.r_[-np.inf, np.unique(scores), np.inf]
    fpr = np.array([np.mean(scores[~genuine] >= t) for t in thresholds])
    fnr = np.array([np.mean(scores[genuine] < t) for t in thresholds])
    index = int(np.argmin(np.abs(fpr-fnr)))
    threshold = float(thresholds[index])
    return {"threshold": threshold, "fpr": float(fpr[index]), "fnr": float(fnr[index]),
            "eer_midpoint": float((fpr[index]+fnr[index])/2)}


def counts(scores: np.ndarray, genuine: np.ndarray, threshold: float) -> dict:
    accepted = scores >= threshold
    fp = int(np.sum(accepted & ~genuine))
    fn = int(np.sum(~accepted & genuine))
    return {"fp": fp, "impostor": int(np.sum(~genuine)), "fpr": fp/int(np.sum(~genuine)),
            "fn": fn, "genuine": int(np.sum(genuine)), "fnr": fn/int(np.sum(genuine))}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    trials, meta, sensors = read_trials(args.archive)
    if trials.trial_id.duplicated().any() or meta.trial_id.duplicated().any():
        raise ValueError("Duplicate trial IDs")
    merged = trials.merge(meta, on="trial_id", validate="one_to_one")
    if merged.pattern.nunique() != 1 or merged.device_id.nunique() != 1:
        raise ValueError("Expected one pattern and one device")
    sensor_groups = {key: part for key, part in sensors.groupby("trial_id", sort=False)}
    records = []
    failures = []
    for record in merged.itertuples():
        try:
            values = features_for_trial(sensor_groups[record.trial_id],
                                        record.actual_touch_down, record.actual_touch_up)
            records.append({"trial_id": record.trial_id, "participant_id": record.participant_id,
                            **values})
        except (ValueError, KeyError) as error:
            failures.append({"trial_id": record.trial_id, "reason": str(error)})
    frame = pd.DataFrame(records).sort_values("trial_id")
    users = sorted(frame.participant_id.unique())
    if len(users) != 4:
        raise ValueError(f"Expected four users; got {users}")
    order = frame.groupby("participant_id").cumcount()
    frame["partition"] = np.where(order < 25, "enroll", np.where(order < 35, "tune", "test"))
    frame = frame[order < 50]
    columns = [col for col in frame if col not in ("trial_id", "participant_id", "partition")]
    enroll = frame[frame.partition == "enroll"]
    model = make_pipeline(RobustScaler(), LogisticRegression(
        class_weight="balanced", max_iter=5000, C=0.1, random_state=42))
    model.fit(enroll[columns], enroll.participant_id)
    result = {"users": users, "pattern": str(merged.pattern.iloc[0]),
              "device": str(merged.device_id.iloc[0]), "counts_by_user_partition":
              frame.groupby(["participant_id", "partition"]).size().unstack(fill_value=0).to_dict("index"),
              "excluded": failures, "model": "RobustScaler + multinomial logistic regression C=0.1",
              "note": "One score for every claimed identity per trial; accept when score >= common threshold."}
    scoring = {}
    for partition in ("tune", "test"):
        subset = frame[frame.partition == partition]
        probabilities = model.predict_proba(subset[columns])
        scores = probabilities.ravel()
        truth = (np.asarray(model.classes_)[None, :] == subset.participant_id.to_numpy()[:, None]).ravel()
        scoring[partition] = (scores, truth, subset, probabilities)
    threshold_result = eer(*scoring["tune"][:2])
    result["threshold_selection"] = threshold_result
    result["tune"] = counts(*scoring["tune"][:2], threshold_result["threshold"])
    result["test"] = counts(*scoring["test"][:2], threshold_result["threshold"])
    test_scores, _, test_frame, test_probas = scoring["test"]
    result["test_by_user"] = {}
    for user_index, user in enumerate(model.classes_):
        genuine = test_frame.participant_id.to_numpy() == user
        result["test_by_user"][str(user)] = counts(test_probas[:, user_index], genuine,
                                                       threshold_result["threshold"])
    result["test_oracle_eer_for_diagnostic_only"] = eer(*scoring["test"][:2])
    serialized = json.dumps(result, ensure_ascii=False, indent=2)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(serialized, encoding="utf-8")
    print(serialized)


if __name__ == "__main__":
    main()
