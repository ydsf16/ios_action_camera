#!/usr/bin/env python3
"""Create a synthetic AVFoundation export fixture; requires ffmpeg/ffprobe.

This is not a captured Camera/IMU package and does not prove stabilization quality.
Copy the resulting directory into a simulator's Documents/Recordings, then use
the ordinary Library > Generate stabilized video UI.
"""
import argparse
import csv
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("directory", type=Path, help="New output directory")
args = parser.parse_args()
args.directory.mkdir(parents=True, exist_ok=False)
manifest = json.loads((Path(__file__).resolve().parents[1] / "Tests/Fixtures/export-manifest.json").read_text())
manifest["id"] = args.directory.name
video = args.directory / "video.mov"
subprocess.run([
    "ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=30:duration=2",
    "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=2",
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
                        [1200, 0, 960, 0, 1200, 540, 0, 0, 1] + [0])
with (args.directory / "gyro.csv").open("w") as f:
    writer = csv.writer(f)
    writer.writerow(["host_sec", "gx_rad_s", "gy_rad_s", "gz_rad_s"])
    writer.writerows([1000 + i/100, 0, 0, 0] for i in range(-15, 216))
(args.directory / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(args.directory.resolve())
