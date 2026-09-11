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
            Text(clip.manifest.status == "complete" ? "原片" : "录制异常 · 数据已保留")
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
    @State private var player: AVPlayer?
    @State private var saving = false
    @State private var saved = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if clip.canPlay { VideoPlayer(player: player) }
                else { ContentUnavailableView("录制未完成", systemImage: "exclamationmark.triangle", description: Text("已有文件仍保存在本机，可通过“文件”App 导出检查。")) }
                Text(clip.manifest.status == "complete" ? "原片 · 尚未进行稳定处理" : (clip.manifest.error ?? "上次录制被中断"))
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                Button {
                    Task { await saveToPhotos() }
                } label: {
                    HStack {
                        if saving { ProgressView().tint(.white) }
                        Text(saving ? "正在保存…" : (saved ? "已保存到相册" : "保存到相册"))
                    }.frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent).disabled(saving || saved || !clip.canPlay).padding(.horizontal)
                .padding(.bottom)
            }
            .navigationTitle("预览").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { if clip.canPlay { player = AVPlayer(url: clip.video) } }
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
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: clip.video)
            }
            saved = true
        } catch { message = error.localizedDescription }
    }
}
