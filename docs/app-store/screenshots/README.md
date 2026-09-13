# RoamShot App Store screenshots

Uploads are in `store/`, ordered 01–06. Each PNG is 1284×2778, opaque RGB, for the 6.5-inch iPhone set. Render the layouts with `swift scripts/render_store_screenshots.swift`. The app controls are rendered by the app, not redrawn by image generation.

- `01-capture.png`: build 27 production camera controls at 1×, with an AI-generated sunny coastal path as the viewfinder illustration.
- `02-zoom.png`: the same simulator scene at 2×, selected using the real zoom control. This is a central enlargement for UI illustration, not an optical lens measurement, actual capture, or proof of stabilization quality. Both camera images are labeled as illustrative AI media.
- `03-playback.png`: actual build 26 playback UI, unchanged in build 27. An eight-second synthetic 4K60 fixture with zero gyro and AI landscape was processed for this screenshot. The labeled image is not a synchronization measurement or before/after comparison.
- `04-simple.png`: actual build 26 settings UI, unchanged in build 27. Standard, gravity level and 2.8K are selected as unsaved simulator screenshot settings.
- `05-unlock.png`: actual build 27 settings upgrade page, captured with the Xcode CommerceQA scheme and local StoreKit configuration. Shows the ¥20 lifetime product; no free-recording button or automatic recording paywall. App Store Connect China base price is ¥20.
- `06-controls.png`: actual expanded advanced settings, unchanged in build 27, including crop, black borders and zoom transition.

`raw/capture.png` and `raw/zoom.png` use the RoamShot Store Screenshots simulator (iPhone 14 Plus, iOS 26.3). Launch the Debug app with `--store-camera-image` followed by the absolute path to `sample-coast.png`, then use the existing 2× button. The fixture is compiled only for Debug simulators; it is excluded from all physical-device and Release builds. These screenshots demonstrate the production interface with generated sample media, not a working simulator camera.

`iap-review.png` is the unframed build 27 IAP review screenshot (RoamShot UI QA, iPhone 17 Pro simulator). Other originals remain in `raw/`. `sample-landscape.png` and `sample-coast.png` were generated for this app's marketing. No family recordings or third-party photographs are included.

The user requested generated scenery because outdoor imagery was unavailable at night. The coastal-image prompt and built-in tool provenance are in `generation-prompts.md`. Actual phone recording, telephoto stabilization and purchase acceptance remain separate.

Reference: [Apple screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications) and [accurate metadata guidelines](https://developer.apple.com/app-store/review/guidelines/#accurate-metadata).
