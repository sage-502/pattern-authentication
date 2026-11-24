"""Evaluate a shared threshold for enrollable, per-user motion templates."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.preprocessing import RobustScaler

from authentication_policy import FIXED_THRESHOLD
from evaluate_fixed_threshold import read_trials, features_for_trial, eer, counts


def load_features(archive: Path, enroll_count: int = 25,
                  tune_count: int = 10) -> tuple[pd.DataFrame, list[str]]:
    trials, meta, sensors = read_trials(archive)
    if trials.trial_id.duplicated().any() or meta.trial_id.duplicated().any():
        raise ValueError("Duplicate trial IDs")
    merged = trials.merge(meta, on="trial_id", validate="one_to_one")
    if merged.pattern.nunique() != 1 or merged.device_id.nunique() != 1:
        raise ValueError("One pattern and one device required")
    sensor_groups = {key: part for key, part in sensors.groupby("trial_id", sort=False)}
    rows = []
    excluded = []
    for record in merged.itertuples():
        try:
            features = features_for_trial(sensor_groups[record.trial_id],
                                          record.actual_touch_down, record.actual_touch_up)
            rows.append({"trial_id": record.trial_id, "participant_id": record.participant_id,
                         **features})
        except (ValueError, KeyError) as error:
            excluded.append({"trial_id": record.trial_id, "reason": str(error)})
    if excluded:
        raise ValueError(f"Cannot compare users with missing trials: {excluded}")
    frame = pd.DataFrame(rows).sort_values("trial_id").reset_index(drop=True)
    order = frame.groupby("participant_id").cumcount()
    if any(frame.groupby("participant_id").size() != 50):
        raise ValueError("Expected 50 valid trials per participant")
    if enroll_count < 2 or tune_count < 1 or enroll_count + tune_count >= 50:
        raise ValueError("Invalid enrollment/tuning counts for 50 trials")
    frame["partition"] = np.where(order < enroll_count, "enroll",
                                  np.where(order < enroll_count + tune_count, "tune", "test"))
    columns = [col for col in frame if col not in ("trial_id", "participant_id", "partition")]
    return frame, columns


def template_scores(frame: pd.DataFrame, columns: list[str],
                    feature_set: list[str]) -> dict[str, tuple[np.ndarray, np.ndarray, dict]]:
    """Score each claimed user with only their own 25-trial template.

    A generic scaler is learned from the other three users' enrollment trials;
    the target user's enrollment data only defines that user's template.
    """
    by_partition = {part: [] for part in ("tune", "test")}
    users = sorted(frame.participant_id.unique())
    for user in users:
        enroll_other = frame[(frame.partition == "enroll") & (frame.participant_id != user)]
        enroll_user = frame[(frame.partition == "enroll") & (frame.participant_id == user)]
        scaler = RobustScaler().fit(enroll_other[feature_set])
        own = scaler.transform(enroll_user[feature_set])
        center = np.median(own, axis=0)
        spread = np.maximum(np.median(np.abs(own-center), axis=0)*1.4826, 0.25)
        for part in by_partition:
            subset = frame[frame.partition == part]
            x = scaler.transform(subset[feature_set])
            distance = np.sqrt(np.mean(((x-center)/spread)**2, axis=1))
            score = -distance
            genuine = subset.participant_id.to_numpy() == user
            by_partition[part].append((score, genuine, user))
    result = {}
    for part, values in by_partition.items():
        result[part] = (np.concatenate([v[0] for v in values]),
                        np.concatenate([v[1] for v in values]),
                        {user: (score, genuine) for score, genuine, user in values})
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--enroll-count", type=int, default=25)
    parser.add_argument("--tune-count", type=int, default=10)
    parser.add_argument("--threshold", type=float, default=FIXED_THRESHOLD,
                        help="Fixed approval threshold; default is the prototype policy")
    args = parser.parse_args()
    frame, columns = load_features(args.archive, args.enroll_count, args.tune_count)
    # A fixed, interpretable subset. No feature selection on tune or test data.
    selected = [c for c in columns if c == "duration" or
                (c.startswith("all_") and c.endswith(("_mean", "_std", "_delta")))]
    scores = template_scores(frame, columns, selected)
    threshold = float(args.threshold)
    output = {"protocol": f"{args.enroll_count} enroll, {args.tune_count} threshold tune, "
              f"{50-args.enroll_count-args.tune_count} untouched test per user; one attempt",
              "score": "negative RMS standardized distance from claimant's enrollment median template",
              "feature_count": len(selected), "features": selected,
              "users": sorted(frame.participant_id.unique()),
              "applied_fixed_threshold": threshold,
              "tune_eer_diagnostic_only": eer(*scores["tune"][:2]),
              "tune": counts(*scores["tune"][:2], threshold),
              "test": counts(*scores["test"][:2], threshold),
              "test_by_claimant": {user: counts(*pair, threshold)
                                   for user, pair in scores["test"][2].items()},
              "test_eer_diagnostic_only": eer(*scores["test"][:2])}
    output["per_user_thresholds"] = {}
    for user in output["users"]:
        tune_pair = scores["tune"][2][user]
        test_pair = scores["test"][2][user]
        chosen = eer(*tune_pair)
        output["per_user_thresholds"][user] = {
            "threshold_selection": chosen,
            "tune": counts(*tune_pair, chosen["threshold"]),
            "test": counts(*test_pair, chosen["threshold"]),
        }
    output["per_user_thresholds_pooled_test"] = {
        key: sum(output["per_user_thresholds"][user]["test"][key]
                 for user in output["users"])
        for key in ("fp", "impostor", "fn", "genuine")
    }
    serialized = json.dumps(output, ensure_ascii=False, indent=2)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(serialized, encoding="utf-8")
    print(serialized)


if __name__ == "__main__":
    main()
