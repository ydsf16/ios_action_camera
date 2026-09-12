# MotionCam · iPhone 运动相机

首版交互：**拍摄 → 预览 → 保存**。支持调节稳定强度、裁切倍数、动态裁切与黑边；保持水平后续加入。见[已确认 UI](docs/design/README.md)。

## 当前版本：0.6.0（素材管理与界面整理）

素材页按日期分组，可长按删除、批量选择并查看预计释放空间；删除会一并清理原片、稳定结果和运动数据，保留系统相册中的独立副本。处理中的素材先取消并等待工作线程退出，再删除。播放页保留全屏画面，顶部切换「原片／稳定」，底部「调整／导出」，更多菜单提供素材信息和删除。见[设计说明](docs/design/library-refinement.md)与[验证记录](docs/library-validation.md)。

点击取景器顶部格式或进入设置，可选择当前镜头支持的 **1080p / 4K × 24 / 30 / 60 fps**。
选择会保留，录制中不可更改。“稳定与导出参数”可单独选择 **1080p（1920×1080）/ 2.8K（2816×1584）**。
导出保留原帧率和时间戳，横竖屏自动适配，输出不超过原片尺寸；1080p 原片不会放大到 2.8K。

曝光新增“室内折中（≤10 ms）”：保留系统自动曝光和 ISO，限制长曝光拖影。
它设置曝光上限，不固定快门，也不保证所有 LED 灯光下均无频闪；仍可选择系统自动或 ≤5 ms 运动模式。

- SwiftUI 相机界面；后置超广角／广角，录制期间镜头固定。
- 自动横竖屏，开始录制时确定该段方向；只改变显示矩阵，保留原始像素／内参／IMU 坐标。
- 支持选择原生分辨率及帧率，默认 4K / 30fps / SDR；H.264 视频、AAC 声音。
- 视频与同步运动数据保存到独立素材文件夹。
- 原片列表、播放、保存到相册；完整文件通过“文件”App 或 Finder 导出。
- 请求关闭视频防抖，记录实际生效状态；保持原始像素方向并记录逐帧内参。
- 连续自动对焦（不支持的镜头显示固定对焦）；曝光模式可选系统自动、室内折中（最长 10 ms）或运动清晰（最长 5 ms），保留自动 ISO。视频与 IMU 使用系统时钟映射同步。
- 处理权限拒绝、空间不足、视频丢帧、传感器中断、相机中断、退后台收尾。

录制结束后自动按导出设置生成稳定视频，保留原片与原声音。素材预览可切换原片／稳定结果，并保存当前版本到相册。旧素材可以手动点击「生成稳定视频」。

Gyroflow 1.6.3 核心读取实际录制时钟映射、原始陀螺仪和逐帧完整内参，使用可调平滑与裁切；没有额外视觉时间补偿。当前直接在 IOSurface 的 NV12 纹理上执行 Metal 重投影，保留 Lanczos4 采样，最多 3 帧并行。应用不再做逐帧 BGRA 转换、GPU 上传或读回；Apple 框架负责视频解码、编码和音频封装。姿态、平滑和裁切继续由 CPU 计算。性能数据与边界见 [性能验证](docs/performance-validation.md)。

当前仅前台处理，开始拍摄时暂停处理，结束后继续；退后台取消当前任务，可回到素材页重试。暂未实现任务持久化、地平线锁定、滚动快门校正与热管理。镜头残余畸变尚未标定，不能把逐帧 K 当成完整镜头标定。手机性能、同步精度、音画方向仍需真机验收。系统 OIS 是否关闭不能由 `.off` 保证。

## 在 iPhone 运行

