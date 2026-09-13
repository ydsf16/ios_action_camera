# Focus and composition grid — 0.10.0 (23)

## Behavior

- Default continuous autofocus remains enabled. Tap the viewfinder to set its
  focus point and continue automatic focusing; long press for 0.5 seconds to
  autofocus once and then lock. Another tap resumes continuous autofocus.
- The yellow indicator stays visible while focusing for a lock and once locked.
  Tracking/unsupported-lens notices disappear after two seconds. Locked status
  is displayed only after actual device focusMode reports locked and focus
  adjustment has ended; no fixed delay simulates successful autofocus.
- Focus requests use AVCaptureVideoPreviewLayer coordinate conversion, which
  accounts for aspect-fill cropping and orientation. Requests include the preview
  device ID; stale requests from replaced inputs are rejected. These normalized
  points never alter the native image, K, or IMU coordinate conventions.
- Pinch zoom, tap and long press share the preview's UIKit gesture handling;
  overlays and camera buttons remain separate. These operations are allowed
  during recording without stopping or reconfiguring the capture session.
- Changing the physical input/format or leaving the camera restores normal
  focus. Automatic primary-lens switches restore autofocus with a notice;
  the old lens lock is not presented as a lock on the new lens. Exposure-setting
  changes preserve the current focus selection.
- Settings → Shooting aids → Grid starts off and persists through AppStorage.
  The grid draws thirds of the camera image using preview-layer conversion,
  clipped to the full-screen viewfinder, and updates during layout/rotation.
  Its layers and the focus indicator are preview-only; they never enter the
  recording or stabilization pixel pipeline.

## Apple references

- [Point of interest](https://developer.apple.com/documentation/avfoundation/avcapturedevice/focuspointofinterest)
- [Preview coordinate conversion](https://developer.apple.com/documentation/avfoundation/avcapturevideopreviewlayer/capturedevicepointconverted(fromlayerpoint:))
- [One-shot autofocus](https://developer.apple.com/documentation/avfoundation/avcapturedevice/focusmode-swift.enum/autofocus)

The installed iPhone SDK's AVCaptureDevice.h also explicitly specifies that
one-shot autofocus transitions to locked after its scan. Device configuration
locks protect all focus-point/mode writes.

## Validation, 2026-09-13

- Signed iPhone Release and simulator Debug builds passed before device checks.
- Simulator settings showed Grid initially off. Toggling it displayed four
  reference lines behind the camera overlays; the enabled preference was read
  back from the app container. The grid remained visible after terminating and
  relaunching the app. The portrait screen was visually inspected.
- A DEBUG-only device regression runner used the same CaptureService.focus
  entry point as preview gestures on the connected iPhone 16. The actual focus
  point became (0.37, 0.61), mode 2 (continuous); a lock request completed in
  mode 0 (locked); a stale preview-device request changed neither mode nor point;
  tapping again restored mode 2. The same session clock identity, format/frame
  durations, exposure mode/limit, output rotation and stabilization mode were
  retained throughout. No recording was created by this test.
- Real-device optical sharpness, physical gesture feel, off-center focus mapping
  in all four phone orientations, and automatic cross-lens behavior still need
  hands-on scene testing. The regression runner does not simulate those results.

Device check result: `/tmp/roamshot-0100-focus-validation.json`.
Runner: a Debug build launched with `--focus-controls-test`; writes
`Documents/focus-controls-validation.json`. It is excluded from Release builds.

Final Release 0.10.0 (23) was installed on the iPhone 16.
The version/build were read back from the device; Grid remained off, capture
remained 4K/60 fps, and output remained 2.8K. Static-linkage audit passed.

The final Release launch command timed out. A separate process readback did not confirm RoamShot running. Installation is verified; open the final app manually.
