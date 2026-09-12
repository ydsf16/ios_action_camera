# 录制包 v1

```text
MC_日期_时间_随机ID/
  manifest.json       配置、时间原点、状态、计数和警告
  video.mov           H.264 + AAC；正常封装完成后才使用此文件名
  frames.csv          每个成功写入的视频帧
  audio.csv           每个成功写入的音频缓冲区
  gyro.csv            原始角速度 rad/s
  accelerometer.csv   原始加速度 g（含重力）
  gravity.csv         CoreMotion 重力 g、姿态四元数 x/y/z/w
  drops.csv           采集或编码丢帧记录
```

录制过程中视频名为 `video.partial.mov`。`manifest.status` 为 `recording`、`complete` 或 `failed`。异常时保留现有文件供诊断；进程被强制终止时，未封装视频不保证可播放，缓存中的最后部分遥测数据也可能尚未写入。不得把保留文件等同于恢复成功。

## 时间

- 原始视频 PTS 用整数 `pts_value / pts_timescale` 记录，避免仅存低精度小数。
- `host_sec` 每帧经 `CMSyncConvertTime(pts, from: session.synchronizationClock, to: CMClockGetHostTimeClock())` 转换；转换失败停止录制，不退回未转换 PTS。
- `video_sec = source_pts - firstVideoPTS`。Writer 从同一个 `firstVideoPTS` 开始，丢帧保留时间间隔。
- 音频使用相同会话 PTS 原点，保留实际缓冲区时间；早于首视频帧的音频不写入。
- IMU 时间为 CoreMotion 原始启动后秒数。开始录制前保留约 0.5 秒预缓存，停止后再收集约 0.15 秒尾部数据。
- 不分别把视频和 IMU 首时间归零；不默认添加经验 offset 或固定 ppm 补偿。
- 分析工具应从每帧 `host_sec ↔ video_sec` 建立映射，必要时用整段时钟对拟合并报告残差；视觉同步验证属于下一阶段实测。
- 请求 IMU 100Hz；实际采样率、覆盖范围和缺口需以文件为准。

## 坐标与成像

- CoreMotion 设备轴原样保存：竖屏时 x 向屏幕右侧、y 向顶部、z 向屏幕外；不取负、不预先旋转。原始加速度与重力分别保存，不把异步采样按行拼接。
- 重力使用 `.xArbitraryZVertical`，四元数顺序为 `qx,qy,qz,qw`。设备坐标到镜头坐标的映射留给处理适配层明确实现并实测。
- 视频数据连接旋转 0°、关闭镜像；编码保留原始横向像素。竖屏展示仅用视频轨道的 +90° transform，元数据显式记录。
- 内参从每个 sample buffer 附件读取，CSV 按**行优先**存储 k00…k22，对应未旋转编码像素；缺失记 `nan`。显示旋转时不能直接把原始 K 当成竖屏 K。
- 曝光、ISO、对焦和倍率是采集回调时读取的设备状态，不宣称与该帧曝光完全精确对应。
- 显式 `.off` 并逐帧记录 `activeVideoStabilizationMode.rawValue`；不保证 OIS 停止。
- 不提供虚构畸变系数或滚动快门参数。未标定 `rollingShutterReadoutMS` 为空。

## 依据

- [Apple：采集会话时钟](https://developer.apple.com/documentation/avfoundation/avcapturesession/synchronizationclock)
- [Apple：视频与 Writer 会话起点](https://developer.apple.com/documentation/avfoundation/avassetwriter/startsession(atsourcetime:))
- [Apple：逐帧内参启用条件](https://developer.apple.com/documentation/avfoundation/avcaptureconnection/iscameraintrinsicmatrixdeliveryenabled)
- 现有 SensorRecorder 参考版本：[1.5 采集实现](https://github.com/ydsf16/ios_sensor_recorder/tree/aeab12eda455d4929676ed48a55da076acbabbe4)

此包目前不是 SensorRecorder 原 CSV 布局，也不是直接可打开的 Gyroflow 工程；下一阶段将添加适配器。

## 0.2.3 录制策略

- 支持时使用 `continuousAutoFocus`；固定对焦镜头不伪报自动对焦开启。
- 在选择格式后、录制开始前设置 `continuousAutoExposure` 和 `activeMaxExposureDuration ≤ 0.005 s`，ISO 继续自动调节。曝光上限通过 Apple 的自动曝光上限 API 设置，不以降低帧率实现。
- 视频 PTS 使用 `CMSyncConvertTime` 映射到 host clock，CoreMotion 保留原始采样时间；缺少采集同步时钟时拒绝录制。这是系统时间戳同步，未实现共同硬件触发采样。
- manifest 新增可选字段 `maximumAutoExposureSeconds`、`continuousAutoFocusEnabled`、`systemTimestampSynchronizationEnabled`、`hardwareTriggeredSynchronizationEnabled`，兼容旧录制包；后者明确为 false。
- `frames.csv` 中已有的曝光／ISO／焦点列仍是回调时观察值，不承诺逐帧精确曝光元数据。
- 前台相机就绪后，将配置读回值写入 Documents/capture-configuration.json，供真机验证。

官方说明：[自动曝光上限](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activemaxexposureduration)、[采集同步时钟](https://developer.apple.com/documentation/avfoundation/avcapturesession/synchronizationclock)。

## Exposure policy (0.4.1)

`exposurePolicy` is an optional manifest field: `motion` retains continuous AE with
an explicit 5 ms maximum; `automatic` restores AVFoundation's format-specific AE
maximum with `activeMaxExposureDuration = .invalid`. The latter lets the system
choose exposure and ISO for indoor lighting and can exceed 5 ms. It does not force
10 ms or claim universal LED/PWM flicker suppression. The earlier 5 ms default is
preserved until the user selects a different policy; selection persists and applies
to preview and recording, including lens changes. Configuration is locked while
recording. The actual finite AE maximum remains in `maximumAutoExposureSeconds`;
per-frame observed duration/ISO remain in frames.csv. Timestamp mapping is unchanged.

The settings page now displays the installed bundle version. CameraPreview updates
rotation/stabilization only when changed, and does not subscribe to processing-job
progress. These guard against redundant preview reconfiguration; the user's elevator
lighting symptom is specifically addressed through the exposure policy, not claimed
resolved by UI changes alone.

## Exposure policy (0.4.2)

`balanced` adds a 10 ms continuous-AE maximum between the existing `automatic` and
`motion` choices. It is an exposure ceiling, not a fixed 1/100 s shutter or a
measured flicker-frequency lock. ISO remains automatic; low light may produce
more noise or underexposure at the device's ISO limit. Existing saved choices and
the original `motion` fallback are preserved. `capture-configuration.json` also
includes `observed_iso` beside the observed duration for device validation.

The user reported that `automatic` eliminated visible elevator-light flicker but
increased motion blur. The new 10 ms ceiling is a candidate compromise, pending
same-scene device validation; no exposure measurements of that scene are yet
available. A 1/100 s shutter is a common choice for 50 Hz lighting, while LED PWM
may require another duration. See [Sony's shutter recommendations](https://www.sony.com/electronics/support/camcorders-and-video-cameras-hard-drive-camcorders/articles/00122281).
