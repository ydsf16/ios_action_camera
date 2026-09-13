import SwiftUI
import AVKit
import Photos

struct ClipPreviewView: View {
    let clip: RecordedClip
    @ObservedObject var library: RecordingLibraryModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var jobs = StabilizationJobs.shared
    @State private var showOriginal = false
    @State private var player: AVPlayer?
    @State private var saving = false
    @State private var saved = false
    @State private var message: String?
    @State private var showAdjustment = false
    @State private var showInfo = false
    @State private var confirmDeletion = false
    @State private var controlsVisible = true
    @State private var stabilizationReport: StabilizationReport?

    private var duration: Double {
        let seconds = player?.currentItem?.duration.seconds ?? 0
        return seconds.isFinite && seconds > 0 ? seconds : max(clip.manifest.durationSeconds, 0.1)
    }
    private var busy: Bool {
        switch jobs.states[clip.id] { case .queued, .processing: return true; default: return false }
    }
    private var stableURL: URL { clip.directory.appendingPathComponent(StabilizationProcessor.filename) }
    private var hasStable: Bool { FileManager.default.fileExists(atPath: stableURL.path) }
    private var playbackURL: URL { hasStable && !showOriginal ? stableURL : clip.video }
    private var deletion: ClipDeletion { ClipDeletion(clips: [library.clips.first { $0.id == clip.id } ?? clip]) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if clip.canPlay {
                FullFramePlayer(player: player).ignoresSafeArea().contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() } }
            } else {
                ContentUnavailableView("录制未完成", systemImage: "exclamationmark.triangle", description: Text("已有文件保留在本机，可在更多菜单中查看或删除。"))
            }
            if controlsVisible {
                VStack(spacing: 0) {
                    header
                    Spacer(minLength: 0)
                    playbackControls
                }.transition(.opacity)
            }
            if library.deleting {
                Color.black.opacity(0.35).ignoresSafeArea()
                ProgressView("正在停止处理并删除…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .foregroundStyle(.white).tint(AppTheme.accent)
        .statusBarHidden()
        .interactiveDismissDisabled(saving || library.deleting)
        .task { if clip.canPlay { replacePlayer() } }
        .task(id: jobs.revisions[clip.id]) {
            stabilizationReport = StabilizationReport.load(directory: clip.directory)?.stabilization
        }
        .sheet(isPresented: $showAdjustment) {
            NavigationStack {
                StabilizationSettingsView(directory: clip.directory)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { showAdjustment = false } } }
            }.tint(AppTheme.accent)
        }
        .sheet(isPresented: $showInfo) { ClipInfoView(clip: clip) }
        .onChange(of: jobs.revisions[clip.id]) { _, _ in stableResultChanged() }
        .onChange(of: hasStable) { _, ready in if ready { stableResultChanged() } }
        .onDisappear { releasePlayer() }
        .alert(deletion.title, isPresented: $confirmDeletion) {
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) {
                releasePlayer()
                Task {
                    if await library.remove([clip]) { dismiss() }
                    else { message = library.failure; library.failure = nil; if clip.canPlay { replacePlayer() } }
                }
            }
        } message: { Text(deletion.message) }
        .alert("素材提示", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("知道了", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44).background(.black.opacity(0.35), in: Circle()) }
                .accessibilityLabel("关闭预览").disabled(saving || library.deleting)
            Spacer(minLength: 0)
            if hasStable {
                Picker("视频版本", selection: Binding(get: { showOriginal }, set: { value in showOriginal = value; replacePlayer(); saved = false })) {
                    Text("原片").tag(true)
                    Text("稳定").tag(false)
                }.pickerStyle(.segmented).frame(maxWidth: 200).disabled(saving || library.deleting)
                .accessibilityIdentifier("videoVersion")
            } else { Text("原片").font(.subheadline.weight(.semibold)) }
            Spacer(minLength: 0)
            Menu {
                Button { player?.pause(); showInfo = true } label: { Label("素材信息", systemImage: "info.circle") }
                Button(role: .destructive) { player?.pause(); confirmDeletion = true } label: { Label("删除素材", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 44).background(.black.opacity(0.35), in: Circle())
            }.accessibilityLabel("更多").disabled(saving || library.deleting)
        }.padding(.horizontal, 16).padding(.bottom, 22)
        .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea(edges: .top))
    }

    private var playbackControls: some View {
        VStack(spacing: 12) {
            processingStatus
            if !busy, !showOriginal, hasStable, let stabilizationReport, stabilizationReport.cropLimited {
                Button { player?.pause(); showAdjustment = true } label: {
                    Label("已受裁切限制 · 调整", systemImage: "exclamationmark.circle")
                        .font(.footnote).foregroundStyle(.yellow)
                }.disabled(saving)
            }
            if clip.canPlay {
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    let current = currentSeconds
                    VStack(spacing: 2) {
                        HStack(spacing: 12) {
                            Button { togglePlayback() } label: {
                                Image(systemName: (player?.rate ?? 0) > 0 ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
                            }.accessibilityLabel((player?.rate ?? 0) > 0 ? "暂停" : "播放")
                            Slider(value: Binding(get: { currentSeconds }, set: { player?.seek(to: CMTime(seconds: $0, preferredTimescale: 600)) }), in: 0...duration)
                                .accessibilityLabel("播放进度")
                        }
                        HStack {
                            Text(MediaText.duration(current))
                            Spacer()
                            Text(MediaText.duration(duration.rounded(.up)))
                        }.font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                    }
                }
                HStack(spacing: 12) {
                    Button { player?.pause(); showAdjustment = true } label: {
                        Label("调整", systemImage: "slider.horizontal.3").frame(minWidth: 64, minHeight: 32)
                    }.buttonStyle(.bordered).tint(AppTheme.accent).disabled(busy || saving)
                    Button { Task { await saveToPhotos() } } label: {
                        HStack(spacing: 8) {
                            if saving { ProgressView().tint(AppTheme.accent) }
                            else { Image(systemName: saved ? "checkmark" : "square.and.arrow.up") }
                            Text(saving ? "正在导出…" : saved ? "已保存到相册" : hasStable && !showOriginal ? "导出稳定视频" : "导出原片")
                        }.font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 32)
                    }.buttonStyle(PrimaryActionStyle(color: saved ? AppTheme.success : AppTheme.accent, completed: saved)).disabled(saving || saved || busy)
                    .accessibilityIdentifier("exportVideo")
                }
            }
        }.disabled(library.deleting).padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 16)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.88)], startPoint: .top, endPoint: .bottom).ignoresSafeArea(edges: .bottom))
    }

    @ViewBuilder private var processingStatus: some View {
        if clip.canPlay {
            switch jobs.states[clip.id] {
            case .queued:
                HStack { Label("等待稳定处理", systemImage: "clock"); Spacer(); Button("取消") { jobs.cancel(clip.directory) } }.font(.footnote)
            case let .processing(fraction):
                HStack {
                    ProgressView("正在稳定 \(Int(min(1, max(0, fraction)) * 100))%", value: min(1, max(0, fraction)))
                    Button("取消") { jobs.cancel(clip.directory) }.font(.footnote)
                }
            case let .failed(error):
                HStack {
                    Label("处理未完成", systemImage: "exclamationmark.circle").foregroundStyle(.yellow)
                    Button("详情") { message = error }
                    Spacer()
                    Button("重试") { jobs.enqueue(clip.directory, force: true) }
                }.font(.footnote)
            default:
                if !hasStable { Button("生成稳定视频") { jobs.enqueue(clip.directory) }.font(.footnote) }
            }
        }
    }

    private var currentSeconds: Double {
        let value = player?.currentTime().seconds ?? 0
        return value.isFinite ? min(max(value, 0), duration) : 0
    }
    private func releasePlayer() { player?.pause(); player?.replaceCurrentItem(with: nil); player = nil }
    private func replacePlayer() {
        let time = player?.currentTime() ?? .zero
        let playing = (player?.rate ?? 0) > 0
        releasePlayer()
        let replacement = AVPlayer(url: playbackURL)
        player = replacement
        replacement.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            Task { @MainActor in if finished, playing, player === replacement { replacement.play() } }
        }
    }
    private func stableResultChanged() {
        guard hasStable, !saving, !library.deleting else { return }
        showOriginal = false; replacePlayer(); saved = false
    }
    private func togglePlayback() {
        guard let player else { return }
        if player.rate > 0 { player.pause() }
        else {
            if currentSeconds >= duration - 0.1 { player.seek(to: .zero) }
            player.play()
        }
    }
    @MainActor private func saveToPhotos() async {
        guard !saving, !saved, !busy, !library.deleting, clip.canPlay else { return }
        let source = playbackURL
        saving = true; player?.pause()
        defer { saving = false }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { message = "请在系统设置中允许添加照片。视频仍保存在本机。"; return }
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: source) }
            saved = true
        } catch { message = error.localizedDescription }
    }
}

