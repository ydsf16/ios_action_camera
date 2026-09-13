# RoamShot 1.0.1 (32): 4K60 capture and Metal performance

Based on submitted `v1.0.0-build.27` / `b3bf9e3`. Minimum iOS remains 17.0.
Publishing was paused during measurement and resumed at the user's request on
September 14, 2026. Defaults remain 4K60, 5 ms maximum
exposure and 2.8K output. Orientation, per-frame intrinsics and IMU clocks/axes
retain the submitted version's contracts.

## Diagnosis and final changes

The eight downloaded build-27 recordings requested 3840x2160 at 60 fps but
already contained about 47–49 fps in their originals. All logged
`capture_copy_pool_full`; stabilization preserved the original frame counts and
PTS. The representative 282-frame / 5.969483 s clip had 68 pool-full drops.

- 4K60 recording now prefers the system HEVC encoder, with the existing bitrate,
  PTS and frame metadata. `canApply` checks availability and falls back to H.264;
  `manifest.videoCodec` records the selection. Other recording modes and stabilized
  H.264 output are unchanged.
- The owned capture pool grows from 8 to 16, bounded to roughly 190 MiB of NV12
  image storage at 4K plus platform alignment/metadata, allocated on demand.
  On exhaustion, unused Metal texture wrappers are flushed and allocation is
  retried once within the same limit. Increasing the pool alone did NOT solve
  sustained H.264 throughput: build 29 still dropped 151 pool-full frames in 13 s.
- `capture-performance.json` records pool capacity, copy counts/times and pool-full
  drops. Failure to write these optional diagnostics cannot invalidate a recording.
- Periodic free-space queries run on a separate utility queue, with at most one
  outstanding query. Results only affect the same active recording. This removes
  filesystem queries from the video/audio/IMU delivery queue. Low-space, critical
  temperature and missing-motion stop checks remain.
- Lanczos4 interior sampling uses 2x2 texture gathers rather than 64 separate reads
  per plane. The same 32-phase weights, 8x8 support, precision, pixel centers,
  chroma siting and boundary/black-fill handling are retained. Processing keeps
  three frames in flight and zero application CPU pixel copies per frame.
- Split encoder readiness/append timings make the remaining bottleneck observable.
  Callback-based encoder waiting and HEVC stabilized output were measured and
  removed because neither improved end-to-end speed.

No frames are synthesized and no timestamps are rewritten to label missing-frame
originals as 60 fps. Existing 47–49 fps recordings retain their original cadence.

## Fresh iPhone 16 recording: capture pass

Device: iPhone 16, iOS 18.2.1. Clip `RS_2026-09-13_22-04-19_971C8A10`, build 30
(same final capture path), portrait, virtual dual-wide camera, 4K60, motion exposure
policy with 0.005 s maximum, HEVC original.

- 1204 frames / 20.107678 s; about 59.88 fps over the whole recording.
- After the first second: **59.9771 fps**, maximum adjacent gap **16.692 ms**.
- **Zero pool-full drops.** Four `FrameWasLate` entries are confined to startup:
  two precede the first accepted video frame, two fall within its first 34 ms.
  The largest recorded gap is consequently 50.030 ms at the beginning.
- All 1204 frames include K. Gyro, acceleration and gravity cover the movie at
  approximately 99.74 Hz, maximum IMU gap 10.028 ms.
- Encoded versus logged video PTS differs by less than 0.5 microseconds; recorded
  clock-pair fit residual is 23.18 microseconds. This checks stored clocks, not an
  independent visual/gyro time-offset estimate.
- No audio drops. Original/stabilized movies retain all 1204 video frames and their
  PTS, AAC audio, matching display rotation and audio/video duration.

## Device processing comparison

Same 1204-frame clip, same build-32 optimized Debug binary, identical 2.8K settings,
H.264 output and original polling encoder readiness. Runs are sequential with the
app foreground; this is a single paired timing observation, not a thermal benchmark.

