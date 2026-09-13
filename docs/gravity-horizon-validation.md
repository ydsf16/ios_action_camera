# Gravity horizon lock — 0.8.1 (19)

## Behavior and contracts

- An independent “重力水平锁定” switch is available in default and per-clip
  stabilization settings. It defaults to off, including when decoding old settings.
  No short-segment preview was added.
- Uses recorded `CMDeviceMotion.gravity`, separated from user acceleration by
  CoreMotion. It does not use total accelerometer readings as gravity. Pan and pitch
  remain available. The lock can also be used with zero orientation smoothing.
- Gravity retains its independent sampling times and uses the same recorded clock
  mapping as gyro. Streams are not zipped by row, independently zeroed, or shifted by
  an empirical offset. Raw media, gyro, gravity CSV, and per-frame K remain unchanged.
- CoreMotion's device axes are x right, y up, z out of the screen in portrait.
  In the existing native rear-camera image basis, pass normalized gravity to
  Gyroflow's gravity metadata as `[-deviceY, -deviceX, -deviceZ]`.
  This conversion applies once. The gyro integrator's separate raw-rate convention
  is unchanged; it must not be substituted for the gravity-metadata convention.
- Gyroflow receives 100% horizon lock with horizon roll `-displayRotationDegrees`.
  Its video rotation remains zero; Swift preserves the source track display transform.
  Manifest rotation must be 0/90/180/270 and agree with the source track's linear
  transform. Native pixels and K are never rotated twice.
- Missing, nonfinite, nonmonotonic, insufficiently covering or invalid gravity
  raises an error when the switch is on; no silent fallback to gyro-only horizon.
  Gravity gaps must be below 100 ms and vector lengths within 0.5–1.5 g.
  With the switch off, old materials do not require gravity.
- When normalized gravity's image-plane projection approaches zero, the horizon is
  ill-defined. Lock amount uses a smoothstep fade from 0 to 100% over projection
  lengths 0.05–0.20, using Gyroflow's horizon-amount keyframes. This avoids choosing an
  arbitrary roll when looking straight up/down. It does not guarantee immunity to
  erroneous CoreMotion gravity during sustained acceleration.
- Existing crop/edge policies still apply. A horizon correction can require more
  cropping, or leave black regions when stability priority is selected. Frame-coverage
  priority can fail when its crop cap cannot cover the requested horizon correction.
- Processing remains Metal NV12 IOSurface. Gravity affects CPU pose calculations;
  no production image conversions, uploads or readbacks were introduced.
- Export receipts record the switch, source, sample count and gravity-axis mapping.

## Verification — 2026-09-13

- 23 Swift tests passed, including legacy/default decoding, persisted lock choice,
  asynchronous gravity timestamps, raw-axis preservation, unchanged K, missing data,
  insufficient coverage and gaps.
- 17 Rust tests passed; the preexisting optional GPU parity test remains ignored.
  Transform checks cover both ±20° tilt and zero tilt in all four capture orientations.
  Missing/shifted gravity is rejected; an optical-axis gravity fixture introduces no
  arbitrary roll correction.
- Eight actual Metal NV12 pixel tests passed (four orientations × both tilt signs).
  Known tilted bright stripes become horizontal after accounting for the preserved
  movie display rotation. These complement the mathematical transform assertions.
- A copied real iPhone recording, `MC_2026-09-13_09-57-07_B6823473`, was processed on
  Mac with lock off/on and otherwise identical settings: 0.8 s smoothing, fixed 1×,
  black borders allowed, 2.8K. The locked version consumed all 848 gravity samples.
  Both results contain 375 decoded frames at 2816×1584, retain audio, and preserve
  recorded frame timing within 0.498 microseconds. Duration is 7.820368 seconds.
  Source-file SHA-256 hashes match both working copies. A sampled frame shows the
  expected small horizon correction; this is not full handheld quality acceptance.
- Signed iPhone Release and simulator Debug builds passed; the static-linkage audit
  found no external Gyroflow dylib or developer-machine dependency. Version 0.8.1 (19)
  was installed on the connected iPhone 16, read back from the device, and successfully
  launched; the process remained running after launch. These checks do not establish
  full real iPhone processing or handheld horizon quality acceptance.

Local A/B artifacts live under
`/Users/grape/Documents/ChatGPT/PhoneAI/artifacts/gravity-horizon-0.8.1/`:
`unlocked/stabilized.mov` and `locked/stabilized.mov`. These are full processing
validation outputs, not an in-app short-preview feature.

```sh
swift test
cargo test --manifest-path Engine/Cargo.toml --release --locked
scripts/benchmark_export.sh --horizon-pixel-test
python3 scripts/check_app_linkage.py build-device/Build/Products/Release-iphoneos/RoamShot.app
```

## References

- [Apple: CMDeviceMotion.gravity](https://developer.apple.com/documentation/coremotion/cmdevicemotion/gravity)
- [Apple: CMDeviceMotion](https://developer.apple.com/documentation/coremotion/cmdevicemotion)
- [Gyroflow: stabilization and gravity horizon lock](https://docs.gyroflow.xyz/app/getting-started/basic-usage/stabilization)
- Pinned Gyroflow `977b843e320fd36b32db2b71f210f1f1a516f8cb`:
  `src/core/smoothing/horizon.rs`, `src/core/imu_integration/mod.rs`,
  `src/core/gyro_source/mod.rs`, and `src/core/stabilization/frame_transform.rs`.
