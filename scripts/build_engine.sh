#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PATH="$HOME/.cargo/bin:$PATH"
export IPHONEOS_DEPLOYMENT_TARGET=17.0
command -v cargo >/dev/null || { echo 'Install Rust (rustup, minimal profile) first.' >&2; exit 1; }
git submodule update --init vendor/gyroflow
expected=977b843e320fd36b32db2b71f210f1f1a516f8cb
[ "$(git -C vendor/gyroflow rev-parse HEAD)" = "$expected" ] || { echo 'Unexpected Gyroflow revision' >&2; exit 1; }
for patch_name in gyroflow-full-intrinsics.patch gyroflow-metal-validation.patch; do
    patch_file="$PWD/patches/$patch_name"
    if git -C vendor/gyroflow apply --reverse --check --ignore-space-change "$patch_file" 2>/dev/null; then
        : # Already patched. Tracked patches are the source of submodule changes.
    else
        git -C vendor/gyroflow apply --check --ignore-space-change "$patch_file"
        git -C vendor/gyroflow apply --ignore-space-change "$patch_file"
    fi
done
for target in "${@:-aarch64-apple-ios}"; do
    rustup target add "$target"
    cargo build --manifest-path Engine/Cargo.toml --release --locked --target "$target"
done
