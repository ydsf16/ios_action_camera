# Simple stabilization and automatic fitting — 0.9.0 (20)

Historical validation below describes 0.9.0. Version 0.9.1 moves output size back
to settings before generation and makes export a direct Photos save, with no
reprocessing. See [output resolution validation](output-resolution-validation.md).

## User flow

- The ordinary adjustment page offers Natural / Standard / Strong and Keep level.
  Detailed strength, fixed/dynamic crop, black borders and zoom transition remain
  available inside Advanced. There is no short-preview feature.
- Presets use 0.3 / 0.8 / 3 seconds of smoothing and maximum dynamic crops of
  1.5× / 2× / 2.5×, respectively. All use automatic fitting, no black borders and
  a 2-second zoom transition. Choosing a preset preserves horizon and export choices.
- Existing saved settings decode with automatic fitting disabled, retaining their
  previous numeric/crop/edge behavior. They appear as custom settings, without a
  misleading selected preset. New defaults are Standard. Editing an advanced value
  enters custom mode; selecting a preset restores automatic fitting.
- Per-clip Generate first checks telemetry, pose/crop feasibility and movie display
  orientation without decoding or encoding frames. An impossible manual crop
  combination stays on the settings page and offers recommended settings. Rejected
  preflight checks do not save options or modify the current movie/receipt.
- Processing failures preserve the original and previous result. Parameter failures
  offer recommended settings; data/storage/codec errors remain explicit and do not
  pretend a parameter change will repair them. Retrying original settings is retained.
- Output size is chosen in Export: 1080p or 2.8K, capped at original dimensions.
  Changing size regenerates with the visible successful result's options, rather than
  a failed draft. Keeping the current encoded width saves directly. Original export
  retains original size. Photo permission denial does not trigger reprocessing.

## Engine policy

All fitting happens before codecs start; there are no encoded trial clips. The same
planner is used for preflight and final processing. Automatic mode evaluates at most
ten whole-clip pairs of smoothing multiplier / horizon multiplier:

`(1,1), (.5,1), (.25,1), (.25,.5), (.1,.5), (.1,.25), (.02,.25), (.02,0), (.005,0), (0,0)`.

Duplicate consecutive pairs are skipped when smoothing or horizon is disabled.
For each candidate, adaptive crop uses the available frame coverage up to the preset
cap. Manual mode retains the previous five smoothing factors and does not weaken
requested horizon lock. Explicit black-border mode accepts the first candidate,
preserving requested smoothing and crop. The existing coverage calculation remains
approximate; it is not a guarantee against every possible dark edge.

Horizon-amount keyframes retain the existing near-vertical confidence fade, scaled by
the chosen horizon multiplier. Receipts include requested/effective smoothing and
horizon percentages. The UI explains reductions; if all requested orientation
correction is disabled at the final limit, it says only framing was adjusted and
labels the video as a processed result instead of stabilized video. Invalid sensor
data, invalid projections and codec failures still produce errors. No automatic
time offset, raw-axis changes, intrinsics changes or CPU pixel copies were added.

## Validation, 2026-09-13

- 25 Swift tests passed: migration, presets, retaining horizon/export choices,
  old receipts and explicit non-stabilized fallback reporting, plus existing contracts.
- 20 Rust tests passed; one preexisting optional GPU parity test is ignored. Tests
  cover manual crop/horizon conflicts and automatic recovery in all four orientations,
  preservation of explicit black-border settings, and rejection of broken telemetry.
- All eight Metal horizon pixel tests still pass (four orientations, both tilt signs).
- A synthetic 45° gravity/crop conflict on a copied 4K recording was checked before
  encoding. Both preflight and failed manual processing preserved previous result and
  receipt bytes. Automatic processing matched the preflight report, produced 375
  decoded frames with matching PTS and audio track count, and preserved source hashes.
  The final zero-correction case was explicitly reported as framing only.
- The same recording with its real, unchanged IMU was exported using Strong + Keep
  level: 2816×1584, 375 frames, requested/effective smoothing 3/3 seconds and horizon
  100/100%, actual crop 1.2292–1.4907×. Video PTS residual is at most 0.4981 microseconds;
  compressed audio packet hashes match the original. All five input hashes match.
- Signed iPhone Release and simulator Debug builds passed. Static-linkage audit
  found no external Gyroflow dylib or developer-machine dependencies. Simple and
  advanced settings and the colored export-size buttons were opened in the simulator
  and visually inspected.
- Simulator app UI: a conflicting custom draft was rejected before generating a
  task, with the existing primary action changing to recommended settings in place.
  Previous real movie, receipt and draft hashes remained unchanged. An export from
  the same conflicting draft used the last successful result's Strong + horizon
  settings and generated 1080p successfully. The user flow then exported again at
  2.8K. Both saved movies were found in the simulator Photos library, with expected
  dimensions and audio; each matched the generated movie byte for byte when saved.
  The visible recommended-settings action was then exercised after another conflict;
  it completed with Standard + Keep level, retaining the chosen 2.8K size and 375 frames.
- Library badges use “已处理”; a final zero-correction fallback is described as
  framing only, including in the playback selector and processing explanation.
- After the phone was reconnected, version 0.9.0 (20) was installed on the iPhone 16.
  The installed version/build were read back from the device; launch succeeded and
  the RoamShot process was confirmed running. Hands-on capture/processing quality
  acceptance is separate from this installation and launch verification.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
cargo test --manifest-path Engine/Cargo.toml --release --locked
scripts/benchmark_export.sh --horizon-pixel-test
scripts/benchmark_export.sh --adaptive-test /path/to/copied/recording
python3 scripts/check_app_linkage.py build-device/Build/Products/Release-iphoneos/RoamShot.app
```

Local real-clip output:
`/Users/grape/Documents/ChatGPT/PhoneAI/artifacts/simple-stabilization-0.9.0/strong/stabilized.mov`.