| Sampling | Processing time | Output |
| --- | ---: | --- |
| Original Lanczos4 (`warpPlaneReference`) | 15.509 s | 2816x1584, 1204 frames |
| Gather Lanczos4 (`warpPlane`) | 14.183 s | 2816x1584, 1204 frames |

End-to-end time decreased **8.6%** (1.33 s). Optimized processing is about 1.42x
real time for this clip. Its 11.369 s encoder-readiness wait now dominates wall time;
GPU command intervals can overlap and must not be added to elapsed time.

Additional same-clip optimized runs measured 14.166 s and 14.198 s. Switching
stabilized output to HEVC took 14.978 s; callback readiness took 14.198 s, versus
14.183 s with polling. Neither experimental change remains in the final source.

## Correctness and build validation

- GPU oracle: 26,763,264 Y/UV byte samples at 4K to 2816x1584, including identity,
  fractional/projective transforms, edges and off-image black fill; maximum
  difference from the original kernel **zero**.
- Mac full export of the same 282-frame real clip: 4.452 s reference / 3.111 s
  gather. All decoded output frame hashes are identical. These host timings are
  separate from the physical phone measurements above.
- Existing Metal pixel tests passed: translation, downscale, black Y/UV and multiple
  frames in flight. Gravity-horizon pixel tests also passed.
- Capture-copy oracle passed at 720p and 4K: exact Y/UV bytes, original PTS/duration
  and attachments, 16-buffer bound and reuse after release. 720p is a buffer-only
  fixture, not a recording option.
- Final signed Release build 32 compiled and passed the linkage audit: no external
  Gyroflow dylib or developer-machine dependencies.
- Final Release 1.0.1 (32) installed successfully on the iPhone 16. Its automatic
  launch timed out after installation; live `lockState` again reported
  `passcodeRequired: true`. The later manual recording below verifies that this
  final Release launches, records and completes automatic stabilization.
  The paired timing comparisons above used optimized Debug with the same production paths.
- Downloaded final phone output passed packet/PTS/duration/orientation checks:
  all 1204 video frames, 944 AAC packets; compressed audio SHA-256 matches the
  original. An extracted frame was visually checked and contains normal imagery.

No controlled process-memory/thermal profile or long-duration stress test has been
collected. This pass establishes sustained 60 fps for the observed 20 s recording,
with two missing frames at startup; it does not promise zero drops on every device.

## Final Release manual recording, 2026-09-13 22:51

The user recorded `RS_2026-09-13_22-51-25_7A8E1316` on installed **1.0.1 (32)**.
The downloaded manifest, movie and fresh processing receipt confirm the final
Release camera/recording/automatic-stabilization path, without diagnostic launch flags.

- 3840x2160 HEVC, requested 60 fps, 5 ms maximum exposure, portrait display rotation.
- 624 frames over 10.470662 s: **59.595 fps** across the whole clip. After the first
  second, **59.97705 fps**, maximum gap **16.694 ms**; no continuing cadence gaps.
- **Zero pool-full drops.** Seven `FrameWasLate` entries: three precede the first
  accepted frame, four fall in its first 67 ms. The movie therefore has one initial
  **83.355 ms** gap. Startup frame loss remains an open issue.
- All 624 frames have K. IMU streams cover the video at about 99.73 Hz; maximum
  interval 10.028 ms. Recorded clock fit residual 14.55 microseconds; encoded/logged
  video PTS error below 0.5 microseconds. No empirical offset was applied.
- Stabilization completed in **7.390 s**, producing 2816x1584 H.264, all 624 frames,
  identical video PTS/durations and display transform. All 493 AAC packets are
  preserved; compressed audio SHA-256 matches the original. No audio drops.
- The output was decoded for visual inspection. Encoder readiness waits account
  for 5.801 s, consistent with the earlier performance bottleneck.

