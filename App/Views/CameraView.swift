import SwiftUI
import AVFoundation

struct CameraView: View {
    @StateObject private var camera = CaptureService()
    private let jobs = StabilizationJobs.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ObservedObject private var access = ProAccess.shared
    @State private var showLibrary = false
    @State private var showSettings = false
    @State private var pinchStartZoom: Double?
    @AppStorage("cameraGridEnabled") private var gridEnabled = false

    private var recording: Bool { camera.phase == .recording }

    var body: some View {
        ZStack {
            #if DEBUG && targetEnvironment(simulator)
            if let image = camera.storeScreenshotImage {
                GeometryReader { geometry in
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .scaleEffect(camera.zoom).clipped()
                }.ignoresSafeArea()
            } else { livePreview }
            #else
            livePreview
            #endif

            // Subtle scrims keep controls readable without reserving space in the viewfinder.
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: verticalSizeClass == .compact ? 80 : 170)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                    .frame(height: verticalSizeClass == .compact ? 160 : 300)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            if camera.phase == .unavailable {
                VStack(spacing: 16) {
                    Image(systemName: "camera").font(.largeTitle)
                    Text(camera.permissionDenied ? "允许相机和麦克风访问后开始拍摄" : "请在 iPhone 上打开相机")
                        .font(.subheadline).multilineTextAlignment(.center)
                    if camera.permissionDenied {
                        Button("打开设置") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }.buttonStyle(.borderedProminent)
                    }
                }.padding(30)
            }
            if camera.phase == .preparing { ProgressView("正在准备相机") }

