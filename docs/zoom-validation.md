# Continuous capture zoom — 0.7.0 (16)

## Behavior

- Prefer Triple / Dual Wide / Dual virtual capture devices when they support the requested video format and intrinsic-matrix delivery. Otherwise retain physical-camera capture.
- Pinch and the expandable logarithmic zoom slider work while ready or recording. Preset buttons ramp to their target at a rate of 3. All requests are clamped to current device limits and a UI maximum of 5x.
- On iOS 18+, use `displayVideoZoomFactorMultiplier`; older devices derive the wide-camera reference from constituent switch-over factors. UI 0.5x does not mean assigning AVFoundation a factor below 1.
- Virtual-device primary switching uses `.auto`; Apple may switch based on zoom, light and focus distance. Preset buttons request a field of view and do not guarantee which physical camera supplies a frame.
- No input replacement, session restart or timestamp reset happens on the zoom path. Source sample PTS, session clock conversion, IMU values and per-sample K remain authoritative.
- `camera_index_observed` and `zoom_observed` are callback-time device observations, not exposure-exact metadata. Their source and index mapping are recorded in the manifest. The stabilizer uses sample-attached K, not a UI zoom value.
- Capture zoom and stabilization crop remain independent settings. A large capture zoom can reduce detail and increase the need for stabilization crop.

## Verified

- 18 Swift tests passed, including virtual-camera factor mapping, restricted ranges and logarithmic slider endpoints.
- 11 Rust tests passed; one preexisting physical-Metal comparison remains ignored in the default run. The new native-transform test varies focal length continuously and abruptly with zero rotation and verifies that 1x stabilization crop preserves the input zoom instead of cancelling it.
- iPhone Release and Simulator Debug build; static linkage audit passed.
- Installed and version-read 0.7.0 (16) on iPhone 16 / iOS 18.2.1 (YJJY), then launched successfully.
- Fresh configuration readback: BuiltInDualWideCamera, UltraWide + Wide constituents, active Wide, raw zoom 2 with display multiplier 0.5, 3840x2160 at 60 fps, intrinsic delivery enabled, active video stabilization off, session system clock available. This is configuration evidence; it does not yet verify every recorded frame.

## Remaining real-scene acceptance

Record a short 4K30 clip using pinch/slider through 0.5x → 1x → 2x → 0.5x, first stationary and then walking. Verify actual K presence/change against frames, continuous source/IMU times, observed constituent switches, drop counts, output/audio, and preservation of the intentional zoom. Test daylight and a nearby object separately.

The present renderer still uses uncalibrated zero residual distortion and no rolling-shutter correction. Cross-camera orientation/extrinsics, viewpoint/parallax changes, image fusion and OIS effects are not solved by supplying K alone. A full cross-lens stabilization-quality claim requires the real-scene checks above; the existing 4K60 buffer-pressure issue is also separate from this feature.

## Apple references

- [Zoom controls and smooth ramps](https://developer.apple.com/documentation/avfoundation/capture-device-zoom)
- [Virtual-device switch-over zoom factors](https://developer.apple.com/documentation/avfoundation/avcapturedevice/virtualdeviceswitchovervideozoomfactors)
- [Active primary constituent](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activeprimaryconstituent)
- [Intrinsic delivery support](https://developer.apple.com/documentation/avfoundation/avcaptureconnection/iscameraintrinsicmatrixdeliverysupported)
