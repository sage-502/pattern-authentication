"""Tune claimant-aware feature weighting on one-pattern, one-device trials.

The last five trials per person are never used for model or threshold selection.
This experiment is separate from the app's touch_v3 DTW score.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
from sklearn.preprocessing import RobustScaler

from evaluate_enrollment_threshold import load_features
from evaluate_fixed_threshold import counts, eer


def pooled(parts):
    return np.concatenate([x[1] for x in parts]), np.concatenate([x[2] for x in parts])


def score_all(frame, features, strength, cap):
    users = sorted(frame.participant_id.unique())
    result = {"tune": [], "test": []}
    weights_out = {}
    for user in users:
        own = frame[(frame.partition == "enroll") & (frame.participant_id == user)]
        others = frame[(frame.partition == "enroll") & (frame.participant_id != user)]
        train = frame[frame.partition == "enroll"]
        scaler = RobustScaler().fit(train[features])
        a = scaler.transform(own[features])
        b = scaler.transform(others[features])
        center = np.median(a, axis=0)
        within = np.maximum(1.4826 * np.median(np.abs(a-center), axis=0), 0.25)
        # A feature is useful only when the impostor center is separated from
        # the claimant, relative to the spread of both groups.
        other_center = np.median(b, axis=0)
        other_spread = 1.4826 * np.median(np.abs(b-other_center), axis=0)
        separation = np.abs(other_center-center) / np.maximum(within+other_spread, 0.25)
        rank = np.argsort(np.argsort(separation)).astype(float) / max(1, len(features)-1)
        weight = np.minimum(np.sqrt(1+strength*rank), cap)
        weights_out[user] = dict(zip(features, weight.tolist()))
        for part in result:
            subset = frame[frame.partition == part]
            x = scaler.transform(subset[features])
            distance = np.sqrt(np.mean((weight*(x-center)/within)**2, axis=1))
            truth = subset.participant_id.to_numpy() == user
            result[part].append((user, -distance, truth))
    return result, weights_out


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("archive", type=Path)
    p.add_argument("--out", type=Path)
    args = p.parse_args()
    frame, columns = load_features(args.archive, enroll_count=40, tune_count=5)
    features = [c for c in columns if c == "duration" or
                (c.startswith("all_") and c.endswith(("_mean", "_std", "_delta")))]
    candidates = []
    for strength in (0, 0.5, 1, 2, 4, 8):
        scored, weights = score_all(frame, features, strength, cap=3)
        threshold = eer(*pooled(scored["tune"]))
        candidates.append((strength, threshold, scored, weights))
    # Pick on tune only; zero weight is preferred on ties.
    best = min(candidates, key=lambda c: (c[1]["eer_midpoint"],
                                          c[1]["fpr"]+c[1]["fnr"], c[0]))
    strength, selection, scored, weights = best
    threshold = selection["threshold"]
    out = {
        "protocol": "same pattern/device, 40 enroll + 5 tune + 5 untouched test per user",
        "score": "negative weighted robust distance; distinct from app touch_v3 DTW",
        "features": features, "chosen_strength": strength, "threshold": threshold,
        "tune": counts(*pooled(scored["tune"]), threshold),
        "test": counts(*pooled(scored["test"]), threshold),
        "test_by_claimant": {u: counts(s, g, threshold) for u,s,g in scored["test"]},
        "weights_by_claimant": weights,
        "candidates": [{"strength": s, "tune_eer": e["eer_midpoint"],
                        "tune": counts(*pooled(v["tune"]), e["threshold"]),
                        "test_at_tune_threshold": counts(*pooled(v["test"]), e["threshold"])}
                       for s,e,v,_ in candidates],
    }
    if args.out:
        args.out.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({k:out[k] for k in ("chosen_strength","threshold","tune","test","test_by_claimant","candidates")}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