Evidence: `/tmp/roamshot-iphone16-perf/release32-fresh/`, including `audit.json`,
`media-check.json`, `capture-performance.json`, `stabilization.json` and both movies.
This confirms successful recording and valid output; it is not an interactive
playback/Photos-export UI test.

## Follow-up: investigate apparent slowdown before publishing

Git push and App Store upload were paused at the user's request. No commit, push,
archive upload or review submission was performed during that interrupted release
attempt. The initial follow-up ran on the host while the phone was disconnected;
the subsequent connected-phone comparison is recorded below.

The historical fast physical-phone result (`artifacts/metal-nv12-iphone-validation/
native-receipt.json` in the PhoneAI workspace) is 1068 frames / 35.603354 s at
1920x1080 output, processed in 6.925577 s. Its cadence is approximately 30 fps.
The current default is 2816x1584 at 60 fps: 4.302x as many output pixels per second
of footage. Additionally, build-27 originals often contained only about 48 fps;
recovering 60 fps increases frame count per second by roughly 25%. Neither
comparison isolates a software speed regression.

Code inspection found no CPU fallback on the Release pixel path. The same
IOSurface mapping and three-frame Metal pipeline remain, with the optimized
Lanczos gather kernel. In the final phone receipt, 5.801 of 7.390 s is spent
waiting for video encoder readiness. This is observed backpressure, not proof
of a particular hardware encoder limit.

An isolated **Apple M1 host** experiment used the exact same 624-frame HEVC source,
identical stabilization options and original PTS. A temporary processor copy
allowed bitrate overrides; production code/settings were not modified.

| Variable | Host time |
| --- | ---: |
| Current 2.8K60, 68.836 Mbps target | 6.610 s |
| Change output to 1080p60, standard 32 Mbps target | 3.595 s |
| Keep 2.8K60, change only bitrate to 16 Mbps | 6.417 s |
| Keep 2.8K60/default bitrate, use old Lanczos reads | 9.565 s |
| Repeat current 2.8K60/default bitrate | 6.575 s |

The resolution comparison also uses the normal resolution-scaled bitrate; the
separate fixed-resolution bitrate experiment shows little throughput benefit.
These host results support output-size and encoder backpressure as explanations;
they are not phone measurements or a controlled comparison of entire old app builds.
No bitrate reduction or quality concession has been applied to the product.

Evidence/scripts/output copies: `/tmp/roamshot-throughput-audit/`. Historical app
source: `2ae3605`; current release baseline: `b3bf9e3` plus the uncommitted changes
described above. The connected-phone tests below now quantify the matched build
and resolution comparisons. Thermal and process-memory profiling remains open.

## Matched whole-app comparison on iPhone 16, 2026-09-13 23:12

Both versions used the same physical iPhone 16, the same 624-frame 4K HEVC source
and original timestamps, identical stabilization options, and 2816x1584 H.264
output at the normal bitrate target. A separate, app-owned test recording held a
copy of the input. Both apps were optimized Debug (`-O`, whole-module compilation,
no Debug dylib), with validation-only launch hooks. Build 27 processing sources
were checked against `b3bf9e3`; the Rust source/library was identical between builds.

| Installed app / run order | End-to-end time | Frames |
| --- | ---: | ---: |
| Build 27, first | 8.309 s | 624 |
| Build 32, first | 7.443 s | 624 |
| Build 27, second | 14.732 s | 624 |
| Build 32, second | 7.426 s | 624 |

Build 32 takes about **10.5% less time than the faster build-27 run**. The older
build varied substantially; no thermal measurements were collected, so the cause
of that variation is unproven. These runs do not reproduce a current-build slowdown
under this source/configuration, and are not a claim about every device condition.

Build 32 spent 5.514-5.736 s waiting for encoder readiness and 0.109-0.138 s in
explicit GPU waits. Metal command intervals overlapped other work. Encoder
backpressure is the dominant observed wait; these measurements do not independently
establish the hardware encoder's maximum throughput.

