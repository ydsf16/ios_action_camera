# 0.2.0 拍后稳定验收

2026-09-12，Mac M1 / Xcode 26.3 / Rust 1.98.1。Gyroflow v1.6.3，提交 `977b843e320fd36b32db2b71f210f1f1a516f8cb`，附仓库内逐帧 K 补丁。

## 已验证

- Rust 4 项测试通过：异常时间拒绝、静止姿态与内参、动态内参改变焦距和主点、CPU 实际像素输出及缓存越界拒绝。
- Swift 6 项测试通过：原有采集数据契约，加上录制时钟对拟合与异常映射拒绝。31 ppm 仅为构造的单元测试输入，不代表手机测量值。
- Python 3 项录制审计测试通过。
- iOS arm64 与 Simulator arm64 静态核心构建成功；App iOS 签名 Debug / Simulator Debug 编译成功。
- 在 iPhone 17 Pro / iOS 26.3 模拟器，实际点击素材中的「生成稳定视频」，观察进度与稳定预览，再点击保存，界面确认「已保存到相册」。
- 合成输入为 2 秒、1920×1080、30 fps 彩色运动测试图和 440 Hz AAC 音频。输出 60 帧，起始 PTS 为 0，视频与声音时长均为 2 秒。95 个音频包的内容哈希逐包一致，原片 SHA-256 未变化。
- Mac 核心另处理了既有 SensorRecorder 实拍中的 180 帧，4K 输入、1080p 输出，检查导出的实际图像。此为核心像素通路检查，不代表当前 RoamShot 实拍同步、效果或 iPhone 性能验收。

## 已知限制

- 默认 GPU 路径在独立 CPU 缓存输入测试中输出黑帧。首版显式使用 CPU，不能宣称 Metal 加速可用。
- 自动排队只在前台运行；拍摄暂停处理，后台取消当前任务，用户可重试。初始化阶段和单帧计算不能立即抢占。
- 使用 Plain 3D 平滑和动态缩放，过大裁切尝试降低平滑强度，仍过大则报错保留原片。该策略不是严格无黑边保证，也未完成极端运动验收。
- 逐帧 K 已接入；残余畸变取零且未标定。滚动快门和地平线锁定关闭，当前不用加速度／重力参与姿态融合。
- 本轮 iPhone 连接反复中断。最后成功列出 3 段 RoamShot 录制目录，但紧接着复制素材和安装新版均失败，CoreDevice 报 1011（找不到设备）；未取得当前 RoamShot 真机录制包，也未安装此版本到手机。

## 重现模拟器导出

先按 README 编译并安装到 Apple Silicon 模拟器，然后执行：

```sh
python3 scripts/make_export_fixture.py /tmp/MC_Synthetic_Export_Test
# 用 xcrun simctl get_app_container <Simulator-UUID> com.grape.RoamShot data
# 得到 App 数据目录，将整个 MC_Synthetic_Export_Test 复制到 Documents/Recordings。
```

在 App 打开「素材 → 测试片段 → 生成稳定视频」，完成后切换原片／稳定结果，保存到相册。
检查包内 `stabilized.mov` 的分辨率、帧数、PTS、声音，以及 `stabilization.json`。
该合成包只包含导出器需要的文件，不是完整录制审计用例。

## 下一轮真机验收

1. 同一个固定物理镜头录制 15 秒：静止、左右转动、走动和拍手。
2. 检查原片／稳定成片的方向、声音、视野、稳定性；导出整包审计实际时间映射。
3. 处理过程中继续录制，检查采集丢帧、IMU 缺口、处理暂停与恢复。
4. 检查取消、退后台、重试、长片段内存与温度；按真实结果决定 GPU 优化和下一档参数。

## 0.2.1 启动修复（2026-09-12）

真机反馈打开卡住，Xcode 显示 dyld SIGABRT：`-lroamshot_gyroflow` 优先选中了 Cargo 同目录下的 dylib，App 引用了开发机绝对路径。此前「启动命令成功」不代表进程正常运行，模拟器能访问开发机文件也掩盖了缺陷。

现已改用 SDK 对应的 `.a` 完整路径强制静态链接。iOS 签名 Debug 与 Simulator Debug 编译通过，两个成品的 Mach-O 依赖检查通过；检查器也确认能拒绝原来的动态库。0.2.1（build 3）已安装到 iPhone 16 并启动，随后进程仍存在，镜像中可见拍摄界面。镜像提示不支持访问 iPhone 相机，已退出镜像；本机拍摄和处理效果仍需继续真机验收。

此轮已成功读取旧 RoamShot 包：104 帧、104 帧内参、407 个陀螺仪样本、无丢帧、IMU 完整覆盖；录制审计无错误无警告，稳定输入适配检查通过。

