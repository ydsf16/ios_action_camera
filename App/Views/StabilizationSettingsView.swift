import SwiftUI

struct StabilizationSettingsView: View {
    let directory: URL?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var jobs = StabilizationJobs.shared
    @State private var options: StabilizationOptions
    @State private var error: String?
    init(directory: URL? = nil) {
        self.directory = directory
        _options = State(initialValue: directory.map(StabilizationOptions.load) ?? StabilizationOptions.defaults())
    }
    var body: some View {
        Form {
            Section("稳定强度") {
                LabeledContent("强度", value: "\(Int(options.strength * 100))%")
                Slider(value: $options.strength, in: 0...1, step: 0.05)
                Text("越强越能抑制抖动，也会减少自然运镜。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("裁切与画面边缘") {
                LabeledContent("最大裁切", value: String(format: "%.1f×", options.maxCrop))
                Slider(value: $options.maxCrop, in: 1...5, step: 0.1)
                Toggle("动态裁切", isOn: $options.dynamicCrop)
                Toggle("允许黑边", isOn: $options.allowBlackBorders)
                Text(options.dynamicCrop ? "按运动自动缩放，最多达到上述倍数；不是固定放大倍数。" : "使用上述固定裁切倍数，整段画面不动态缩放。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text(options.allowBlackBorders ? "保留所选稳定强度；裁切不足时显示黑色边缘。" : "裁切不足时会降低平滑强度；仍无法覆盖边缘时提示调整参数。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button(directory == nil ? "保存为默认设置" : "应用并重新生成") {
                    do {
                        if let directory { jobs.enqueue(directory, options: options, force: true) }
                        else { try options.saveDefaults() }
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                if let error { Text(error).foregroundStyle(.orange) }
                Text(directory == nil ? "用于之后新建的处理任务。" : "原片和上一版稳定结果保留，新版完成后替换稳定结果。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("稳定参数").navigationBarTitleDisplayMode(.inline)
    }
}
