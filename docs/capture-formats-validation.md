# Capture and export formats — 0.5.0 build 13

Validated on 2026-09-12 with Xcode 26.3 and the pinned Gyroflow core.

## Automated checks

- 12 Swift tests passed: format fallback and persistence, migration of the removed
  720p recording preference, preservation of old stabilization options, source-size
  export limits, and 24/60 fps timestamp gaps/native intrinsics.
- Rust: 10 tests passed, one existing test ignored. The new 4K-to-2.8K native
  transform check verifies field of view at both 1× and 5× crop.
- Signed iPhone Release build and static-link audit passed.
- `scripts/CaptureBufferValidation.swift` passed on Mac M1: exact Y/UV bytes at
  1280×720 and 3840×2160, original PTS/duration and attachments, distinct owned
  buffers, eight-buffer allocation bound and successful reuse after release.
  CPU pixel access is confined to the test oracle.

## Full Metal export with synthetic video and audio

| Input | Requested output | Actual output | Frames | Video duration |
| --- | --- | --- | --- | --- |
| 4K60 | 1080p | 1920×1080, 60 fps | 180 | 2.999999 s |
| 4K60 | 2.8K | 2816×1584, 60 fps | 180 | 2.999999 s |
| 1080p24 | 2.8K | 1920×1080, 24 fps | 72 | 2.999999 s |

All output video PTS matched the source; all 142 AAC packet hashes matched in
each comparison. The source videos are 3 s long; the final encoded sample differs
by 1 µs due to rational frame durations on the movie timebase. Movie timescale is
now 1,000,000, avoiding the earlier millisecond-level edit-list truncation.
Rendered 2.8K frames were inspected. These synthetic checks verify the export
pipeline, not real-scene stabilization quality or sustained phone recording rate.

## iPhone status

- iPhone 16 (YJJY), iOS 18.2.1: native 4K60 configuration read back with both frame
  durations equal to 1/60 s. Video/IMU system clock was available.
- Before the owned-buffer fix, a completed 4K60 clip saved 283 frames over
  5.716307 s and reported 63 capture drops: 60 `OutOfBuffers`, three `FrameWasLate`.
  The latter three preceded the first accepted frame. A later clip also exhibited
  buffer exhaustion. This motivated the bounded Metal copy in 60 fps recording.
- Build 13, including that fix and the final export choices, installed successfully
  and its version was read back from the phone. The device was subsequently locked;
  sustained recording and drop counts on this final build still require a new clip.

Local validation artifacts, including private phone footage, are kept outside the
repository under the PhoneAI workspace's `artifacts/capture-formats-0.5.0` directory.
No phone footage is committed.