## 0.2.2 音视频写入等待修复（2026-09-12）

用手机新录制的 81 帧素材在模拟器复现停滞。线程采样定位在 `waitForInput(videoWriter)`，不是 Gyroflow 持续计算。此前按时间戳交替送入音视频的单循环无法独立推进各轨道；压缩音频样本可能包含多个包，视频写入反压时，音频推进和 EOF 标记也被阻塞。

改为独立音频任务持续读取／写入，音频 EOF 立即标记完成；视频 EOF 也立即标记完成，然后等待声音任务并封装。两条轨道共用取消与拍摄暂停控制。增加 `processing-status.json` 记录阶段／失败原因，Debug 构建支持 `--stabilize-recording <MC_目录名>` 通过同一队列重现导出。

修复后，同一素材在模拟器完整输出 81 帧，3840×2160 转为 1920×1080，逐帧 PTS 与原片一致，旋转矩阵保持不变，127 个可读取 AAC 包内容哈希一致；抽帧检查有正常画面。视频封装时长 2.700000 秒，原片 2.700250 秒；输出音频时长 2.698333 秒，原片 2.700229 秒，尾部时长微差仍需真机音画验收。

本轮调试期间手机 USB 断开，0.2.2 尚未安装到手机；不将模拟器完成等同于真机完成。

## 0.3.0 方向与参数（2026-09-12）

- Rust 7 项测试通过，包含半分辨率输出时 1×／5× 裁切对应的实际像素视野、固定裁切 5×、允许黑边时 1× 上限，以及不同强度确实改变运动平滑结果；Swift 6 项测试通过。
- iOS 签名 Debug / Simulator Debug 编译通过，静态链接检查通过。0.3.0 已安装并在 iPhone 16 启动；模拟器横屏界面布局检查通过，手机实际旋转录制方向仍需验收。
- 模拟器使用真实录制的 81 帧素材，实际通过 UI 将强度改为 85%，开启允许黑边，保留动态裁切和 2× 上限；重新生成完成，receipt 记录这组参数，预览返回稳定结果，上一版被成功替换。
- 像素缓冲旋转仍为 0，录制时选择显示矩阵，稳定输出沿用原片矩阵；时间戳转换与 CoreMotion 采样未改变。

### Full-screen playback and border controls (2026-09-12)

- Clip preview now opens full screen with play/pause, seeking, original/result switch,
  processing status, settings and export overlaid. Tap the picture to hide controls.
  Aspect-fit preserves the encoded frame and its stabilization borders.
- Enabling Allow black borders selects fixed 1x crop. Users can subsequently adjust
  crop or enable dynamic crop; the panel explains that either can remove borders.
  Existing saved settings remain intact; a one-tap full-FOV button resets them.
- CPU pixel regression with identical synthetic motion and smoothing: four frames
  contain 81,045 black pixels at 1x and zero at 2x. Eight Rust tests and six Swift
  tests pass. Device and simulator builds pass; static-link audit passes.
- Simulator full-screen landscape playback and overlay layout inspected. Device
  unavailable during this validation; this build has not been installed on iPhone.

### 0.3.1: Metal GPU reprojection (2026-09-12)

- Fixed pinned upstream OpenCV-standard WGSL `k2.x` reference to `params.k2.x`.
  Previously shader compilation failed but an uncaptured validation handler only
  logged the failure, and the wrapper returned success with zero pixels.
- Tracked `patches/gyroflow-metal-validation.patch` fixes that identifier, makes
  uncaptured GPU validation fail into the Rust panic boundary, and propagates
  unsuccessful GPU rendering/readback. The app requires an actual wgpu backend
  for every frame; initialization fallback to CPU cannot masquerade as GPU success.
- Metal is now the default. Host regression config can request `use_gpu:false`.
  GPU rendering currently uploads BGRA and reads back for AVFoundation encoding.
  Clock mapping, K, smoothing, crop and audio handling are unchanged.
- Nine Rust tests (including physical Mac Metal vs CPU pixels) and six Swift tests
  pass. Moving gradient frames differ by mean 0.395–0.427 / 255 across all channels;
  warm 640x360 timings vary, so these are not an iPhone speedup benchmark.
- Signed device build and static-link audit passed. Installed 0.3.1 build 7 on
  YJJY iPhone 16. First debug export was cancelled by foreground transition;
  second completed using Metal in 2.782 seconds for 81 frames / 2.7 seconds of
  recorded 4K input, with 1920x1080 encoded output and preserved portrait transform.
  Full output decodes, extracted frame inspected, all 127 audio packet hashes match.
  Originals retained and previous CPU result backed up outside the repository.
- Receipt now includes processing_seconds and Metal backend. GPU failure stops the
  job and preserves prior output. Long recordings, thermal behavior and eliminating
  transfer overhead remain future profiling work.
