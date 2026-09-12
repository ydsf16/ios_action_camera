# 素材删除与界面验证 · 0.6.0 (14)

2026-09-12，在 Mac M1 / Xcode 26.3 与专用 iPhone 17 Pro / iOS 26.3 模拟器执行。手机用于其他工作，本轮没有连接、安装或启动真机 App。

## 已通过

- iOS Simulator Debug 与 iPhone Release 构建；静态链接检查无外部 Gyroflow dylib 或开发机依赖。
- CaptureCore 15 项测试通过，包括完整素材包删除、其他素材与独立导出副本保留、目录外路径和符号链接保护、混合成功／失败结果、重复删除与未完成素材展示。
- `DeletionQueueValidation.swift` 编译生产队列，替换慢速处理器模拟取消后继续写尾部文件，验证删除必须等待完成、禁止重新入队、移除选中待处理项、保留无关队列、暂停状态删除和非法目标拒绝。
- `ProcessingCancellationValidation.swift` 使用真实 Gyroflow / Metal / AVFoundation、4K60 合成视频与 AAC 声音：取消保留原片与上一版输出并清理临时文件；删除正在导出的素材后无目录、文件或队列状态残留。
- 模拟器素材网格按今天／昨天分组；批量选择数量和约占空间正确，取消确认保留文件和选择。
- 从播放页删除 1 段合成素材后返回网格；再批量删除 2 段，只移除选中目录，其余 3 段保留。
- 导出稳定视频后显示「已保存到相册」。模拟器 DCIM 中的视频 SHA-256 与源稳定视频相同；删除 App 内素材后该副本仍保留。
- 原片／稳定切换会同步更新导出按钮文案；在 2.5 秒切换，播放器仍停留在 2.5 秒。
- 横竖屏播放、点击隐藏／恢复控件经过实际界面检查；保持 resizeAspect，编码画面及边缘未被界面缩放裁掉。

界面截图见[设计说明](design/library-refinement.md)。彩条为合成素材，没有将用户录制视频放入仓库。

## 复现命令

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
xcrun swiftc -parse-as-library Sources/CaptureCore/*.swift \
  App/Stabilization/StabilizationJobs.swift scripts/DeletionQueueValidation.swift \
  -o /tmp/motioncam-deletion-queue-validation
/tmp/motioncam-deletion-queue-validation
```

真实处理器验证需要先构建主机 Rust 静态库，并将 `Stabilize.metal` 编译为验证可执行文件旁的 `default.metallib`：

```sh
xcrun swiftc -O -parse-as-library -import-objc-header Engine/include/MotionCamGyroflow.h \
  Sources/CaptureCore/*.swift App/Stabilization/MetalStabilizer.swift \
  App/Stabilization/StabilizationProcessor.swift App/Stabilization/StabilizationJobs.swift \
  scripts/ProcessingCancellationValidation.swift Engine/target/release/libmotioncam_gyroflow.a \
  -lc++ -liconv -framework Metal -framework QuartzCore -framework Security \
  -framework SystemConfiguration -o /tmp/motioncam-validation/cancellation
/tmp/motioncam-validation/cancellation /path/to/synthetic/MC_fixture_4K60
```

该脚本将输入复制到独立临时目录后验证，输入不会被删除或替换。

## 仍待真机验收

- 用户手机上的触控、长按、相册权限和删除体验。
- 4K60 长录制丢帧、温度和处理速度验收延续之前记录；本轮 UI 测试不代表这些问题已解决。