            // Only the controls respect safe areas; the live image extends behind them.
            VStack(spacing: 0) {
                HStack {
                    Text(recording ? timer : "RoamShot")
                        .font(.system(.headline, design: .monospaced)).foregroundStyle(recording ? .red : .white)
                    Spacer()
                    Menu {
                        CaptureFormatControls(camera: camera)
                    } label: {
                        Text(camera.formatLabel).font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12).frame(minHeight: 44)
                            .background(.black.opacity(0.35), in: Capsule())
                    }.disabled(camera.phase != .ready).accessibilityLabel("录制格式")
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape").frame(width: 44, height: 44).background(.black.opacity(0.35), in: Circle())
                    }
                        .disabled(recording || camera.phase == .finishing).accessibilityLabel("设置")
                }
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                .padding(.leading, 22).padding(.trailing, 8)

                Spacer(minLength: 24)

                VStack(spacing: 16) {
                    if !camera.usesVirtualCamera {
                        HStack(spacing: 14) {
                        ForEach(camera.lenses) { lens in
                            Button { camera.selectLens(lens) } label: {
                                Text(lens.label).font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(lens.id == camera.selectedLens ? .yellow : .white)
                                    .frame(width: 44, height: 44).background(.black.opacity(0.45), in: Circle())
                            }.disabled(camera.phase != .ready)
                        }
                        }
                    }
                    if camera.zoomRange.maximum > camera.zoomRange.minimum { CameraZoomControls(camera: camera) }

                    if recording && !access.hasPro {
                        Text("\(max(0, 60 - Int(camera.duration))) 秒后自动保存")
                            .font(.caption).foregroundStyle(.white.opacity(0.85))
                    }
                    Text(camera.phase == .finishing ? "正在保存…" : "视频")
                        .foregroundStyle(.yellow).font(.system(size: 14, weight: .semibold))
                        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                    HStack {
                        Button { showLibrary = true } label: {
                            Image(systemName: "square.grid.2x2")
                                .font(.title2).frame(width: 54, height: 54)
                                .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
                        }.accessibilityLabel("素材").disabled(recording || camera.phase == .finishing)
                        Spacer()
                        Button {
                            if recording { camera.stopRecording() } else { camera.startRecording() }
                        } label: {
                            ZStack {
                                Circle().fill(.black.opacity(0.2)).frame(width: 78, height: 78)
                                Circle().stroke(.white, lineWidth: 4).frame(width: 78, height: 78)
                                if camera.phase == .finishing {
                                    ProgressView()
                                } else {
                                    RoundedRectangle(cornerRadius: recording ? 6 : 35)
                                        .fill(.red).frame(width: recording ? 30 : 66, height: recording ? 30 : 66)
                                }
                            }
                        }
                        .disabled(camera.startingRecording || (camera.phase != .ready && camera.phase != .recording))
                        .accessibilityLabel(recording ? "停止录制" : "开始录制")
                        .accessibilityIdentifier("recordButton")
                        Spacer()
                        Color.clear.frame(width: 54, height: 54)
                    }.padding(.horizontal, 30)
                }.padding(.bottom, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black).foregroundStyle(.white)
        .sheet(isPresented: $showLibrary) { RecordingLibraryView() }
        .sheet(isPresented: $showSettings) { RecordingSettingsView(camera: camera, gridEnabled: $gridEnabled) }
        .alert("拍摄提示", isPresented: Binding(get: { camera.message != nil }, set: { if !$0 { camera.message = nil } })) {
            Button("知道了", role: .cancel) { camera.message = nil }
        } message: { Text(camera.message ?? "") }
        .task {
            #if DEBUG
            // Device regression runner uses the same queue and exporter as the UI.
            let args = ProcessInfo.processInfo.arguments
            if let index = args.firstIndex(of: "--stabilize-recording"), index + 1 < args.count {
                let name = args[index + 1]
                if (name.hasPrefix("RS_") || name.hasPrefix("MC_")), !name.contains("/"), !name.contains("..") {
                    showLibrary = true
                    jobs.enqueue(CaptureService.recordingsRoot.appendingPathComponent(name), force: args.contains("--force-stabilization"))
                    return
                }
            }
            #endif
            camera.setActive(scenePhase == .active)
            await camera.prepare()
            #if DEBUG
            if args.contains("--focus-controls-test") { await camera.validateFocusControls() }
            #endif
        }
        .onChange(of: scenePhase) { _, value in
            if value == .active {
                Task { await access.refresh() }
                jobs.setForeground(true)
                camera.setActive(!showLibrary)
                if !showLibrary { Task { await camera.prepare() } }
            }
            else if value == .background { jobs.setForeground(false); camera.setActive(false) }
        }
        .onChange(of: recording) { _, value in
            jobs.setRecording(value)
        }
        .onChange(of: camera.latestDirectory) { _, directory in
            if let directory { jobs.enqueue(directory) }
        }
        .onChange(of: showLibrary) { _, value in camera.setActive(!value && scenePhase == .active) }
    }

    private var timer: String {
        let seconds = Int(camera.duration)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var livePreview: some View {
        CameraPreview(session: camera.session, device: camera.previewDevice,
            gridEnabled: gridEnabled, interactionEnabled: camera.phase == .ready || recording,
            focusFeedback: camera.focusFeedback, rotationChanged: camera.setCameraRotation,
            focusRequested: camera.focus,
            zoomChanged: { scale, ended in
                if ended { pinchStartZoom = nil; return }
                if pinchStartZoom == nil { pinchStartZoom = camera.zoom }
                camera.setZoom((pinchStartZoom ?? camera.zoom) * scale)
            })
            .ignoresSafeArea()
    }
}

private struct CaptureFormatControls: View {
    @ObservedObject var camera: CaptureService
    var showIcons = false
    var body: some View {
        if camera.availableFormats.isEmpty {
            LabeledContent("录制格式", value: "准备中")
        } else {
            Picker(selection: Binding(get: { camera.selectedFormat.resolution }, set: camera.selectResolution)) {
                ForEach(camera.availableResolutions) { resolution in Text(resolution.label).tag(resolution) }
            } label: {
                if showIcons { SettingsLabel("分辨率", symbol: "video.fill", color: AppTheme.blue) }
                else { Text("分辨率") }
            }
            Picker(selection: Binding(get: { camera.selectedFormat.fps }, set: camera.selectFrameRate)) {
                ForEach(camera.availableFrameRates, id: \.self) { fps in Text("\(fps) fps").tag(fps) }
            } label: {
                if showIcons { SettingsLabel("帧率", symbol: "speedometer", color: AppTheme.blue) }
                else { Text("帧率") }
            }
        }
    }
}