With only the test copy's output preset changed to 1080p (including the normal
resolution-scaled bitrate), build 32 took **3.742 s**. Restoring its 2.8K preset
took **7.411 s**. Product output defaults remain 2.8K/60.

Correctness checks on the downloaded phone outputs:

- Both old/new 2.8K exports have **identical decoded pixels in all 624 frames**.
- The old/new 2.8K, 1080p, and restored-2.8K exports preserve all original video
  PTS/durations and the display transform.
- All 493 AAC packet records and compressed audio payload hashes match the source.
- No frame removal, reduced sampling quality, or product bitrate reduction was
  used to obtain the speedup.

Evidence: `/tmp/roamshot-phone-comparison/` contains per-run installed-build records,
receipts, output movies, frame hashes, `results.json`, and `pixel-verification.txt`.

## Actual hardware encoder verification, 2026-09-14

An Instruments Time Profiler + os_log recording on the connected iPhone 16
identified the actual H.264 output encoder for a separate app-owned 127-frame
test copy at 2816x1584. The optimized Debug diagnostic app uses processing and
Metal sources identical to the production checkout; no alternate encoder was used.

- RoamShot PID 11445 delegates the AVAssetWriter compression path to
  `mediaplaybackd` PID 277. App-process VideoToolbox encode/prepare breakpoints did
  not fire because the actual compression session runs in that service.
- Service logs report `H264H9.videoencoder` / `AVE_H264StartSession` at **2816x1584**,
  successful preparation, and successful invalidate/finalize.
- Active frame-processing stacks contain `AVE_H264EncodeFrame`,
  `AVE_USL_Drv_Start`, `AVE_USL_Drv_Process`, and `AVE_DAL::UCProcess`, with
  AVAssetWriter's `FigMediaProcessorCreateForVideoCompressionWithFormatWriter2`
  setup in the same service.

This confirms **hardware H.264 encoding in the observed production export path**.
The evidence is actual driver activity, not just encoder registration or advertised
capability. The direct `UsingHardwareAcceleratedVideoEncoder` session property was
not read; the session is in the system service. AVAssetWriter readiness waits still
combine queueing/interleaving/write-path effects and do not establish a pure
hardware-encoding time or maximum throughput.

The 20-second trace contains the export interval. It reported dropped log messages
under load, so it is not a complete per-frame timeline. This trace establishes the
encoder path and is not a replacement for the earlier matched speed comparison.
Relevant logs, stacks, launch identity and receipt are retained in the PhoneAI
workspace at `artifacts/roamshot-hardware-encoder-2026-09-14/`; the full trace is
`/tmp/roamshot-hardware-encoder3.trace`. Release status is recorded separately in
`app-store/release-validation.md`.

## Reproduce

Use recording copies; the exporter replaces `stabilized.mov` only after success.

```sh
./scripts/benchmark_export.sh /path/to/reference-copy --reference-lanczos
./scripts/benchmark_export.sh /path/to/optimized-copy
./scripts/benchmark_export.sh --self-test
./scripts/benchmark_export.sh --horizon-pixel-test
./scripts/validate_metal_sampling.sh
python3 scripts/audit_recording.py /path/to/recording
```

Debug-only `--reference-lanczos` selects the old shader; Release always uses gathers.
`--recording-validation-seconds 20` records through the usual camera, entitlement,
telemetry and stop paths, requiring the 4K60 preset. `--keep-awake-for-validation`
keeps foreground diagnostics awake; neither diagnostic launch behavior is in Release.

Local media/receipts are under `/tmp/roamshot-iphone16-perf/`, including `before/`,
`fresh29/`, `fresh30/`, `audit30.json`, `phone-reference32-1.json`,
`phone-optimized32-1.json` and `phone-final32.mov`. Device media and internal
validation records are retained locally and are not part of the source release.
