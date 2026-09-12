import SwiftUI
import AVKit
import Photos

struct RecordedClip: Identifiable {
    let directory: URL
    let manifest: RecordingManifest
    var id: String { manifest.id }
    var video: URL { directory.appendingPathComponent("video.mov") }
    var canPlay: Bool { FileManager.default.fileExists(atPath: video.path) }
}

struct RecordingLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var clips: [RecordedClip] = []
    @State private var selected: RecordedClip?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Group {
                if clips.isEmpty {
                    ContentUnavailableView("还没有视频", systemImage: "video", description: Text("拍下第一段，素材会保存在这里。"))
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                            ForEach(clips) { clip in
                                Button { selected = clip } label: { ClipTile(clip: clip) }.buttonStyle(.plain)
                            }
                        }.padding()
                    }
                }
            }
            .navigationTitle("素材")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .fullScreenCover(item: $selected) { ClipPreviewView(clip: $0) }
            .task { await loadClips() }
            .alert("素材读取失败", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("知道了", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
        }
    }

    private func loadClips() async {
        do {
            let root = CaptureService.recordingsRoot
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            clips = urls.compactMap { directory in
                guard let manifest = try? RecordingManifest.read(from: directory.appendingPathComponent("manifest.json")) else { return nil }
                return RecordedClip(directory: directory, manifest: manifest)
            }.sorted { $0.manifest.createdAt > $1.manifest.createdAt }
        } catch { failure = error.localizedDescription }
    }
}

private struct ClipTile: View {
    let clip: RecordedClip
    @ObservedObject private var jobs = StabilizationJobs.shared
    private var status: String {
        if clip.manifest.status != "complete" { return "录制异常 · 数据已保留" }
        switch jobs.states[clip.id] {
        case .queued: return "等待处理"
        case let .processing(value): return "稳定处理中 \(Int(value * 100))%"
        case .ready: return "稳定视频"
        case .failed: return "处理未完成 · 原片已保留"
        default: return FileManager.default.fileExists(atPath: clip.directory.appendingPathComponent(StabilizationProcessor.filename).path) ? "稳定视频" : "原片"
        }
    }
    @State private var thumbnail: UIImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.08))
                if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFill() }
                else { Image(systemName: clip.canPlay ? "video" : "exclamationmark.triangle").frame(maxWidth: .infinity, maxHeight: .infinity) }
                Text(String(format: "%02d:%02d", Int(clip.manifest.durationSeconds) / 60, Int(clip.manifest.durationSeconds) % 60))
                    .font(.caption.monospacedDigit()).padding(6).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6)).padding(6)
            }.frame(height: 175).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
            Text(clip.manifest.createdAt, format: .dateTime.month().day().hour().minute()).font(.caption)
            Text(status)
                .font(.caption2).foregroundStyle(clip.manifest.status == "complete" ? .secondary : Color.orange)
        }
        .task {
            guard clip.canPlay else { return }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clip.video))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 400, height: 400)
            if let image = try? await generator.image(at: .zero) { thumbnail = UIImage(cgImage: image.image) }
        }
    }
}

private struct ClipPreviewView: View {
    let clip: RecordedClip
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var jobs = StabilizationJobs.shared
    @State private var showOriginal = false
    @State private var player: AVPlayer?
    @State private var saving = false
    @State private var saved = false
    @State private var message: String?
    @State private var showAdjustment = false
    @State private var controlsVisible = true
    private var duration: Double {
        let seconds = player?.currentItem?.duration.seconds ?? 0
        return seconds.isFinite && seconds > 0 ? seconds : max(clip.manifest.durationSeconds, 0.1)
    }
    private var busy: Bool {
        switch jobs.states[clip.id] { case .queued, .processing: return true; default: return false }
    }

