# MotionCam · iPhone 运动相机

首版交互：**拍摄 → 预览 → 保存**。后续调整只提供「自然／标准／更稳」和「保持水平」。见[已确认 UI](docs/design/README.md)。

## 当前版本：0.1.0（录制原型）

- SwiftUI 相机界面；后置超广角／广角，录制期间镜头固定。
- 优先 4K / 30fps / SDR，镜头不支持时回退 1080p / 30fps；H.264 视频、AAC 声音。
- 视频与同步运动数据保存到独立素材文件夹。
- 原片列表、播放、保存到相册；完整文件通过“文件”App 或 Finder 导出。
- 请求关闭视频防抖，记录实际生效状态；保持原始像素方向并记录逐帧内参。
- 处理权限拒绝、空间不足、视频丢帧、传感器中断、相机中断、退后台收尾。

当前保存**原片**，尚未集成 Gyroflow 或稳定预览。首版仅竖屏拍摄，自动曝光；实时性能、同步精度、音画方向需真机验收。系统 OIS 是否关闭不能由 `.off` 保证。

## 在 iPhone 运行

1. 用 Xcode 打开 `MotionCam.xcodeproj`，选择 `MotionCam` scheme。
2. 连接并信任 iPhone（iOS 17+），按系统提示开启开发者模式。
3. 在 Signing & Capabilities 中确认你的开发团队。工程已沿用 SensorRecorder 的团队配置，Bundle ID 为 `com.grape.MotionCam`。
4. 选择 iPhone，点击 Run，允许相机、麦克风和运动访问。
5. 拍摄约 15 秒：静止几秒、左右转动、走几步，再停止。
6. 点击左下角素材入口，播放并检查声音；需要时保存到相册。
7. 从“文件 → 我的 iPhone → MotionCam → Recordings”导出整段文件夹，按[真机验收](docs/recording-validation.md)检查。

模拟器可检查界面与空状态，不支持本项目的真实 Camera / IMU 录制。

## 开发与验证

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
python3 -m unittest discover -s Tests/AuditTests -v
xcodebuild -project MotionCam.xcodeproj -scheme MotionCam \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build-device CODE_SIGNING_ALLOWED=NO
```

无需第三方依赖。新增 Swift 文件后运行 `python3 scripts/generate_project.py` 更新工程；生成文件一并提交。

## 结构

| 路径 | 职责 |
| --- | --- |
| `App/Capture` | AVFoundation、CoreMotion、文件录制和生命周期 |
| `Sources/CaptureCore` | 数据契约、时间轴与 CSV 写入；可供其他采集产品复用 |
| `App/Views` | 拍摄、素材、原片预览与相册保存 |
| `Tests/CaptureCoreTests` | 时间戳、丢帧间隔、运动预缓存和文件收尾测试 |
| `docs/recording-format.md` | 录制包、坐标、时间与内参约定 |

本项目依据 SensorRecorder 已验证的采集约定独立实现；现有 SensorRecorder 工程未修改，两者目前没有共享同一个二进制采集库。待录制验收后再提取共享模块。

## 分步实现

1. **录制闭环**：本次实现，下一步真机验证。
2. **稳定处理**：接入核心引擎，先对照桌面相同素材输出。
3. **简单调整**：三档稳定程度、重力保持水平、自动动态裁切。
4. **处理与导出队列**：拍摄优先、进度、热管理、可恢复任务。
5. **产品化**：机型覆盖、性能验收、付费与发布。

录制素材仅保存在设备上；本版本不包含分析 SDK、云上传或收费功能。
