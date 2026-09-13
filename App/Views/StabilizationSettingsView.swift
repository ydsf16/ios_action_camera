import SwiftUI

struct StabilizationSettingsView: View {
    let directory: URL?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var jobs = StabilizationJobs.shared
    @State private var options: StabilizationOptions
    @State private var error: String?
    @State private var checking = false
    @State private var canRecommend = false
    @State private var advanced = false
    @State private var control: ProcessingControl?
    private let previousResult: StabilizationReport.Receipt?
    init(directory: URL? = nil) {
        self.directory = directory
        previousResult = directory.flatMap(StabilizationReport.load)
        _options = State(initialValue: directory.map(StabilizationOptions.load) ?? StabilizationOptions.defaults())
    }
    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    ForEach(StabilizationPreset.allCases) { preset in
                        Button { options.applyPreset(preset) } label: {
                            Text(preset.label).font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                                .foregroundStyle(options.preset == preset ? AppTheme.background : AppTheme.blue)
                                .background(options.preset == preset ? AppTheme.blue : AppTheme.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain).accessibilityAddTraits(options.preset == preset ? [.isSelected] : [])
                    }
                }.padding(.vertical, 4)
                if options.preset == nil {
                    Label("正在使用高级自定义参数", systemImage: "slider.horizontal.3").font(.footnote).foregroundStyle(AppTheme.violet)
                }
            } header: { Text("稳定效果") } footer: {
                Text(options.preset?.detail ?? "原有设置已保留。选择上方效果可恢复自动适配。")
            }.listRowBackground(AppTheme.surface)
            Section {
                Toggle(isOn: $options.horizonLock) { SettingsLabel("保持水平", symbol: "level") }
            } footer: {
                Text("使用重力方向保持水平，仍可转向和俯仰。自动模式会根据运动调整，完成后可查看说明。")
            }.listRowBackground(AppTheme.surface)
            Section {
                HStack(spacing: 12) {
                    ForEach(ExportResolution.allCases) { resolution in
                        Button { options.exportResolution = resolution } label: {
                            VStack(spacing: 8) {
                                Text(resolution == .fullHD ? "1080p" : "2.8K").font(.title3.weight(.semibold))
                                Text(resolution == .fullHD ? "高清" : "更多细节").font(.caption)
                            }.frame(maxWidth: .infinity, minHeight: 64)
                                .foregroundStyle(options.exportResolution == resolution ? AppTheme.background : AppTheme.accent)
                                .background(options.exportResolution == resolution ? AppTheme.accent : AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain).accessibilityLabel(resolution.label)
                            .accessibilityAddTraits(options.exportResolution == resolution ? [.isSelected] : [])
                    }
                }
            } header: { Text("输出分辨率") } footer: {
                Text("稳定处理时直接生成此尺寸，导出只保存成片。保留原片帧率和声音，1080p 原片不会放大。")
            }.listRowBackground(AppTheme.surface)
            Section {
                DisclosureGroup("高级设置", isExpanded: $advanced) {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent("稳定强度", value: "\(options.strengthLabel) · \(Int((options.strength * 100).rounded()))%")
                        Slider(value: manual(\.strength), in: 0...1, step: 0.01).tint(AppTheme.blue).accessibilityLabel("稳定强度")
                        Text("0% 关闭平滑；越强越需要裁切。改变以下参数后使用手动配置。").font(.footnote).foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                    Picker("裁切方式", selection: manual(\.dynamicCrop)) {
                        Text("动态").tag(true); Text("固定").tag(false)
                    }.pickerStyle(.segmented)
                    LabeledContent(options.dynamicCrop ? "最大裁切" : "固定裁切", value: String(format: "%.1f×", options.maxCrop))
                    Slider(value: manual(\.maxCrop), in: 1...5, step: 0.1).tint(AppTheme.violet).accessibilityLabel("裁切倍数")
                    Toggle("允许黑边", isOn: manual(\.allowBlackBorders))
                    Text(options.allowBlackBorders ? "保留设定强度和裁切；画面不足处显示黑边。" : "在裁切上限内保留完整画面，必要时降低平滑；无法兼顾时提前提示。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if options.dynamicCrop {
                        LabeledContent("缩放过渡", value: String(format: "%.1f 秒", options.zoomTransitionSeconds))
                        Slider(value: manual(\.zoomTransitionSeconds), in: 0.5...10, step: 0.5).tint(AppTheme.violet).accessibilityLabel("缩放过渡时间")
                    }
                    Button("恢复推荐设置") { options = options.recommended() }
                }
            }.listRowBackground(AppTheme.surface)
            if let previousResult {
                Section {
                    Label(previousResult.stabilization.summary, systemImage: previousResult.stabilization.adjusted ? "info.circle" : "checkmark.circle")
                        .foregroundStyle(previousResult.stabilization.adjusted ? AppTheme.amber : AppTheme.success)
                    DisclosureGroup("处理说明") {
                        Text(previousResult.stabilization.details).font(.footnote).foregroundStyle(.secondary)
                    }
                    if previousResult.options != options {
                        Text("当前参数尚未应用，生成后更新结果。").font(.footnote).foregroundStyle(.secondary)
                    }
                } header: { Text("上次结果") }.listRowBackground(AppTheme.surface)
            }
            Section {
                Button {
                    if canRecommend { options = options.recommended() }
                    apply()
                } label: {
                    HStack {
                        if checking { ProgressView() }
                        Text(checking ? "正在检查素材…" : directory == nil ? "保存为默认设置" : canRecommend ? "使用推荐设置生成" : "生成视频")
                    }.frame(maxWidth: .infinity)
                }.buttonStyle(PrimaryActionStyle()).listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                if let error {
                    Text(error).foregroundStyle(AppTheme.amber)
                }
            } footer: {
                Text(directory == nil ? "新拍摄的素材将按所选效果和分辨率自动生成。" : "按所选效果和分辨率生成，原片和上一版结果保留到成功替换。")
            }
        }
        .disabled(checking).settingsAppearance()
        .navigationTitle("稳定与输出").navigationBarTitleDisplayMode(.inline)
        .onChange(of: options) { _, _ in error = nil; canRecommend = false }
        .onDisappear { control?.cancel() }
    }
    private func manual<Value>(_ key: WritableKeyPath<StabilizationOptions, Value>) -> Binding<Value> {
        Binding(get: { options[keyPath: key] }, set: { options[keyPath: key] = $0; options.automaticAdjustment = false })
    }
    private func apply() {
        guard !checking else { return }
        error = nil; canRecommend = false
        guard let directory else {
            do { try options.saveDefaults(); dismiss() } catch { self.error = error.localizedDescription }
            return
        }
        let selected = options, token = ProcessingControl()
        control = token; checking = true
        Task {
            defer { checking = false; control = nil }
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try await StabilizationProcessor.preflight(directory: directory, options: selected, control: token)
                }.value
                try token.checkpoint()
                jobs.enqueue(directory, options: selected, force: true)
                dismiss()
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription; canRecommend = error is StabilizationProcessor.ParameterConflict }
        }
    }
}
