# Metal NV12 pipeline — 0.4.0

The production pixel path is AVFoundation NV12 decoding → IOSurface-backed Metal
textures → Lanczos4 warp of Y and UV → encoder-pool NV12 buffers → AVFoundation
H.264 encoding. No application-side CPU pixel mapping, BGRA conversion, texture
upload, GPU readback, or intermediate full-frame copy occurs on this path. Internal
codec/driver allocations are owned by Apple and are not claimed to be copy-free.

Up to three frames can be in flight. Source/output CVPixelBuffers and CVMetalTextures
remain alive through command completion. Completed buffers enter the encoder in
PTS order. Audio continues independently with compressed packets preserved. Buffers
come from the writer pool. Autolock is disabled while recording or processing in
foreground, and restored afterwards; backgrounding cancels safely.

The GPU shader uses the same quantized Lanczos4 weights as Gyroflow. Pose integration,
smoothing and dynamic crop remain on CPU: measured together at 0.021 s for 900 frames.
Per-frame transforms total 0.016 s. Moving those tiny sequential tasks to GPU is not
a demonstrated performance improvement. Codec work uses system video processing;
we do not claim all operations execute on GPU cores.

The direct projection contract is the app's current zero residual distortion,
no rolling-shutter, no digital-lens mode. Unsupported models fail explicitly.
Per-frame intrinsics and Gyroflow smoothing/crop feed a homography. A regression
checks the logical-output-to-encoder-viewport scale at 1x and 5x crop. Native shaders
use integer pixel centers as Gyroflow CPU does; the old wgpu fragment path has a
half-output-pixel position difference. Chroma siting/range and color attachments are
preserved; output aperture/intrinsics are not copied from the larger input image.

## Measured on Apple M1 (not iPhone)

Same optimized Swift build, same inputs and settings, sequential runs; single-run
results are directional, not a thermal or device-wide guarantee. Synthetic motion
is for rendering/performance checks, not camera stabilization-quality claims.

| Input / 1080p output | BGRA wgpu baseline | Native NV12 |
| --- | ---: | ---: |
| Real 4K, 81 frames / 2.7 s | 1.730 s | 0.890 s |
| Synthetic 4K, 900 frames / 30 s, moving, black borders allowed | 13.624 s | 6.544 s |
| 30 s clip process peak memory footprint (`time -l`) | 151.7 MB | 61.0 MB |
| 30 s clip process maximum resident set | 457.6 MB | 56.9 MB |

30 s case: 2.08x faster than baseline, 4.58x playback speed. Memory numbers describe
this process's reported accounting, not all shared IOSurface/driver/codec memory.
Native parse 0.026 s, pose/crop 0.021 s, transforms 0.016 s, decode waits 0.174 s,
GPU submission 0.171 s, GPU waits 5.739 s, encoder wait/append 0.073 s. Command GPU
timestamp intervals can overlap and must not be summed as exclusive GPU busy time.

Both outputs fully decode: 81/900 frames at 1920x1080 and 2.7/30 seconds. All
127/1408 audio packet hashes match the respective input. Real footage result frame
visually inspected; native vs baseline encoded-video PSNR averages 36.8 dB, with
geometry preserved and expected subpixel/resampling differences.

Metal pixel checks cover identity, translation, downscale, Y/UV black fill and
multiple in-flight buffer lifetimes. Ten Rust tests include crop/transform and
CPU/wgpu regressions. Six Swift input/clock tests cover the unchanged capture contract.

## Reproduce

Use copies of recordings: successful runs replace stabilized.mov in the supplied
folder. No private footage belongs in this public repository.

```sh
./scripts/benchmark_export.sh --self-test
./scripts/benchmark_export.sh /absolute/path/to/recording-copy
./scripts/benchmark_export.sh /absolute/path/to/another-copy --legacy-bgra
python3 scripts/make_export_fixture.py /tmp/MC_Performance --seconds 30 --width 3840 --height 2160 --motion
```

The benchmark script compiles Rust, Metal and optimized Swift. Install the Metal
Toolchain via Xcode if missing. Receipts include per-stage timings, backend, in-flight
limit and application pixel-copy count. For physical iPhone diagnostics, optimized
Debug supports `--stabilize-recording MC_… --force-stabilization` with optional
`--legacy-bgra`; production Release always uses native NV12. Use equal settings and
at least a 30-second clip, check output/audio, and compare cold/warm/thermal runs.

Signed Release and simulator builds passed. The simulator completed an 81-frame
export using the native path; an extracted output frame was visually checked.
Simulator timings are not an iPhone performance result.

## Physical iPhone 16 validation (2026-09-12)

YJJY was reconnected and tested using a real 35.603333 s recording (1068 frames,
3840x2160 input, 1920x1080 output, original -90 degree display transform). Settings:
strength 0.5, dynamic crop on, maximum 2x, black borders off. Original and prior
output were backed up outside the public repository.

| Run | Processing time |
| --- | ---: |
| Previous 0.3.1 receipt, historical reference | 28.335 s |
| 0.4.0 optimized Debug, legacy BGRA path | 17.014 s |
| Same build, native NV12 path | 6.926 s |

The controlled same-build comparison is 2.46x faster, or 5.14x playback speed.
The historical 28.335 s measurement includes build/run-condition differences and
is not an isolated pipeline benchmark. These are single foreground runs, not a
sustained thermal guarantee. Native input parsing 0.087 s, pose/smoothing/crop
0.048 s, transforms 0.017 s, decode waits 0.619 s, GPU submission 0.149 s,
GPU waits 4.964 s, encoder wait/append 0.406 s, finishing 0.051 s.

Full native output decodes, 1068 frames / 35.603333 s, transform preserved;
all 1670 audio packet hashes match the input. An extracted frame was inspected.
Encoded native vs legacy comparison averages 38.88 dB PSNR, with the expected
resampling/subpixel differences described above. App-side pixel-copy count is zero.

Initial attempts were cancelled while the phone was locked. Check `devicectl device
info lockState` and keep the app in foreground before benchmarking. Unlocking the
phone allowed both tests to complete. Finally the signed 0.4.0 build 8 Release app
was installed and launched normally, retaining the native result. Reported timings
were collected using optimized Debug diagnostics; the final Release install was
verified separately.

Apple references: [Core Video Metal texture mapping](https://developer.apple.com/documentation/corevideo/cvmetaltexturecachecreatetexturefromimage(_:_:_:_:_:_:_:_:_:)),
[Apple-silicon image processing](https://developer.apple.com/videos/play/wwdc2021/10153/).
