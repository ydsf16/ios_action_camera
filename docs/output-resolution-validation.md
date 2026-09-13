# Output resolution before generation — 0.9.1 (21)

## Behavior

- Settings → Default stabilization and output selects 1080p or 2.8K before
  recording. The choice is persisted with the effect; new recordings use it when
  they enter the stabilization queue. The initial default remains 2.8K.
- A clip's Adjust page includes the same output-size cards before Generate.
  Changing resolution keeps the selected preset, automatic fitting and horizon
  setting. An explicit Generate creates the selected size from the original.
- Export saves the currently visible original or processed movie directly to
  Photos. There is no export sheet, resolution selector, render queue submission,
  resizing or second stabilization in this action.
- Source frame rate/audio, orientation and the existing no-upscaling rule remain
  unchanged. Original recordings and the previous successful result keep the
  existing preservation policy.

## Verified on 2026-09-13

- Signed Release build for iPhone and Debug build for simulator passed.
  Static-linkage audit found no external Gyroflow dylib or developer-machine paths.
- Simulator settings were visually inspected. Selecting Standard + 2.8K and
  saving defaults persisted both values, with automatic fitting enabled.
- On a copied 4K recording, Adjust → 1080p → Generate produced a 1920×1080,
  60 fps movie with 375 video frames and an audio track. The successful receipt
  retained Standard, automatic fitting and gravity horizon lock.
- Tapping Export saved directly into simulator Photos. The saved movie SHA-256
  matched stabilized.mov exactly. All nine files in the recording folder retained
  the same hashes and modification timestamps throughout the save, including
  options, receipt and processing status. No second stabilization occurred.
- Hashes of all five input files remained unchanged across generation and export.
- Version 0.9.1 (21) was installed on the connected iPhone 16. The installed
  version and build were read back from the device. The generation/Photos checks
  above ran in the simulator; real-device behavior still needs hands-on acceptance.

Local verification logs: `/tmp/roamshot-091-device-build.log`,
`/tmp/roamshot-091-simulator-build.log`,
`/tmp/roamshot-091-export-verification.json`.

The device launch command timed out and a separate process listing did not
confirm RoamShot running. Installation is verified; device launch is unverified.

## 0.9.2 (22): upgrade existing global defaults to 2.8K

The connected phone still had a saved `fullHD` global output choice, despite the
new-install 2.8K default. On app startup, a one-time migration now sets only the
global output size to 2.8K and records completion. Saving defaults also records
completion, so subsequent explicit 1080p choices persist. Existing clip options
and receipts retain their recorded sizes. Capture remains 4K/60 fps by default;
output keeps the source frame rate without frame interpolation.

- Six focused Swift tests passed, including legacy-default migration, retaining
  stabilization/horizon settings, unchanged per-clip decoding and subsequent
  explicit output choices. iPhone Release and simulator Debug builds passed.
- Installed and launched 0.9.2 (22) on the iPhone 16. Read back the installed
  version and app preferences: capture `uhd4K`/60, output `action2_8K`, migration
  complete. This confirms device configuration, not a new physical recording.
- Simulator app was seeded with the previous phone's 1080p default. A copied 4K
  clip without saved processing options used the migrated global default and
  generated 2816×1584 at 60 fps, 375 video frames, with audio. The output receipt
  records 2.8K. No export-time resizing was introduced.
- Logs: `/tmp/roamshot-092-default-tests.log`,
  `/tmp/roamshot-092-default-output-verification.json`,
  `/tmp/roamshot-092-install.json`, `/tmp/roamshot-092-launch.json`.
