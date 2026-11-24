"""Validate an exported dataset directory without changing its contents.

Usage: python tools/validate_export.py path/to/unzipped-export
"""
import csv
import json
import math
import pathlib
import sys

TRIAL = ['trial_id','participant_id','pattern','node_timestamps','device_id','hand','posture']
SENSOR = ['trial_id','timestamp','ax','ay','az','gx','gy','gz']
WINDOW = ['trial_id','capture_mode','button_t0_monotonic','capture_start_monotonic',
          'capture_end_monotonic','actual_touch_down','actual_touch_up',
          'pre_delay_sec','window_duration_sec','window_completeness',
          'window_error','button_dispatch_delay_ms','deadline_error_ms']


def read(path, expected):
    with path.open('rb') as f:
        if f.read(3) == b'\xef\xbb\xbf':
            raise ValueError(f'{path.name}: UTF-8 BOM is forbidden')
    with path.open(newline='', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        if reader.fieldnames != expected:
            raise ValueError(f'{path.name}: header {reader.fieldnames!r} != {expected!r}')
        return list(reader)


def validate(root):
    trials = read(root / 'trials.csv', TRIAL)
    sensors = read(root / 'sensor_events.csv', SENSOR)
    ids = set()
    bounds = {}
    last = {}
    windows = {}
    metadata = root / 'fixed_window_metadata.csv'
    if metadata.exists():
        for row in read(metadata, WINDOW):
            key = row['trial_id']
            if key in windows:
                raise ValueError(f'duplicate fixed-window metadata: {key}')
            if row['capture_mode'] == 'fixed_window_v1':
                t0 = float(row['button_t0_monotonic'])
                start = float(row['capture_start_monotonic'])
                end = float(row['capture_end_monotonic'])
                if abs(start - t0 - 0.5) > 1e-6 or abs(end - start - 4.0) > 1e-6:
                    raise ValueError(f'{key}: invalid fixed-window boundaries')
                if row['window_completeness'].lower() != 'true':
                    raise ValueError(f'{key}: incomplete window in success export')
                windows[key] = (start, end)
    for row in trials:
        key = row['trial_id']
        if key in ids:
            raise ValueError(f'duplicate trial_id: {key}')
        ids.add(key)
        nodes = [int(n) for n in row['pattern'].split('-')]
        times = json.loads(row['node_timestamps'])
        if not 4 <= len(nodes) <= 9 or len(set(nodes)) != len(nodes):
            raise ValueError(f'{key}: invalid actual pattern')
        if len(nodes) != len(times) or any(b <= a for a, b in zip(times, times[1:])):
            raise ValueError(f'{key}: node time count/order')
        bounds[key] = times
    for row in sensors:
        key = row['trial_id']
        if key not in ids:
            raise ValueError(f'orphan sensor row: {key}')
        values = [float(row[k]) for k in SENSOR[1:]]
        if not all(math.isfinite(v) for v in values):
            raise ValueError(f'{key}: non-finite sensor value')
        if key in last and values[0] < last[key]:
            raise ValueError(f'{key}: decreasing sensor timestamp')
        if key in windows and not windows[key][0] <= values[0] < windows[key][1]:
            raise ValueError(f'{key}: sensor timestamp outside fixed window')
        last[key] = values[0]
    if windows and set(windows) != ids:
        raise ValueError('fixed-window metadata trial IDs differ from trials.csv')
    if set(last) != ids:
        raise ValueError('sensor and trial ID sets differ')
    print(f'OK: {len(trials)} trial rows, {len(sensors)} sensor rows, exact headers and numeric values')
    print('Note: physical clock alignment and sensor quality still require a real-device review.')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    validate(pathlib.Path(sys.argv[1]))
