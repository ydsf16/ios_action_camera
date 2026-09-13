# RoamShot App Store screenshots

Final uploads are in `store/`, ordered 01–04. Each PNG is 1284×2778, opaque RGB, for the 6.5-inch iPhone screenshot set. The native AppKit layout is reproducible with `swift scripts/render_store_screenshots.swift` from the repository root. App screenshots are placed intact inside a branded frame; controls and text are not redrawn.

- `store/01-playback.png`: actual build 26 playback UI. The landscape is AI-generated illustrative media, explicitly labeled in the image. An eight-second synthetic 4K60 fixture with zero gyro was processed by the app for this UI screenshot; it is not a real capture, lens calibration, synchronization measurement, or stabilization-quality comparison.
- `store/02-simple.png`: actual build 26 settings UI, Standard selected, gravity level enabled, 2.8K selected. These are unsaved screenshot settings in an isolated simulator.
- `store/03-controls.png`: actual build 26 expanded advanced settings, including dynamic crop, maximum crop, black borders, and zoom transition.
- `store/04-unlock.png`: actual build 25 paywall from Xcode local StoreKit testing. UI is unchanged in build 26. Shows the ¥20 non-consumable and the one-minute free option; the App Store Connect China base price is ¥20.

Source screenshots are in `raw/`; `iap-review.png` remains the unframed IAP review screenshot, and `stabilization.png` is the earlier raw settings screenshot retained for traceability. `sample-landscape.png` was generated for this app's marketing material. No private recordings or third-party photographs are used.

Screenshot simulator: RoamShot Store Screenshots, iPhone 14 Plus, iOS 26.3. Debug navigation shortcuts enter production views; simulator-only navigation is excluded from Release. Phone recording and real movement acceptance remain separate.

Reference: [Apple screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications) and [accurate metadata guidelines](https://developer.apple.com/app-store/review/guidelines/#accurate-metadata).
