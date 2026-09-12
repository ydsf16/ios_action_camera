#!/usr/bin/env python3
"""Create a synthetic AVFoundation export fixture; requires ffmpeg/ffprobe.

This is not a captured Camera/IMU package and does not prove stabilization quality.
Copy the resulting directory into a simulator's Documents/Recordings, then use
the ordinary Library > Generate stabilized video UI.
"""
import argparse
import csv
import math
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("directory", type=Path, help="New output directory")
parser.add_argument("--seconds", type=int, default=2)
parser.add_argument("--width", type=int, default=1920)
parser.add_argument("--height", type=int, default=1080)
parser.add_argument("--fps", type=int, choices=[24, 30, 60], default=30)
parser.add_argument("--motion", action="store_true", help="Synthetic gyro for border/render regression only")
args = parser.parse_args()
if not 1 <= args.seconds <= 300 or args.width < 4 or args.height < 4 or args.width % 2 or args.height % 2:
    parser.error("Use 1–300 seconds and positive even dimensions")
args.directory.mkdir(parents=True, exist_ok=False)
manifest = json.loads((Path(__file__).resolve().parents[1] / "Tests/Fixtures/export-manifest.json").read_text())
manifest["id"] = args.directory.name
manifest.update(durationSeconds=args.seconds, width=args.width, height=args.height, requestedFPS=args.fps,
                videoFrames=args.seconds*args.fps, framesWithIntrinsics=args.seconds*args.fps, gyroSamples=args.seconds*100+31)
video = args.directory / "video.mov"
subprocess.run([
    "ffmpeg", "-v", "error", "-f", "lavfi", "-i", f"testsrc2=size={args.width}x{args.height}:rate={args.fps}:duration={args.seconds}",
    "-f", "lavfi", "-i", f"sine=frequency=440:sample_rate=48000:duration={args.seconds}",
    "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
    "-c:a", "aac", "-video_track_timescale", "1000000", "-shortest", str(video)
], check=True)
packets = json.loads(subprocess.check_output([
    "ffprobe", "-v", "error", "-select_streams", "v", "-show_packets", "-of", "json", str(video)
]))["packets"]
with (args.directory / "frames.csv").open("w") as f:
    writer = csv.writer(f)
    writer.writerow(["frame", "pts_value", "pts_timescale", "host_sec", "video_sec"] +
                    [f"k{r}{c}" for r in range(3) for c in range(3)] + ["stabilization_active"])
    for index, packet in enumerate(packets):
        pts = int(packet["pts"])
        writer.writerow([index, 1_000_000_000 + pts, 1_000_000, 1000 + pts/1e6, pts/1e6] +
                        [args.width*0.625, 0, args.width/2, 0, args.width*0.625, args.height/2, 0, 0, 1] + [0])
with (args.directory / "gyro.csv").open("w") as f:
    writer = csv.writer(f)
    writer.writerow(["host_sec", "gx_rad_s", "gy_rad_s", "gz_rad_s"])
    writer.writerows([1000 + i/100, 0, 0, math.sin(i/20)*1.5 if args.motion else 0] for i in range(-15, args.seconds*100+16))
(args.directory / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(args.directory.resolve())

if args.motion:
    (args.directory / "stabilization-options.json").write_text(json.dumps(dict(strength=1, maxCrop=1, dynamicCrop=False, allowBlackBorders=True)))
