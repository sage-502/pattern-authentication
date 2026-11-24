"""Experimental one-attempt authentication policy for the fixed-pattern prototype.

The threshold is calibrated for the negative standardized RMS template distance
used by evaluate_enrollment_threshold.py with 40 enrollment trials per user.
"""

FIXED_THRESHOLD = -1.403977504364883


def is_accepted(score: float, threshold: float = FIXED_THRESHOLD) -> bool:
    """Accept exactly when the claimant's template score meets the threshold."""
    return float(score) >= float(threshold)
