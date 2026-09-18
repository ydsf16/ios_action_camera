# 曝光与前后台恢复验证

## 改动

- 曝光保留已有持久化标识，新增 fastMotion（≤2 ms），默认仍为 motion（≤5 ms）。选择项简化为自动 / ≤10 ms / ≤5 ms / ≤2 ms，场景建议放在说明中。
- 前后台恢复保持现有相机停止收尾及回前台启动机制，并同步初始队列状态。
- 后台取消的处理任务保留原参数，等待旧工作线程退出后自动重新排队，避免两个任务同时写同一素材。
- 手动取消和删除清除自动重试意图。进程被系统终止后的恢复、编码帧级断点续传不包含在本次实现中。

## 自动验证

CaptureCore 28 项测试通过。Release iOS 无签名构建通过。以下脚本使用真实生产队列与可控的替代处理器验证调度，不能替代真实 Metal 导出及手机前后台验收：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun swiftc -parse-as-library Sources/CaptureCore/*.swift \
  App/Stabilization/StabilizationJobs.swift scripts/ForegroundQueueValidation.swift \
  -o /tmp/roamshot-foreground-validation
/tmp/roamshot-foreground-validation
```

通过：后台取消后再回前台、旧任务退出前快速回前台、后台前后主动取消、删除正在取消的任务、原片保持不变。

## 待真机验证

- 每个曝光选项在支持的格式上生效，特别是明亮室外 4K60 的实际曝光与帧率。
- 录制时进入后台，回前台确认原片和声音正常收尾、取景自动恢复。
- 稳定处理中进入后台再返回，自动重新处理成功且上一版输出保留。
- 系统锁屏、相机权限中断、素材页前后台、长视频及低空间场景。

本次尚未安装到用户手机，未上传新构建或改变正在审核的版本。
