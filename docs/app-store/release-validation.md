# RoamShot 1.0.0 release validation

## Identity and packaging

- App, Xcode project/scheme/module, Rust package/static library/C symbols, own source text and docs use RoamShot.
- Bundle ID: `com.grape.RoamShot`; non-consumable: `com.grape.RoamShot.pro.lifetime`. New installation identity; existing installations and their recordings are retained separately. New recording directories use `RS_`; legacy directory reading remains compatible.
- Signed iOS archive and App Store export succeeded. Export uses Cloud Managed Apple Distribution, with `get-task-allow=false`.
- Actual IPA contains RoamShot executable/identity, privacy manifest and license resources; no local StoreKit configuration. Binary string scan found no legacy app name, and linkage audit found no developer-machine dylib dependencies.
- GPL source distribution consists of this repository, pinned Gyroflow revision, both tracked patches, Cargo.lock and build scripts. Dependency inventory contains 283 entries, including build dependencies; 198 distinct notice texts are bundled.

## Validation completed

- `swift test`: 28 tests, zero failures, including free/pro recording policy at 24/30/60 fps.
- Debug simulator build and Release iOS archive/export succeeded.
- Xcode StoreKit local purchase presented the ¥20 one-time test purchase and changed the app to permanently unlocked. Xcode transaction manager refund caused the live app to return to the free recording paywall automatically. These are local tests, not production purchases.
- App Store Connect app and matching IAP exist; Chinese localization and ¥20 base price saved and read back.

## Outstanding acceptance

- StoreKitTest automated session configuration reports `SKInternalErrorDomain Code=3` on the installed simulator runtime. A preflight check now skips when dialog configuration is rejected, preventing a hanging purchase test. Full restore, pending approval and App Store sandbox still require successful validation.
- iPhone 16 reconnected on September 13 and build 27 installed successfully. Launch attempts later timed out, so build 27 real-device startup and recording acceptance are not yet confirmed. Verify a fresh 4K60 recording reaches the 60-second cap, closes video/audio/CSV normally, preserves camera-to-host clock mapping and IMU axes, and produces 2.8K output with audio. Verify Pro records beyond 60 seconds.
- Build 1.0.0 (25) uploaded successfully to App Store Connect. The source tag `v1.0.0-build.25` and main branch are public. Support, privacy and terms URLs each returned HTTP 200 after GitHub Pages deployment.
- Build 26 also renames the remaining internal C API abbreviations to roamshot_engine_ and RoamShot type names; iOS archive, simulator build/launch, binary string and linkage audits passed. App Store Connect upload and processing succeeded on September 13, 2026; build 26 is associated with version 1.0.0, which is prepared for the user to submit with the lifetime IAP. Source tag `v1.0.0-build.26` and the corresponding main branch commit are public.
- The automated CommerceQA rerun produced one skipped test, zero executed purchase scenarios, because StoreKit rejected configuration. Local manual purchase/refund evidence remains separate.
- Store metadata: age 4+, no collected data, free download, Mac/Vision Pro distribution disabled, and IAP review screenshot and review draft configured.
- App review contacts/copyright were copied from the existing Sensor Recorder Pro app under the same account. First release is configured for China mainland; the original four UI marketing screenshots and Chinese copy were uploaded for build 26; build 27 replaces them with six images and revised copy. The user explicitly reserves the final review submission action. The account business page explicitly reports an updated Developer Program agreement awaiting the account holder; the Paid Apps agreement is active. Exporting or uploading a build does not mean review approval or availability on the App Store.

## Build 27 follow-up

- Free recording starts directly from the record button. The recording paywall and the free-limit upgrade alert are removed; recording reaches the same 60-second policy and saves normally. Upgrade and Restore Purchases remain in Settings > RoamShot Pro. The camera only shows a time-to-save countdown while a free recording is running.
- Simulator Debug build and signed Release archive passed. `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`: 28 tests passed. Mach-O linkage check passed. The initial plain `swift test` used Command Line Tools and could not locate XCTest; it was rerun with the full Xcode developer directory.
- Build 27 uploaded and completed App Store Connect processing. Version 1.0.0 now references build 27. Six screenshots and the new direct-recording review notes were saved and read back. App 1.0.0 (27) and RoamShot Pro Lifetime are in the same review draft with two prepared items. The final submission button was not clicked.
- Camera and 2× images show production SwiftUI controls over an AI-generated coastal illustration. The image input is compiled only for Debug simulators and is absent from the signed iOS archive. The updated upgrade screenshot comes from the build 27 settings view with local StoreKit price ¥20.
- Build 26 was installed and its live phone viewfinder was observed before the user's request to remove purchase prompts. That observation does not validate build 27's minute-long recording lifecycle or real stabilization quality.