private struct ClipInfoView: View {
    let clip: RecordedClip
    @Environment(\.dismiss) private var dismiss
    @State private var bytes: Int64?
    @State private var output = "尚未生成"
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("拍摄时间", value: clip.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("时长", value: MediaText.duration(clip.manifest.durationSeconds))
                    LabeledContent("原片", value: "\(clip.manifest.width) × \(clip.manifest.height) · \(clip.manifest.requestedFPS) fps")
                    LabeledContent("稳定视频", value: output)
                    LabeledContent("本机占用", value: "约 \(MediaText.storage(bytes ?? clip.allocatedBytes))")
                }.listRowBackground(AppTheme.surface)
                Section {
                    Text("本机素材包含原片、稳定视频和运动数据。导出会将当前视频另存到系统相册。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.listRowBackground(AppTheme.surface)
            }.settingsAppearance().navigationTitle("素材信息").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.tint(AppTheme.accent)
        .task {
            let directory = clip.directory
            bytes = await Task.detached { RecordingStorage.allocatedBytes(in: directory) }.value
            let url = clip.directory.appendingPathComponent(StabilizationProcessor.filename)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            do {
                if let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first {
                    let size = try await track.load(.naturalSize)
                    let transform = try await track.load(.preferredTransform)
                    let fps = try await track.load(.nominalFrameRate)
                    let rect = CGRect(origin: .zero, size: size).applying(transform)
                    output = "\(Int(abs(rect.width))) × \(Int(abs(rect.height))) · \(Int(fps.rounded())) fps"
                }
            } catch { output = "无法读取" }
        }
    }
}

// Fit the entire encoded frame, including real stabilization borders, at either orientation.
private struct FullFramePlayer: UIViewRepresentable {
    var player: AVPlayer?
    func makeUIView(context: Context) -> PlayerSurface { PlayerSurface() }
    func updateUIView(_ view: PlayerSurface, context: Context) { view.playerLayer.player = player }
    final class PlayerSurface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        override init(frame: CGRect) { super.init(frame: frame); playerLayer.videoGravity = .resizeAspect }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}
