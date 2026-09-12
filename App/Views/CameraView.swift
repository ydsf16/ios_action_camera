import SwiftUI
import AVFoundation

struct CameraView: View {
    @StateObject private var camera = CaptureService()
    @ObservedObject private var jobs = StabilizationJobs.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var showLibrary = false
    @State private var showSettings = false

    private var recording: Bool { camera.phase == .recording }

    var body: some View {
        ZStack {
            CameraPreview(session: camera.session, rotationChanged: camera.setRecordingRotation)
                .ignoresSafeArea()

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
                    Text(recording ? timer : "MotionCam")
                        .font(.system(.headline, design: .monospaced)).foregroundStyle(recording ? .red : .white)
                    Spacer()
                    Text(camera.formatLabel).font(.subheadline.weight(.semibold))
                    Button { showSettings = true } label: { Image(systemName: "gearshape").frame(width: 44, height: 44) }
                        .disabled(recording || camera.phase == .finishing).accessibilityLabel("设置")
                }
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                .padding(.leading, 22).padding(.trailing, 8)

                Spacer(minLength: 24)

                VStack(spacing: 16) {
                    HStack(spacing: 14) {
                        ForEach(camera.lenses) { lens in
                            Button { camera.selectLens(lens) } label: {
                                Text(lens.label).font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(lens.id == camera.selectedLens ? .yellow : .white)
                                    .frame(width: 44, height: 44).background(.black.opacity(0.45), in: Circle())
                            }.disabled(camera.phase != .ready)
                        }
                    }

                    Text(camera.phase == .finishing ? "正在保存…" : "视频")
                        .foregroundStyle(.yellow).font(.system(size: 14, weight: .semibold))
                        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                    HStack {
                        Button { showLibrary = true } label: {
                            Image(systemName: camera.latestDirectory == nil ? "photo.on.rectangle" : "play.rectangle.fill")
                                .font(.title2).frame(width: 54, height: 54)
                                .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                        }.accessibilityLabel("素材").disabled(recording || camera.phase == .finishing)
                        Spacer()
                        Button {
                            if recording { camera.stopRecording() } else {
                                switch UIDevice.current.orientation {
                                case .portrait: camera.setRecordingRotation(90)
                                case .portraitUpsideDown: camera.setRecordingRotation(270)
                                case .landscapeLeft: camera.setRecordingRotation(0)
                                case .landscapeRight: camera.setRecordingRotation(180)
                                default: break // Flat/unknown keeps the current preview orientation.
                                }
                                camera.startRecording()
                            }
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
                        .disabled(camera.phase != .ready && camera.phase != .recording)
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
        .sheet(isPresented: $showSettings) { RecordingSettingsView(focusLabel: camera.focusLabel) }
        .alert("拍摄提示", isPresented: Binding(get: { camera.message != nil }, set: { if !$0 { camera.message = nil } })) {
            Button("知道了", role: .cancel) { camera.message = nil }
        } message: { Text(camera.message ?? "") }
        .onAppear { UIDevice.current.beginGeneratingDeviceOrientationNotifications() }
        .onDisappear { UIDevice.current.endGeneratingDeviceOrientationNotifications() }
        .task {
            #if DEBUG
            // Device regression runner uses the same queue and exporter as the UI.
            let args = ProcessInfo.processInfo.arguments
            if let index = args.firstIndex(of: "--stabilize-recording"), index + 1 < args.count {
                let name = args[index + 1]
                if name.hasPrefix("MC_"), !name.contains("/"), !name.contains("..") {
                    showLibrary = true
                    jobs.enqueue(CaptureService.recordingsRoot.appendingPathComponent(name), force: args.contains("--force-stabilization"))
                    return
                }
            }
            #endif
            camera.setActive(scenePhase == .active)
            await camera.prepare()
        }
        .onChange(of: scenePhase) { _, value in
            if value == .active {
                jobs.setForeground(true)
                camera.setActive(!showLibrary && !showSettings)
                if !showLibrary && !showSettings { Task { await camera.prepare() } }
            }
            else if value == .background { jobs.setForeground(false); camera.setActive(false) }
        }
        .onChange(of: recording) { _, value in
            UIApplication.shared.isIdleTimerDisabled = value
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
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var rotationChanged: (Int) -> Void
    class PreviewView: UIView {
        var rotationChanged: ((Int) -> Void)?
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        override func layoutSubviews() {
            super.layoutSubviews()
            let angle: Int
            switch window?.windowScene?.interfaceOrientation {
            case .landscapeLeft: angle = 180
            case .landscapeRight: angle = 0
            case .portraitUpsideDown: angle = 270
            default: angle = 90
            }
            rotationChanged?(angle)
            if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(CGFloat(angle)) {
                connection.videoRotationAngle = CGFloat(angle)
                connection.preferredVideoStabilizationMode = .off
            }
        }
    }
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.rotationChanged = rotationChanged
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ view: PreviewView, context: Context) { view.setNeedsLayout() }
}

private struct RecordingSettingsView: View {
    let focusLabel: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("录制") {
                    LabeledContent("格式", value: "4K / 30fps · SDR")
                    LabeledContent("自动对焦", value: focusLabel)
                    LabeledContent("曝光时间上限", value: "5 ms · 1/200 秒")
                    LabeledContent("视频／IMU 时钟同步", value: "开启")
                    Text("自动曝光和 ISO 调节保留。使用系统时间戳对齐，不代表硬件触发同步。")
                        .font(.footnote).foregroundStyle(.secondary)
                    LabeledContent("声音", value: "开启")
                    LabeledContent("方向", value: "自动横竖屏")
                    Text("不支持 4K 的镜头自动使用 1080p。录制期间镜头固定。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("稳定处理") {
                    NavigationLink("默认稳定参数") { StabilizationSettingsView() }
                }
                Section("保存") {
                    Text("视频和运动数据保存在本机，可从素材预览保存视频到相册。")
                    Text("完整录制文件可在“文件 → 我的 iPhone → MotionCam → Recordings”中导出。")
                }
                Section("开源") {
                    Link("源代码", destination: URL(string: "https://github.com/ydsf16/ios_action_camera")!)
                    NavigationLink("开源许可") { LicenseNoticesView() }
                    Text("包含 Gyroflow 1.6.3 · GPLv3").font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Text("0.3.0 · 方向与稳定参数\n录制结束后自动生成稳定视频，原片始终保留。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
