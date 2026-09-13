# Camera orientation — 0.7.1 (17)

The old preview used `UIWindowScene.interfaceOrientation`, while the record button
sampled `UIDevice.orientation` independently. A locked interface is not a reliable
capture-orientation source. These paths are replaced with Apple's
`AVCaptureDevice.RotationCoordinator` on iOS 17+.

- Observe separate capture and preview angles on main, including their initial values.
- Recreate the coordinator when the input device changes, including physical/virtual
  camera fallback. Ignore callbacks for an input that has already been replaced.
- Apply preview rotation only to the preview connection. UI refreshes do not restart
  capture or reapply unchanged rotation/stabilization settings.
- Snapshot the capture angle as a quarter turn when recording begins and retain that
  display transform for the entire clip. Wait for an initial angle rather than silently
  assuming portrait. The video-data connection remains at zero rotation; K, IMU axes,
  and timestamps keep their native contract. Stabilized export retains the source transform.
- With iOS portrait orientation lock enabled, the interface stays portrait. Capture
  orientation still follows the camera's physical orientation at recording start.
  Disable the system lock to let the entire interface rotate.
- `capture-configuration.json` includes the rotation source and latest capture/preview
  angles for device verification. These angles may legitimately differ.

## Verification

- 18 existing Swift tests pass; iPhone Release build and static-linkage audit pass.
- The native Metal exporter was exercised with copied 4K60 synthetic fixtures at
  0, 90, 180, and 270 degrees. Each output decodes to 180 frames with preserved PTS
  and an audio track. Display dimensions are 2816×1584 for landscape and 1584×2816
  for portrait. Original fixture contents are unchanged. This verifies file/processing
  orientation, not physical rotation of a phone.
- Installed and version-read 0.7.1 (17) on iPhone 16 / iOS 18.2.1 (YJJY), then
  launched successfully. Fresh configuration reports RotationCoordinator capture
  and preview angles of 90 degrees while portrait, Dual Wide capture at 4K60,
  motion exposure policy, intrinsic delivery enabled, and system stabilization off.
  Physical landscape/portrait transitions remain for hands-on acceptance.

Reproduce with:

```sh
scripts/benchmark_export.sh --orientation-test /path/to/synthetic/MC_fixture_4K60
```

Real-device acceptance: start separate portrait and landscape recordings with the
system orientation lock both on and off. Check the original, stabilized movie,
preview, and recorded `displayRotationDegrees`. Repeat after changing format/lens
and after returning from the library. A single clip intentionally retains the
orientation selected at its start.

References: [rotation coordinator](https://developer.apple.com/documentation/avfoundation/avcapturedevice/rotationcoordinator),
[writer transform for video-data capture](https://developer.apple.com/documentation/avfoundation/avcapturedevice/rotationcoordinator/videorotationangleforhorizonlevelcapture).
