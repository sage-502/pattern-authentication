"""Full-trial calibration, coordinate alignment, denoising, and gravity separation."""

from __future__ import annotations

import math

import numpy as np
import pandas as pd
from scipy.signal import butter, sosfiltfilt


RAW_AXES = ["ax", "ay", "az", "gx", "gy", "gz"]
MODEL_CHANNELS = ["ax", "ay", "az", "lax", "lay", "laz", "fgx", "fgy", "fgz"]
SAMPLE_RATE = 100.0
NOISE_CUTOFF_HZ = 20.0
GRAVITY_CUTOFF_HZ = 0.5
DEFAULT_BASELINE_DELAY_SECONDS = 0.2
DEFAULT_BASELINE_SECONDS = 0.3


def screen_gravity_rotation(gravity_vector: np.ndarray) -> np.ndarray:
    """Build a right-handed screen/gravity frame from an idle gravity vector.

    Z follows gravity. X is the phone screen's +X axis projected onto the
    gravity-orthogonal plane, and Y completes the right-handed frame. This
    fixes all three axes for screen-relative pattern inference without needing
    magnetic north.
    """
    vector = np.asarray(gravity_vector, dtype=float)
    norm = float(np.linalg.norm(vector))
    if norm < 1e-9:
        return np.eye(3)
    z_axis = vector / norm
    phone_x = np.asarray([1.0, 0.0, 0.0])
    x_projected = phone_x - float(np.dot(phone_x, z_axis)) * z_axis
    x_norm = float(np.linalg.norm(x_projected))
    if x_norm < 1e-6:
        # The phone X axis is almost vertical. Preserve the projected screen Y
        # direction instead, then recover X so that X cross Y equals Z.
        phone_y = np.asarray([0.0, 1.0, 0.0])
        y_projected = phone_y - float(np.dot(phone_y, z_axis)) * z_axis
        y_norm = float(np.linalg.norm(y_projected))
        if y_norm < 1e-6:
            return np.eye(3)
        y_axis = y_projected / y_norm
        x_axis = np.cross(y_axis, z_axis)
        x_axis /= np.linalg.norm(x_axis)
    else:
        x_axis = x_projected / x_norm
        y_axis = np.cross(z_axis, x_axis)
        y_axis /= np.linalg.norm(y_axis)
    # Rows are the new basis vectors expressed in the Android body frame.
    return np.vstack((x_axis, y_axis, z_axis))


def baseline_bounds(
    frame: pd.DataFrame,
    baseline_start: float | None = None,
    baseline_end: float | None = None,
) -> tuple[float, float]:
    start = (
        float(frame.timestamp.min()) + DEFAULT_BASELINE_DELAY_SECONDS
        if baseline_start is None else float(baseline_start)
    )
    end = min(float(frame.timestamp.max()), start + DEFAULT_BASELINE_SECONDS) if baseline_end is None else float(baseline_end)
    if end <= start:
        raise ValueError("Baseline end must be later than baseline start")
    return start, end


def calibration_report(
    frame: pd.DataFrame,
    baseline_start: float | None = None,
    baseline_end: float | None = None,
) -> dict[str, object]:
    """Summarize the idle baseline used for calibration and quality control."""
    start, end = baseline_bounds(frame, baseline_start, baseline_end)
    idle = frame[(frame.timestamp >= start) & (frame.timestamp <= end)]
    if len(idle) < 5:
        raise ValueError(f"Baseline contains only {len(idle)} sensor rows")
    acc = idle[["ax", "ay", "az"]].to_numpy(float)
    gyro = idle[["gx", "gy", "gz"]].to_numpy(float)
    gravity = np.median(acc, axis=0)
    rotation = screen_gravity_rotation(gravity)
    noise = np.std(np.column_stack((acc, gyro)), axis=0)
    full = frame[RAW_AXES].to_numpy(float)
    signal_power = np.var(full, axis=0)
    noise_power = np.maximum(noise ** 2, 1e-12)
    snr_db = 10.0 * np.log10(np.maximum(signal_power, 1e-12) / noise_power)
    return {
        "baseline_start": start,
        "baseline_end": end,
        "baseline_rows": int(len(idle)),
        "gravity_vector": gravity.tolist(),
        "gravity_magnitude": float(np.linalg.norm(gravity)),
        "screen_gravity_rotation": rotation.tolist(),
        "aligned_axes_in_body_frame": {
            "x": rotation[0].tolist(), "y": rotation[1].tolist(), "z": rotation[2].tolist(),
        },
        "gyro_bias": np.median(gyro, axis=0).tolist(),
        "axis_noise_std": dict(zip(RAW_AXES, noise.tolist())),
        "axis_snr_db": dict(zip(RAW_AXES, snr_db.tolist())),
    }