    private var stableURL: URL { clip.directory.appendingPathComponent(StabilizationProcessor.filename) }
    private var hasStable: Bool {
        if case .ready = jobs.states[clip.id] { return true }
        return FileManager.default.fileExists(atPath: stableURL.path)
    }
    private var playbackURL: URL { hasStable && !showOriginal ? stableURL : clip.video }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if clip.canPlay {
                FullFramePlayer(player: player).ignoresSafeArea()
                    .contentShape(Rectangle()).onTapGesture { withAnimation { controlsVisible.toggle() } }
            }
            if controlsVisible {
                VStack {
                    HStack {
                        Button { dismiss() } label: { Image(systemName: "xmark").padding(12) }
                            .accessibilityLabel("关闭预览")
                        Spacer()
                        Text(hasStable && !showOriginal ? "稳定结果" : "原片")
                        Spacer()
                        if hasStable {
                            Button(showOriginal ? "看稳定结果" : "看原片") {
                                let time = player?.currentTime() ?? .zero
                                let playing = (player?.rate ?? 0) > 0
                                player?.pause(); showOriginal.toggle()
                                player = AVPlayer(url: playbackURL)
                                player?.seek(to: time)
                                if playing { player?.play() }
                                saved = false
                            }
                        }
                    }.padding(.horizontal).padding(.bottom, 16)
                        .background(LinearGradient(colors: [.black.opacity(0.8), .clear], startPoint: .top, endPoint: .bottom))
                    Spacer()
                    VStack(spacing: 10) {
                        if !clip.canPlay { Text("录制未完成，已有文件保留在本机。") }
                        switch jobs.states[clip.id] {
                        case .queued: Text("等待稳定处理").font(.footnote)
                        case let .processing(fraction):
                            HStack {
                                ProgressView("正在稳定处理 \(Int(fraction * 100))%", value: fraction)
                                Button("取消") { jobs.cancel(clip.directory) }
                            }
                        case let .failed(error):
                            Text(error).font(.footnote).foregroundStyle(.orange).lineLimit(3)
                            Button("重试稳定处理") { jobs.enqueue(clip.directory) }
                        default:
                            if !hasStable { Button("生成稳定视频") { jobs.enqueue(clip.directory) }.disabled(!clip.canPlay) }
                        }
                        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                            HStack {
                                Button {
                                    guard let player else { return }
                                    if player.rate > 0 { player.pause() }
                                    else {
                                        if player.currentTime().seconds >= duration - 0.1 { player.seek(to: .zero) }
                                        player.play()
                                    }
                                } label: { Image(systemName: (player?.rate ?? 0) > 0 ? "pause.fill" : "play.fill").frame(width: 36, height: 36) }
                                .accessibilityLabel((player?.rate ?? 0) > 0 ? "暂停" : "播放")
                                Slider(value: Binding(get: {
                                    let value = player?.currentTime().seconds ?? 0
                                    return value.isFinite ? min(max(value, 0), duration) : 0
                                }, set: { player?.seek(to: CMTime(seconds: $0, preferredTimescale: 600)) }), in: 0...duration)
                                .accessibilityLabel("播放进度")
                            }
                        }
                        HStack {
                            Button("调整稳定参数") { showAdjustment = true }.disabled(busy || saving || !clip.canPlay)
                            Spacer()
                            Button(saving ? "正在保存…" : (saved ? "已保存到相册" : "保存到相册")) {
                                Task { await saveToPhotos() }
                            }.disabled(saving || saved || busy || !clip.canPlay)
                        }.buttonStyle(.bordered)
                    }.padding().background(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
                }.foregroundStyle(.white).tint(.white)
            }
        }
            .statusBarHidden()
            .task { if clip.canPlay { player = AVPlayer(url: playbackURL) } }
            .sheet(isPresented: $showAdjustment) {
                NavigationStack { StabilizationSettingsView(directory: clip.directory)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { showAdjustment = false } } }
                }
            }
            .onChange(of: jobs.revisions[clip.id]) { _, _ in
                if hasStable { player?.pause(); showOriginal = false; player = AVPlayer(url: stableURL); saved = false }
            }
            .onChange(of: hasStable) { _, ready in
                if ready { player?.pause(); showOriginal = false; player = AVPlayer(url: stableURL); saved = false }
            }
            .onDisappear { player?.pause(); player = nil }
            .alert("保存提示", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("知道了", role: .cancel) { message = nil }
            } message: { Text(message ?? "") }
    }

    @MainActor
    private func saveToPhotos() async {
        guard !saving, !saved else { return }
        saving = true
        defer { saving = false }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            message = "请在系统设置中允许添加照片。原片仍保存在本机。"; return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: playbackURL)
            }
            saved = true
        } catch { message = error.localizedDescription }
    }
}

// Preserve the encoded frame, including stabilization borders, at either orientation.
private struct FullFramePlayer: UIViewRepresentable {
    var player: AVPlayer?
    func makeUIView(context: Context) -> PlayerSurface { PlayerSurface() }
    func updateUIView(_ view: PlayerSurface, context: Context) { view.playerLayer.player = player }
    final class PlayerSurface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        override init(frame: CGRect) {
            super.init(frame: frame)
            playerLayer.videoGravity = .resizeAspect
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}