1. 先按下方说明编译 Rust 核心，再用 Xcode 打开 `MotionCam.xcodeproj`，选择 `MotionCam` scheme。
2. 连接并信任 iPhone（iOS 17+），按系统提示开启开发者模式。
3. 在 Signing & Capabilities 中确认你的开发团队。工程已沿用 SensorRecorder 的团队配置，Bundle ID 为 `com.grape.MotionCam`。
4. 选择 iPhone，点击 Run，允许相机、麦克风和运动访问。
5. 拍摄约 15 秒：静止几秒、左右转动、走几步，再停止。
6. 点击左下角素材入口，等待稳定处理，切换原片与稳定结果并检查声音；需要时保存到相册。
7. 从“文件 → 我的 iPhone → MotionCam → Recordings”导出整段文件夹，按[真机验收](docs/recording-validation.md)检查。

模拟器可用合成素材验证处理与界面，不支持本项目的真实 Camera / IMU 录制。

## 开发与验证

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# 先安装 Rust stable / rustup，然后：
./scripts/build_engine.sh aarch64-apple-ios aarch64-apple-ios-sim
cargo test --manifest-path Engine/Cargo.toml --release --locked
swift test
python3 -m unittest discover -s Tests/AuditTests -v
xcodebuild -project MotionCam.xcodeproj -scheme MotionCam \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build-device CODE_SIGNING_ALLOWED=NO
```

首次构建需要联网获取 Gyroflow 子模块和锁定的 Rust 依赖。构建脚本检查上游提交并应用 `patches/gyroflow-full-intrinsics.patch`，因此子模块显示本地修改是预期状态；完整修改以该补丁随源码发布。成品编译后运行 `python3 scripts/check_app_linkage.py <MotionCam.app路径>`，确保未误连开发机上的动态库。新增 Swift 文件后运行 `python3 scripts/generate_project.py` 更新工程；生成文件一并提交。

## 结构

| 路径 | 职责 |
| --- | --- |
| `App/Capture` | AVFoundation、CoreMotion、文件录制和生命周期 |
| `Sources/CaptureCore` | 数据契约、时间轴与 CSV 写入；可供其他采集产品复用 |
| `App/Views` | 拍摄、素材、原片／稳定结果预览与相册保存 |
| `App/Stabilization` | 前台队列、视频读写、原音频保留与取消 |
| `Engine` / `vendor/gyroflow` | Rust C 接口与固定版本 Gyroflow 核心 |
| `Tests/CaptureCoreTests` | 时间戳、丢帧间隔、运动预缓存和文件收尾测试 |
| `docs/recording-format.md` | 录制包、坐标、时间与内参约定 |

本项目依据 SensorRecorder 已验证的采集约定独立实现；现有 SensorRecorder 工程未修改，两者目前没有共享同一个二进制采集库。待录制验收后再提取共享模块。

## 分步实现

1. **录制闭环**：已实现。
2. **稳定处理**：0.2.0 已接通 CPU 核心与拍后导出，验证范围见 [处理验收](docs/stabilization-validation.md)。
3. **简单调整**：已支持强度、最大裁切、动态裁切与允许黑边；重力保持水平待加入。
4. **处理与导出队列**：拍摄优先、进度、热管理、可恢复任务。
5. **产品化**：机型覆盖、性能验收、付费与发布。

录制素材仅保存在设备上；本版本不包含分析 SDK、云上传或收费功能。

## 许可证

GPL-3.0-or-later，附 App Store 许可，详见 [LICENSE](LICENSE) 与 [第三方说明](THIRD_PARTY_NOTICES.md)。本仓库提供应用、核心补丁、依赖锁文件和构建脚本；商店发布前仍需归档匹配源码并整理全部依赖声明。

## 方向与稳定参数

- 设置 → 默认稳定参数：保存之后新建任务使用的默认值。
- 素材 → 预览 → 调整稳定参数：针对该素材重新生成，原片和上一版结果保留到成功替换。
- 稳定强度 0–100%，最大裁切 1–5×。动态裁切开启时是倍数上限，关闭时使用该固定倍数。
- 允许黑边开启时保留选定平滑强度，在裁切不足的区域填黑；关闭时逐步降低平滑强度，仍无法满足上限则报错，不悄悄突破裁切上限。极端运动下的边缘覆盖仍需实拍验收。
- 每段保存 stabilization-options.json；stabilization.json 中记录完成输出的选项。