def _safe_lowpass(values: np.ndarray, cutoff: float, order: int, sample_rate: float) -> np.ndarray:
    if len(values) < 8 or not np.all(np.isfinite(values)):
        return values.copy()
    sos = butter(order, cutoff, btype="lowpass", fs=sample_rate, output="sos")
    try:
        return sosfiltfilt(sos, values)
    except ValueError:
        return values.copy()


def resample_trial(frame: pd.DataFrame, sample_rate: float = SAMPLE_RATE) -> pd.DataFrame:
    required = {"timestamp", *RAW_AXES}
    missing = required - set(frame.columns)
    if missing:
        raise ValueError(f"Sensor frame is missing columns: {sorted(missing)}")
    ordered = frame.sort_values("timestamp").groupby("timestamp", as_index=False)[RAW_AXES].mean()
    if len(ordered) < 5:
        raise ValueError("A trial needs at least 5 sensor rows")
    start, end = float(ordered.timestamp.iloc[0]), float(ordered.timestamp.iloc[-1])
    if not math.isfinite(start) or not math.isfinite(end) or end <= start:
        raise ValueError("Invalid trial timestamp range")
    count = max(5, int(round((end - start) * sample_rate)) + 1)
    timeline = np.linspace(start, end, count)
    source_time = ordered.timestamp.to_numpy(float)
    result = {"timestamp": timeline}
    for axis in RAW_AXES:
        result[axis] = np.interp(timeline, source_time, ordered[axis].to_numpy(float))
    return pd.DataFrame(result)


def preprocess_trial(
    frame: pd.DataFrame,
    sample_rate: float = SAMPLE_RATE,
    noise_cutoff: float = NOISE_CUTOFF_HZ,
    gravity_cutoff: float = GRAVITY_CUTOFF_HZ,
    baseline_start: float | None = None,
    baseline_end: float | None = None,
) -> pd.DataFrame:
    """Align gravity, remove idle gyro bias, filter, and separate gravity."""
    derived = MODEL_CHANNELS + ["fax", "fay", "faz", "gravity_x", "gravity_y", "gravity_z"]
    if set(derived).issubset(frame.columns):
        return frame.sort_values("timestamp").reset_index(drop=True)
    result = resample_trial(frame, sample_rate)
    start, end = baseline_bounds(result, baseline_start, baseline_end)
    idle = result[(result.timestamp >= start) & (result.timestamp <= end)]
    if len(idle) < 5:
        raise ValueError(f"Baseline contains only {len(idle)} resampled rows")
    gravity_vector = np.median(idle[["ax", "ay", "az"]].to_numpy(float), axis=0)
    gyro_bias = np.median(idle[["gx", "gy", "gz"]].to_numpy(float), axis=0)
    rotation = screen_gravity_rotation(gravity_vector)
    result[["ax", "ay", "az"]] = result[["ax", "ay", "az"]].to_numpy(float) @ rotation.T
    result[["gx", "gy", "gz"]] = (result[["gx", "gy", "gz"]].to_numpy(float) - gyro_bias) @ rotation.T
    for axis in ["ax", "ay", "az"]:
        suffix = axis[-1]
        filtered = _safe_lowpass(result[axis].to_numpy(float), noise_cutoff, 4, sample_rate)
        gravity = _safe_lowpass(filtered, gravity_cutoff, 2, sample_rate)
        result[f"f{axis}"] = filtered
        result[f"gravity_{suffix}"] = gravity
        result[f"l{axis}"] = filtered - gravity
    for axis in ["gx", "gy", "gz"]:
        result[f"f{axis}"] = _safe_lowpass(result[axis].to_numpy(float), noise_cutoff, 4, sample_rate)
    return result


def preprocessing_metadata() -> dict:
    return {
        "sample_rate": SAMPLE_RATE,
        "model_channels": MODEL_CHANNELS,
        "noise_filter": {"type": "butterworth", "order": 4, "cutoff_hz": NOISE_CUTOFF_HZ},
        "gravity_filter": {"type": "butterworth", "order": 2, "cutoff_hz": GRAVITY_CUTOFF_HZ},
        "baseline_seconds": DEFAULT_BASELINE_SECONDS,
        "baseline_delay_seconds": DEFAULT_BASELINE_DELAY_SECONDS,
        "coordinate_alignment": {
            "type": "screen_gravity_frame",
            "z_axis": "idle gravity vector",
            "x_axis": "phone screen +X projected onto the gravity-orthogonal plane",
            "y_axis": "right-handed cross product Z x X",
            "fallback": "projected phone screen +Y when screen +X is nearly parallel to gravity",
        },
        "gyro_bias": "idle-window median removed before filtering",
    }
