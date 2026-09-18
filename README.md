# RoamShot

**把 iPhone 变成运动相机。** RoamShot 在拍摄视频的同时记录运动数据，拍摄后在手机上生成稳定视频。适合旅行、徒步、日常走拍，以及放大拍摄后的防抖处理。

使用流程：**拍摄 → 查看稳定结果 → 调整效果 → 保存到相册**。原片始终保留，直到用户主动删除素材。

## 功能

- 全屏取景、自动横竖屏、自动对焦、轻点对焦、长按锁定与默认开启的九宫格。
- 支持设备可用的 1080p / 4K、24 / 30 / 60 fps；默认 4K60。
- 双指与滑条变焦，初始优先 0.5×，不支持时使用 1×；上限 10×（受设备能力限制）；兼容设备使用虚拟相机自动切换物理镜头。
- iOS 17.2+ 接入系统拍摄按键控制录像；iOS 18+ 兼容设备支持相机控制按钮滑动变焦。外接设备的支持边界见[控制器说明](docs/capture-controls-validation.md)。
- 曝光选项：自动、≤10 ms、≤5 ms、≤2 ms；默认 ≤5 ms。短曝光减少运动模糊，需要充足光线；灯光下可能出现闪烁。
- 自然、标准、强力三种稳定效果；重力水平锁定放在高级设置，默认关闭。
- 高级设置支持平滑强度、保留画面（宽高的 20%～100%）、动态缩放与允许黑边。动态裁切指定最少保留比例，固定裁切指定实际保留比例；默认 50%。
- 未允许黑边时，Gyroflow 会在接近裁切上限的时间区间局部减弱稳定修正，并平滑过渡；不会因短暂剧烈运动降低整段视频的稳定强度。
- 输出可选 1080p 或 2.8K，默认 2.8K，保留原片时间戳与声音。输出尺寸在生成前设置；保存到相册直接使用已生成的视频。
- 素材管理支持原片与稳定结果播放、系统分享、重新处理、单段及批量删除。分享当前选中的视频，无需先保存到相册。

免费版每段最多录制 **60 秒**，到时自动停止并保存，不限次数；稳定处理与导出免费、无水印。设置中的 **RoamShot Pro** 一次买断解除单段录制时长限制，支持恢复购买。拍摄时不弹出购买提示，实际价格以商店为准。

## 运行要求与使用边界

- iPhone，iOS 17 或更新版本；拍摄规格由设备和镜头决定。
- 允许相机、麦克风和运动访问；保存到相册时请求添加照片权限。
- 所有素材与处理均在本机完成，无需登录，不包含云端处理或分析 SDK。
- 稳定处理仅支持本 App 同步记录运动数据的素材。
- 录制开始时确定视频方向；录制中转动手机不会改变该段文件的显示方向。
- 几何稳定无法消除已经拍入的运动模糊。高倍率、暗光、镜头切换和剧烈运动仍可能降低效果。
- 逐帧内参不等于完整镜头标定；当前未实现滚动快门校正。请求关闭系统视频防抖，不代表能够保证所有设备的 OIS 都关闭。

切到后台会停止录制并保存。回到拍摄页面时自动恢复取景；保持素材页时不会强制跳回相机。处理中切到后台会取消本次导出并保留任务，回前台自动重新处理；目前会从头生成，不是逐帧断点续传。手动取消不自动重启。任务队列目前仅保存在进程中，不保证系统终止 App 后自动恢复。

**当前采用拍后稳定。** 拍摄时暂停已有处理，优先保证采集。边录边稳定仍处于设计阶段，见[流式稳定方案](docs/design/streaming-stabilization.md)。

## 技术结构

```text
AVFoundation 视频 / 音频 + CoreMotion IMU + 逐帧内参
                         ↓
              本机录制包（原片与传感器数据）
                         ↓
         Gyroflow 姿态估计、平滑与裁切（CPU）
                         ↓
           NV12 / IOSurface 重投影（Metal）
                         ↓
           AVFoundation 编码与音频封装
                         ↓
                 稳定视频 → 系统相册
```

采集使用相机到系统时钟的映射对齐视频与 IMU，保留原始像素、传感器轴向及逐帧内参。默认处理不额外引入视觉估计的时间偏移。Metal 直接处理 NV12 纹理，最多三帧并行，应用避免逐帧 BGRA 转换与 GPU 读回。iPhone 16 的稳定输出已观察到 Apple 硬件 H.264 编码路径；性能受设备、分辨率及温度影响，见[实测记录](docs/performance-build29.md)。

| 目录 | 内容 |
| --- | --- |
| `App/Capture` | 相机、运动数据、录制与生命周期 |
| `App/Stabilization` | 处理队列、Metal 重投影、视频读写 |
| `App/Views` | 拍摄、设置、素材及播放界面 |
| `Sources/CaptureCore` | 数据格式、时间轴、采集与稳定参数 |
| `Engine` | Gyroflow 的 Rust / C 接口 |
| `vendor/gyroflow` | 固定提交的上游核心 |
| `patches` | 随应用发布的上游修改 |
| `Tests` / `scripts` | 自动测试、构建与验证工具 |
| `docs` | 设计、数据契约、性能及发布记录 |

## 构建与运行

需要 macOS、完整 Xcode、Rust stable / rustup。首次构建需要联网获取子模块及锁定依赖。

```sh
git clone --recurse-submodules https://github.com/ydsf16/ios_action_camera.git
cd ios_action_camera
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
./scripts/build_engine.sh aarch64-apple-ios aarch64-apple-ios-sim
open RoamShot.xcodeproj
```

在 Xcode 中选择 `RoamShot` scheme，为自己的设备配置开发团队和签名，连接已信任且开启开发者模式的 iPhone 后运行。模拟器可验证界面和合成素材处理，不能验证真实相机及 IMU 采集。

构建脚本固定 Gyroflow 提交并应用 `gyroflow-full-intrinsics.patch` 和 `gyroflow-metal-validation.patch`。因此子模块显示本地修改属于预期情况；不要将其直接重置。新增 Swift 文件后运行 `python3 scripts/generate_project.py` 更新工程。

## 验证

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
cargo test --manifest-path Engine/Cargo.toml --release --locked
python3 -m unittest discover -s Tests/AuditTests -v
xcodebuild -project RoamShot.xcodeproj -scheme RoamShot \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build-device CODE_SIGNING_ALLOWED=NO
```

打包后运行 `python3 scripts/check_app_linkage.py <RoamShot.app路径>` 检查动态库依赖。真机验收应使用相同设备和素材，对比录制帧率、输出尺寸、声音、处理耗时和温度；构建通过不能替代真机验收。

- [录制数据格式与时间、轴向约定](docs/recording-format.md)
- [真机录制验收](docs/recording-validation.md)
- [稳定参数与适配](docs/simple-stabilization-validation.md)
- [发布构建及审核记录](docs/app-store/release-validation.md)

开发进展与历史验证记录保存在 `docs/`；发布源码通过 Git 版本标签定位。

## 开源许可

本项目采用 GPL-3.0-or-later，并附 App Store 许可，详见 [LICENSE](LICENSE)、[第三方说明](THIRD_PARTY_NOTICES.md)及 [依赖许可](THIRD_PARTY_LICENSES.txt)。源码发布包含应用、固定的上游核心、补丁、依赖锁文件和构建脚本。
