# RoamShot branding — 0.10.1 (24)

- Display name, bundle name, viewfinder title and the in-app Files instructions
  now use **RoamShot**. The bundle ID remains `com.grape.RoamShot`, allowing an
  in-place upgrade with existing app data/preferences. Internal build/engine names
  remain unchanged.
- The generated icon combines a lens ring and flowing trail into an abstract R.
  Midnight navy, mint/teal and cyan follow the app's current color palette.
- `icon-source.png` is the original 1254×1254 RGB generation. The packaged
  `App/Resources/Assets.xcassets/AppIcon.appiconset/RoamShot-1024.png` is a
  mechanical 1024×1024 resize, fully opaque, with square canvas corners.
  iOS supplies its own icon mask. No text or device mockup is baked into the icon.
- The project generator now includes asset catalogs in the resources build phase
  and sets AppIcon as the primary icon, so regenerating the project retains it.

## Validation on 2026-09-13

- Signed iPhone Release and simulator Debug builds passed; static-linkage audit
  passed. Built Info.plist files report RoamShot, version 0.10.1/build 24, the
  unchanged bundle ID, AppIcon and compiled icon resources.
- After simulator upgrade, five existing recording folders and capture/output/grid
  preferences remained present and unchanged. The app launched, its viewfinder
  showed RoamShot, and SpringBoard showed the new icon and name. The home-screen
  icon was visually inspected at its actual display size.
- The physical iPhone was unavailable, so this branding version has not yet been
  installed or visually checked on the phone.

Local evidence: `/tmp/roamshot-0101-device-build.log`,
`/tmp/roamshot-0101-simulator-build.log`, `/tmp/roamshot-home-screen.png`.
