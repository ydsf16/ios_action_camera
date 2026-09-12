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
            .sheet(item: $selected) { ClipPreviewView(clip: $0) }
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
        NavigationStack {
            ScrollView { VStack(spacing: 16) {
                if clip.canPlay { VideoPlayer(player: player).frame(minHeight: 220, idealHeight: 360) }
                else { ContentUnavailableView("录制未完成", systemImage: "exclamationmark.triangle", description: Text("已有文件仍保存在本机，可通过“文件”App 导出检查。")) }
                Text(hasStable ? (showOriginal ? "原片" : "稳定结果") : "原片")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                if hasStable {
                    Button(showOriginal ? "查看稳定结果" : "查看原片") {
                        let time = player?.currentTime() ?? .zero
                        player?.pause(); showOriginal.toggle()
                        player = AVPlayer(url: playbackURL); player?.seek(to: time)
                        saved = false
                    }
                }
                Group {
                    switch jobs.states[clip.id] {
                    case .queued: Text("等待稳定处理").font(.footnote)
                    case let .processing(fraction):
                        ProgressView("正在稳定处理 \(Int(fraction*100))%", value: fraction).padding(.horizontal)
                        Button("取消") { jobs.cancel(clip.directory) }.font(.footnote)
                    case let .failed(error):
                        Text(error).font(.footnote).foregroundStyle(.orange).padding(.horizontal)
                        Button("重试稳定处理") { jobs.enqueue(clip.directory) }
                    default:
                        if !hasStable { Button("生成稳定视频") { jobs.enqueue(clip.directory) }.disabled(!clip.canPlay) }
                    }
                }
                Button("调整稳定参数") { showAdjustment = true }.disabled(busy || saving || !clip.canPlay)
                Button {
                    Task { await saveToPhotos() }
                } label: {
                    HStack {
                        if saving { ProgressView().tint(.white) }
                        Text(saving ? "正在保存…" : (saved ? "已保存到相册" : "保存到相册"))
                    }.frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent).disabled(saving || saved || busy || !clip.canPlay).padding(.horizontal)
                .padding(.bottom)
            }
            }
            .navigationTitle("预览").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
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
