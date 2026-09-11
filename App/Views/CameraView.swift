import SwiftUI
import AVFoundation

struct CameraView: View {
    @StateObject private var camera = CaptureService()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showLibrary = false
    @State private var showSettings = false

    private var recording: Bool { camera.phase == .recording }

    var body: some View {
        ZStack {
            CameraPreview(session: camera.session)
                .ignoresSafeArea()

            // Subtle scrims keep controls readable without reserving space in the viewfinder.
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 170)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 300)
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
        .sheet(isPresented: $showSettings) { RecordingSettingsView() }
        .alert("拍摄提示", isPresented: Binding(get: { camera.message != nil }, set: { if !$0 { camera.message = nil } })) {
            Button("知道了", role: .cancel) { camera.message = nil }
        } message: { Text(camera.message ?? "") }
        .task {
            camera.setActive(scenePhase == .active)
            await camera.prepare()
        }
        .onChange(of: scenePhase) { _, value in
            if value == .active { camera.setActive(!showLibrary); Task { await camera.prepare() } }
            else if value == .background { camera.setActive(false) }
        }
        .onChange(of: recording) { _, value in UIApplication.shared.isIdleTimerDisabled = value }
        .onChange(of: showLibrary) { _, value in camera.setActive(!value && scenePhase == .active) }
    }

    private var timer: String {
        let seconds = Int(camera.duration)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        override func layoutSubviews() {
            super.layoutSubviews()
            if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
                connection.preferredVideoStabilizationMode = .off
            }
        }
    }
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ view: PreviewView, context: Context) { view.setNeedsLayout() }
}

private struct RecordingSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("录制") {
                    LabeledContent("格式", value: "4K / 30fps · SDR")
                    LabeledContent("声音", value: "开启")
                    LabeledContent("方向", value: "竖屏")
                    Text("不支持 4K 的镜头自动使用 1080p。录制期间镜头固定。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("保存") {
                    Text("视频和运动数据保存在本机，可从素材预览保存视频到相册。")
                    Text("完整录制文件可在“文件 → 我的 iPhone → MotionCam → Recordings”中导出。")
                }
                Section {
                    Text("0.1.0 · 录制原型\n当前保存原片，稳定处理将在下一步加入。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
