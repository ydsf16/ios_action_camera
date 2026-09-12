import Foundation

public struct RecordedClip: Identifiable, Sendable {
    public let directory: URL
    public let manifest: RecordingManifest
    public let allocatedBytes: Int64
    // Queue keys and storage identity both come from the directory, including legacy manifests.
    public var id: String { directory.lastPathComponent }
    public var video: URL { directory.appendingPathComponent("video.mov") }
    public var canPlay: Bool { manifest.status == "complete" && FileManager.default.fileExists(atPath: video.path) }
}

public struct RecordingDeletionResult: Sendable {
    public var removed: [URL] = []
    public var failures: [String] = []
    public init() {}
}

/// File work runs off the UI thread. Callers must stop writers and players before removal.
public enum RecordingStorage {
    public static func load(root: URL) throws -> [RecordedClip] {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        return try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
            .compactMap { directory in
                guard (try? validate(directory, root: root)) != nil,
                      let manifest = try? RecordingManifest.read(from: directory.appendingPathComponent("manifest.json")) else { return nil }
                return RecordedClip(directory: directory, manifest: manifest, allocatedBytes: allocatedBytes(in: directory))
            }
            .sorted { $0.manifest.createdAt > $1.manifest.createdAt }
    }

    public static func allocatedBytes(in directory: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var size: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true,
                  values.isRegularFile == true else { continue }
            size += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return size
    }

    /// Reject the root itself, nested/outside paths and symlink packages. Missing children are idempotent.
    @discardableResult
    public static func validate(_ directory: URL, root: URL) throws -> URL {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = directory.standardizedFileURL
        guard candidate.deletingLastPathComponent().resolvingSymlinksInPath() == root,
              candidate.resolvingSymlinksInPath().deletingLastPathComponent() == root else {
            throw StorageError.invalidDirectory
        }
        if FileManager.default.fileExists(atPath: candidate.path) {
            let values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw StorageError.invalidDirectory }
        }
        return candidate
    }

    public static func remove(_ directories: [URL], root: URL) -> RecordingDeletionResult {
        var result = RecordingDeletionResult()
        for directory in Set(directories) {
            do {
                let url = try validate(directory, root: root)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                result.removed.append(directory)
            } catch { result.failures.append("\(directory.lastPathComponent)：\(error.localizedDescription)") }
        }
        return result
    }

    private enum StorageError: LocalizedError {
        case invalidDirectory
        var errorDescription: String? { "只能删除素材目录中的单个录制文件夹。" }
    }
}
