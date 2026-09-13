import SwiftUI

struct StabilizationSettingsView: View {
    let directory: URL?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject private var jobs = StabilizationJobs.shared
    @State private var options: StabilizationOptions
    @State private var error: String?
    private let previousResult: StabilizationReport.Receipt?
    init(directory: URL? = nil) {
        self.directory = directory
        previousResult = directory.flatMap(StabilizationReport.load)
        _options = State(initialValue: directory.map(StabilizationOptions.load) ?? StabilizationOptions.defaults())
    }
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsLabel("输出分辨率", symbol: "square.and.arrow.up", color: AppTheme.accent)
                    let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
                    layout {
                        ForEach(ExportResolution.allCases) { resolution in
                            resolutionButton(resolution)
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: { Text("导出") } footer: {
                Text("保留原片帧率，横竖屏自动适配。输出不超过原片尺寸；1080p 原片选择 2.8K 时仍输出 1080p。")
                    .font(.footnote).foregroundStyle(.secondary)
            }.listRowBackground(AppTheme.surface)
            Section {
                VStack(spacing: 14) {
                    HStack {
                        SettingsLabel("强度", symbol: "waveform.path", color: AppTheme.blue)
                        Spacer()
                        Text("\(options.strengthLabel) · \(Int((options.strength * 100).rounded()))%")
                            .font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(AppTheme.blue)
                    }
                    Slider(value: $options.strength, in: 0...1, step: 0.01)
                        .tint(AppTheme.blue).accessibilityLabel("稳定强度")
                    HStack {
                        Text("关闭")
                        Spacer()
                        Text("自然")
                        Spacer()
                        Text("标准")
                        Spacer()
                        Text("强")
                        Spacer()
                        Text("超强")
                    }.font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            } header: { Text("稳定强度") } footer: {
                Text("越强越能抑制缓慢晃动，也会减少主动运镜、需要更多裁切。0% 关闭平滑，裁切设置仍保留。")
            }.listRowBackground(AppTheme.surface)
            Section {
                Toggle(isOn: $options.horizonLock) {
                    SettingsLabel("重力水平锁定", symbol: "level", color: AppTheme.accent)
                }.tint(AppTheme.accent)
            } footer: {
                Text("使用录制的重力方向保持画面水平，仍可转向和俯仰。可能需要更多裁切；镜头接近朝正上或正下时自动减弱锁定。0% 平滑时也可单独保持水平。")
            }.listRowBackground(AppTheme.surface)
            Section {
                Picker("裁切方式", selection: $options.dynamicCrop) {
                    Text("动态").tag(true)
                    Text("固定").tag(false)
                }.pickerStyle(.segmented)
                VStack(spacing: 14) {
                    HStack {
                        SettingsLabel(options.dynamicCrop ? "最大裁切" : "固定裁切", symbol: "crop", color: AppTheme.violet)
                        Spacer()
                        Text(String(format: "%.1f×", options.maxCrop))
                            .font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(AppTheme.violet)
                    }
                    Slider(value: $options.maxCrop, in: 1...5, step: 0.1)
                        .tint(AppTheme.violet).accessibilityLabel(options.dynamicCrop ? "最大裁切" : "固定裁切")
                }.padding(.vertical, 4)
                Picker("边缘策略", selection: $options.allowBlackBorders) {
                    Text("画面完整优先").tag(false)
                    Text("稳定优先（允许黑边）").tag(true)
                }.tint(AppTheme.accent)
                if options.allowBlackBorders {
                    Button("保留完整视野（1×，不动态裁切）") {
                        options.dynamicCrop = false; options.maxCrop = 1
                    }
                }
            } header: { Text("裁切与画面边缘") } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(options.dynamicCrop ? "按运动自动缩放，最多达到上述倍数。" : "使用上述固定裁切倍数，整段画面不动态缩放。")
                    Text(options.allowBlackBorders ? "保留设定强度；裁切不足的部分显示黑边。切换策略不会改变裁切倍率。" : "裁切不足时降低平滑强度，并在结果中提示；仍无法覆盖边缘时保留原片并提示调整。")
                }
            }.listRowBackground(AppTheme.surface)
            if options.dynamicCrop {
                Section {
                    DisclosureGroup("高级设置") {
                        LabeledContent("缩放过渡", value: String(format: "%.1f 秒", options.zoomTransitionSeconds))
                        Slider(value: $options.zoomTransitionSeconds, in: 0.5...10, step: 0.5)
                            .tint(AppTheme.violet).accessibilityLabel("缩放过渡时间")
                        Text("时间越长，自动缩放变化越慢，也会保持裁切更久。拍摄时主动调整的倍率仍会保留。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.listRowBackground(AppTheme.surface)
            }
            if let previousResult {
                Section {
                    Label(previousResult.stabilization.summary,
                          systemImage: previousResult.stabilization.cropLimited ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(previousResult.stabilization.cropLimited ? AppTheme.violet : AppTheme.success)
                    Text(String(format: "实际裁切 %.1f× – %.1f×", previousResult.stabilization.minimumCrop, previousResult.stabilization.maximumCrop))
                        .font(.footnote).foregroundStyle(.secondary)
                    if previousResult.stabilization.cropLimited {
                        Text("可增大裁切倍率，或选择稳定优先以保留设定强度。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if previousResult.options != options {
                        Text("当前参数尚未应用，重新生成后更新结果。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } header: { Text("上次生成结果") }.listRowBackground(AppTheme.surface)
            }
            Section {
                Button {
                    do {
                        if let directory { jobs.enqueue(directory, options: options, force: true) }
                        else { try options.saveDefaults() }
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                } label: {
                    Label(directory == nil ? "保存为默认设置" : "应用并重新生成", systemImage: directory == nil ? "checkmark" : "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(PrimaryActionStyle())
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                if let error { Text(error).foregroundStyle(.orange) }
            } footer: {
                Text(directory == nil ? "用于之后新建的处理任务。" : "原片和上一版稳定结果保留，新版完成后替换稳定结果。")
            }
        }
        .settingsAppearance()
        .navigationTitle("稳定与导出").navigationBarTitleDisplayMode(.inline)
    }

    private func resolutionButton(_ resolution: ExportResolution) -> some View {
        let selected = options.exportResolution == resolution
        return Button { options.exportResolution = resolution } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(resolution == .fullHD ? "1080p" : "2.8K").font(.title3.weight(.semibold))
                    Spacer(minLength: 4)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? AppTheme.accent : Color.secondary)
                }
                Text(resolution == .fullHD ? "高清 · 1920 × 1080" : "2816 × 1584")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .foregroundStyle(selected ? AppTheme.accent : Color.primary)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? AppTheme.accent.opacity(0.12) : AppTheme.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? AppTheme.accent.opacity(0.7) : Color.white.opacity(0.1), lineWidth: 1) }
        }.buttonStyle(.plain)
            .accessibilityLabel(resolution.label)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