private struct RecordingSettingsView: View {
    @ObservedObject private var access = ProAccess.shared
    @State private var showUpgrade = false
    @ObservedObject var camera: CaptureService
    @Binding var gridEnabled: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showUpgrade = true } label: {
                        HStack {
                            SettingsLabel("RoamShot Pro", symbol: "sparkles")
                            Spacer()
                            Text(access.hasPro ? "已永久解锁" : "永久解锁").font(.subheadline).foregroundStyle(AppTheme.accent)
                        }
                    }
                } footer: { Text("免费每段最长 1 分钟，到点自动保存。Pro 解锁长时间录制，稳定处理和导出不另收费。") }
                    .listRowBackground(AppTheme.surface)
                Section {
                    CaptureFormatControls(camera: camera, showIcons: true).disabled(camera.phase != .ready)
                    LabeledContent {
                        Text(camera.focusLabel).foregroundStyle(.secondary)
                    } label: {
                        SettingsLabel("自动对焦", symbol: "viewfinder", color: AppTheme.blue)
                    }
                    Picker(selection: Binding(get: { camera.exposurePolicy }, set: camera.selectExposurePolicy)) {
                        ForEach(CaptureExposurePolicy.allCases) { policy in Text(policy.title).tag(policy) }
                    } label: {
                        SettingsLabel("曝光模式", symbol: "sun.max.fill", color: AppTheme.amber)
                    }.disabled(camera.phase != .ready)
                } header: { Text("录制") } footer: {
                    Text(camera.exposurePolicy.explanation)
                }.listRowBackground(AppTheme.surface)
                Section {
                    Toggle(isOn: $gridEnabled) {
                        SettingsLabel("九宫格参考线", symbol: "grid", color: AppTheme.blue)
                    }.accessibilityIdentifier("cameraGridToggle")
                } header: { Text("拍摄辅助") } footer: {
                    Text("参考线仅显示在取景画面中。轻点画面选择对焦位置，长按对焦后锁定，再次轻点恢复连续自动对焦。")
                }.listRowBackground(AppTheme.surface)
                Section("稳定处理") {
                    NavigationLink { StabilizationSettingsView() } label: {
                        SettingsLabel("默认稳定与输出", symbol: "waveform.path")
                    }
                }.listRowBackground(AppTheme.surface)
                Section("保存") {
                    SettingsLabel("素材保存在本机", symbol: "internaldrive", color: AppTheme.blue)
                    Text("素材页可批量删除，预览页可导出到相册。完整录制文件可在“文件 → 我的 iPhone → RoamShot → Recordings”中导出。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.listRowBackground(AppTheme.surface)
                Section {
                    DisclosureGroup("采集信息") {
                        LabeledContent("镜头切换", value: camera.usesVirtualCamera ? "随变焦自动切换" : "单镜头")
                        LabeledContent("当前镜头", value: camera.activeLensLabel)
                        LabeledContent("声音", value: "开启")
                        LabeledContent("方向", value: "自动横竖屏")
                        LabeledContent("视频／IMU 时钟同步", value: "开启")
                        Text("自动曝光和 ISO 调节保留。使用系统时间戳对齐，不代表硬件触发同步。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text("录制期间分辨率和帧率固定，可双指或使用滑条变焦。自动切换镜头由系统根据倍率、光线和对焦距离决定；60 fps 会增加存储和处理量。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.listRowBackground(AppTheme.surface)
                Section("帮助") {
                    Link("使用帮助", destination: AppLinks.support)
                    Link("隐私政策", destination: AppLinks.privacy)
                    Link("使用条款", destination: AppLinks.terms)
                }.listRowBackground(AppTheme.surface)
                Section("开源") {
                    Link(destination: URL(string: "https://github.com/ydsf16/ios_action_camera")!) {
                        SettingsLabel("源代码", symbol: "chevron.left.forwardslash.chevron.right", color: AppTheme.violet)
                    }
                    NavigationLink { LicenseNoticesView() } label: {
                        SettingsLabel("开源许可", symbol: "doc.text", color: AppTheme.violet)
                    }
                    Text("包含 Gyroflow 1.6.3 · GPLv3").font(.footnote).foregroundStyle(.secondary)
                }.listRowBackground(AppTheme.surface)
                Section {
                    Text("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—") · \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")\n录制结束后自动生成稳定视频，原片保留至手动删除素材。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.listRowBackground(AppTheme.surface)
            }
            .settingsAppearance()
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.tint(AppTheme.accent)
            .sheet(isPresented: $showUpgrade) { ProUpgradeView() }
    }
}
