# Stabilization controls — 0.8.0 (18)

## Behavior

- The strength slider spans 0–10 seconds of Plain 3D smoothing, with natural,
  standard, strong and extra-strong labels. Zero now disables orientation smoothing;
  crop, lens reprojection and export sizing still apply. No fixed-camera mode is used.
- Persist `smoothingSeconds` directly. The UI position is
  `log(1 + seconds / 0.1) / log(101)`; it is not a percentage of measured stabilization.
  Old `strength` values migrate with the original `0.16 * 25^strength` mapping,
  including old zero (0.16 seconds). Migration also preserves cropping, edge policy,
  export resolution and the old 2-second zoom transition. New default smoothing
  remains 0.8 seconds, displayed as approximately 48% on the expanded scale.
- Dynamic cropping sets a maximum zoom; fixed cropping uses the selected zoom for
  the whole clip. Both range from 1× to 5×. Changing edge policy does not reset either.
  The full-view button remains an explicit choice of 1× fixed cropping.
- Stability priority (`allowBlackBorders: true`) retains requested smoothing.
  Frame-coverage priority keeps the existing fallback factors
  `[1, 0.5, 0.25, 0.1, 0.02]`, applied to the whole clip. The implementation now reports
  the actual selected smoothing time and crop range rather than hiding the reduction.
  This remains an approximate coverage calculation, not a universal no-black-pixel guarantee.
- Dynamic zoom transition is adjustable from 0.5 to 10 seconds under Advanced.
  Longer transitions can retain a tighter crop for longer. Recorded intentional zoom
  still uses the original per-frame intrinsics.
- `mc_engine_report` returns four doubles without touching image buffers.
  `stabilization.json.stabilization` stores requested/effective smoothing time and
  actual min/max crop. Preview shows a crop-limit prompt; settings show the previous
  result and distinguish unapplied edits. Old exports without diagnostics show no
  fabricated result. Old diagnostics are invalidated immediately before publishing a
  new movie, and the new receipt is written after successful replacement. An interrupted
  publication can leave absent diagnostics, but does not present an old report as new.
- Capture, IMU axes, clock mapping, native pixel orientation and K are unchanged.
  Gravity horizon lock was added in [0.8.1](gravity-horizon-validation.md).
  Short-segment interactive preview is excluded at the user's request.

## Verification, 2026-09-13

- 21 Swift tests passed, including migration, real zero/max persistence and absent
  diagnostics. 14 Rust tests passed; the existing optional GPU parity test is ignored.
- A synthetic 20-second slow-motion trajectory has progressively less virtual-camera
  angular travel at 4, 6 and 10 seconds of smoothing. A nonzero three-axis trajectory
  produces identity correction when smoothing is zero. Crop-restricted processing
  reports the actual reduction; stability priority preserves requested strength.
- Five native Metal NV12 exports of copied 4K60 synthetic fixtures passed. Each has
  180 frames, preserved frame PTS and an audio track. All four original input files
  were hash-checked unchanged. Motion was deliberately synthesized for this test;
  these results do not establish real handheld capture quality.
- Re-exporting the existing 10-second result with smoothing off also passed: the
  movie was replaced successfully and the receipt reports the new options/effective zero.

| Case | Requested / effective smoothing | Fixed crop | Sampled dark pixel fraction |
|---|---|---|---|
| Off | 0 / 0 s | 1× | 0.0003% |
| Strong | 4 / 4 s | 1× | 7.15% |
| Extra | 6 / 6 s | 1× | 7.59% |
| Maximum | 10 / 10 s | 1× | 8.10% |
| Coverage priority | 4 / 0.08 s | 1.2× | 0.0021% |

The luma statistic samples every tenth frame on an 8-pixel grid (Y ≤ 18 after
encoding). It verifies visible policy differences on this fixture, not scene-independent
black-border measurement or a stability score.

- Signed iPhone Release and simulator Debug builds passed; static-linkage audit passed.
  The settings page was opened in the simulator and visually inspected. Real iPhone
  installation was subsequently verified with [0.8.1](gravity-horizon-validation.md);
  hands-on strength/edge-policy acceptance is separate from these automated checks.

Reproduce with:

```sh
swift test
cargo test --manifest-path Engine/Cargo.toml --release --locked
scripts/benchmark_export.sh --parameter-test /path/to/synthetic/MC_fixture_4K60
```
