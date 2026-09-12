# Third-party notices

MotionCam is GPL-3.0-or-later with the App Store permission in LICENSE.

## Gyroflow core

- Project: https://github.com/gyroflow/gyroflow
- Version: v1.6.3, commit `977b843e320fd36b32db2b71f210f1f1a516f8cb`.
- Copyright: Adrian Eddy, Elvin Chen, and other Gyroflow contributors; retain upstream per-file notices.
- License: GPLv3 with the upstream App Store Exception. See `vendor/gyroflow/LICENSE`.
- Modification: `patches/gyroflow-full-intrinsics.patch` adds full per-frame camera matrices to LensParams and uses them for image projection. The patch is applied by `scripts/build_engine.sh`; it does not claim upstream acceptance.
- The app links the Rust core. It does not link the Gyroflow Qt UI, FFmpeg, or mdk-sdk.

## Rust dependencies

Exact dependency versions and revisions are captured in `Engine/Cargo.lock`; their source URLs and license metadata can be inspected using `cargo metadata --manifest-path Engine/Cargo.toml --format-version 1`.

Before distributing App Store/TestFlight builds, archive the matching application source, submodule revision, patch, Cargo.lock and build scripts; include the applicable dependency notices and a working source link. The current development build is not an App Store release.

Source: https://github.com/ydsf16/ios_action_camera
