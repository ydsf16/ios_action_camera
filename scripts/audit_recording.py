#!/usr/bin/env python3
"""Read-only audit of MotionCam v1 data. Does not estimate or apply visual offset."""
import argparse
import csv
import json
import math
from pathlib import Path
import shutil
import statistics
import subprocess


def audit(directory, probe=True):
    directory = Path(directory)
    manifest = json.loads((directory / 'manifest.json').read_text())
    errors, warnings = [], []
    report = {'id': manifest['id'], 'status': manifest['status'], 'errors': errors, 'warnings': warnings}

    def rows(name):
        with (directory / name).open(newline='') as stream:
            return list(csv.DictReader(stream))

    def numeric(values, label):
        if not all(math.isfinite(v) for v in values):
            errors.append(f'{label}: non-finite values')
            return False
        return True

    def monotonic(values, label):
        if not numeric(values, label):
            return False
        if any(b <= a for a, b in zip(values, values[1:])):
            errors.append(f'{label}: duplicate or decreasing timestamps')
            return False
        return True

    frames = rows('frames.csv')
    if not frames:
        errors.append('No encoded video frames logged')
        return report
    if manifest['status'] != 'complete':
        errors.append('Recording did not complete; preserve partial files for diagnosis')
    if manifest['videoFrames'] != len(frames):
        errors.append('Manifest/video CSV frame count mismatch')
    pts = [int(r['pts_value']) / int(r['pts_timescale']) for r in frames]
    host = [float(r['host_sec']) for r in frames]
    video = [float(r['video_sec']) for r in frames]
    for values, label in [(pts, 'video source PTS'), (host, 'video host time'), (video, 'video relative time')]:
        monotonic(values, label)
    first = manifest['firstVideoPTS']
    origin = first['value'] / first['timescale']
    if abs(origin - pts[0]) > 1e-6:
        errors.append('Manifest first PTS does not match first encoded frame')
    if abs(manifest['firstVideoHostSeconds'] - host[0]) > 1e-6:
        errors.append('Manifest host origin does not match first frame')
    if any(abs((t - origin) - v) > 1e-6 for t, v in zip(pts, video)):
        errors.append('Video CSV was not rebased from the common writer origin')
    report['video_frames'] = len(frames)
    report['video_span_sec'] = video[-1] - video[0]
    report['video_max_gap_ms'] = max((b-a for a,b in zip(video, video[1:])), default=0) * 1000
    keys = [f'k{r}{c}' for r in range(3) for c in range(3)]
    report['frames_with_intrinsics'] = sum(all(math.isfinite(float(r[k])) for k in keys) for r in frames)
    if report['frames_with_intrinsics'] != len(frames):
        warnings.append('Intrinsic matrix missing for some frames')
    if any(int(r['stabilization_active']) != 0 for r in frames):
        errors.append('System video stabilization was active')

    # Fit recorded clock pairs only. This is not a visual/gyro sync correction.
    if len(frames) > 1 and all(math.isfinite(v) for v in host + video):
        x = [v - host[0] for v in host]
        mx, my = statistics.mean(x), statistics.mean(video)
        den = sum((v-mx)**2 for v in x)
        if den > 0:
            slope = sum((a-mx)*(b-my) for a,b in zip(x,video)) / den
            offset = my - slope * mx
            residuals = [b - (offset + slope*a) for a,b in zip(x,video)]
            report['recorded_host_to_video_rate_ppm'] = (slope - 1) * 1e6
            report['clock_fit_max_residual_us'] = max(abs(r) for r in residuals) * 1e6
            if report['clock_fit_max_residual_us'] > 1000:
                warnings.append('Clock-pair fit residual exceeds 1 ms; inspect clock mapping')

    for name, counter in [('gyro', 'gyroSamples'), ('accelerometer', 'accelerometerSamples'), ('gravity', 'gravitySamples')]:
        stream = rows(name + '.csv')
        times = [float(r['host_sec']) for r in stream]
        if not times:
            errors.append(f'{name}: empty stream')
            continue
        valid = monotonic(times, name)
        if len(times) != manifest[counter]:
            errors.append(f'{name}: manifest sample count mismatch')
        gaps = [b-a for a,b in zip(times,times[1:])]
        report[name] = {'samples': len(times), 'covers_video': times[0] <= host[0] and times[-1] >= host[-1],
                        'max_gap_ms': max(gaps, default=0) * 1000}
        if valid and gaps:
            report[name]['median_hz'] = 1 / statistics.median(gaps)
        if not report[name]['covers_video']:
            errors.append(f'{name}: does not cover first/last video frame')
        if max(gaps, default=0) > 0.05:
            warnings.append(f'{name}: sampling gap exceeds 50 ms')
        for row in stream:
            if not numeric([float(v) for v in row.values()], name):
                break

    audio = rows('audio.csv')
    report['audio_buffers'] = len(audio)
    if not audio:
        errors.append('No recorded audio')
    else:
        monotonic([int(r['pts_value']) / int(r['pts_timescale']) for r in audio], 'audio PTS')
        if len(audio) != manifest['audioBuffers']:
            errors.append('Audio CSV count mismatch')
        if any(abs(int(r['pts_value']) / int(r['pts_timescale']) - origin - float(r['video_sec'])) > 1e-6 for r in audio):
            errors.append('Audio uses a different origin from video')
    drops = rows('drops.csv')
    report['dropped_video_frames'] = sum(r['stream'] == 'video' for r in drops)
    if report['dropped_video_frames'] != manifest['droppedVideoFrames']:
        errors.append('Dropped video count mismatch')
    if drops:
        warnings.append('Capture/encoder drops were logged; inspect drops.csv')

    movie = directory / 'video.mov'
    if not movie.is_file():
        errors.append('Final video.mov is missing')
    elif probe and shutil.which('ffprobe'):
        command = ['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_packets',
                   '-show_entries', 'packet=pts_time', '-of', 'json', str(movie)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=60, check=True)
        packets = json.loads(result.stdout)['packets']
        encoded = [float(p['pts_time']) for p in packets]
        report['encoded_video_packets'] = len(encoded)
        if len(encoded) != len(video):
            errors.append('Movie packet count does not match accepted-frame CSV')
        elif encoded:
            delta = max(abs(a-b) for a,b in zip(encoded,video))
            report['movie_vs_logged_pts_max_error_us'] = delta * 1e6
            if delta > 5e-6:
                errors.append('Movie PTS does not match logged video timeline within 5 microseconds')
    else:
        warnings.append('ffprobe not run; encoded movie timestamps have not been checked')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--no-probe', action='store_true')
    args = parser.parse_args()
    try:
        result = audit(args.directory, not args.no_probe)
    except (OSError, ValueError, KeyError, ZeroDivisionError, subprocess.SubprocessError) as error:
        print(json.dumps({'errors': [str(error)]}, ensure_ascii=False, indent=2))
        raise SystemExit(1)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    raise SystemExit(1 if result['errors'] else 0)
