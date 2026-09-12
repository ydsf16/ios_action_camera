import SwiftUI

@MainActor
final class RecordingLibraryModel: ObservableObject {
    @Published private(set) var clips: [RecordedClip] = []
    @Published private(set) var loading = true
    @Published private(set) var deleting = false
    @Published var failure: String?
    private var loadRevision = 0

    func reload() async {
        loadRevision += 1
        let revision = loadRevision
        let root = CaptureService.recordingsRoot
        do {
            let loaded = try await Task.detached(priority: .userInitiated) { try RecordingStorage.load(root: root) }.value
            guard revision == loadRevision else { return }
            clips = loaded
        } catch { if revision == loadRevision { failure = error.localizedDescription } }
        if revision == loadRevision { loading = false }
    }

    func remove(_ clips: [RecordedClip]) async -> Bool {
        guard !deleting, !clips.isEmpty else { return false }
        deleting = true
        loadRevision += 1
        defer { deleting = false }
        let result = await StabilizationJobs.shared.removeRecordings(clips.map(\.directory), root: CaptureService.recordingsRoot)
        self.clips.removeAll { result.removed.contains($0.directory) }
        await reload()
        if !result.failures.isEmpty { failure = "部分素材未能删除，请重试。\n" + result.failures.joined(separator: "\n") }
        return result.failures.isEmpty
    }
}

struct ClipDeletion: Identifiable {
    let id = UUID()
    let clips: [RecordedClip]
    var title: String { "删除 \(clips.count) 段素材？" }
    var message: String {
        "将删除原片、稳定视频及运动数据，预计释放约 \(MediaText.storage(clips.reduce(0) { $0 + $1.allocatedBytes }))。\n已保存到系统相册的视频保留。删除后无法恢复。"
    }
}

enum MediaText {
    static func storage(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    static func duration(_ seconds: Double) -> String {
        let value = seconds.isFinite ? Int(max(0, min(seconds, 86_400_000))) : 0
        if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}
