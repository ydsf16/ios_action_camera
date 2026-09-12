#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PATH="$HOME/.cargo/bin:$PATH"
bench_dir="$(mktemp -d /tmp/motioncam-export.XXXXXX)"
trap 'rm -rf "$bench_dir"' EXIT
# Apply the same pinned patches as the app, then build the native host library.
bench_target="$(rustc -vV | awk '/^host:/ {print $2}')"
./scripts/build_engine.sh "$bench_target"
xcrun -sdk macosx metal -c App/Stabilization/Stabilize.metal -o "$bench_dir/Stabilize.air"
xcrun -sdk macosx metallib "$bench_dir/Stabilize.air" -o "$bench_dir/default.metallib"
xcrun swiftc -O -D DEBUG -parse-as-library -import-objc-header Engine/include/MotionCamGyroflow.h \
    Sources/CaptureCore/*.swift App/Stabilization/MetalStabilizer.swift App/Stabilization/StabilizationProcessor.swift \
    scripts/ExportBenchmark.swift scripts/MetalPixelValidation.swift "Engine/target/$bench_target/release/libmotioncam_gyroflow.a" \
    -lc++ -liconv -framework Metal -framework QuartzCore -framework Security -framework SystemConfiguration \
    -o "$bench_dir/export"
"$bench_dir/export" "$@"
