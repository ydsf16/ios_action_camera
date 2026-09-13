#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
test_dir="$(mktemp -d /tmp/roamshot-sampling.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
xcrun -sdk macosx metal -c App/Stabilization/Stabilize.metal -o "$test_dir/Stabilize.air"
xcrun -sdk macosx metallib "$test_dir/Stabilize.air" -o "$test_dir/default.metallib"
xcrun swiftc -O App/Stabilization/MetalStabilizer.swift scripts/MetalSamplingValidation.swift -o "$test_dir/validate"
"$test_dir/validate" "$test_dir/default.metallib"
