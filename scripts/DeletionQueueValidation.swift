// Build with the production StabilizationJobs and CaptureCore sources; fake only the slow worker.
import Foundation

final class ProcessingControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    func pause(_ value: Bool) { }
    func checkpoint() throws {
        lock.lock(); defer { lock.unlock() }
        if stopped { throw CancellationError() }
    }
}

enum StabilizationProcessor {
    static let filename = "stabilized.mov"
    static func process(directory: URL, options: StabilizationOptions, control: ProcessingControl, progress: @escaping (Double) -> Void) async throws -> URL {
        try Data().write(to: directory.appendingPathComponent("started"))
        if directory.lastPathComponent == "active" {
            do {
                while true { try control.checkpoint(); try await Task.sleep(nanoseconds: 5_000_000) }
            } catch {
                // Model delayed audio shutdown: it can still write after cancellation is requested.
                try await Task.sleep(nanoseconds: 80_000_000)
                try Data("last write".utf8).write(to: directory.appendingPathComponent("audio-tail"))
                throw error
            }
        }
        let output = directory.appendingPathComponent(filename)
        try Data("stable".utf8).write(to: output)
        return output
    }
}

@main struct DeletionQueueValidation {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deletion-queue-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func package(_ name: String) throws -> URL {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("original".utf8).write(to: directory.appendingPathComponent("video.mov"))
            return directory
        }
        let active = try package("active"), queued = try package("queued"), keep = try package("keep")
        let jobs = StabilizationJobs()
        jobs.enqueue(active); jobs.enqueue(queued); jobs.enqueue(keep)
        try await waitUntil { FileManager.default.fileExists(atPath: active.appendingPathComponent("started").path) }
        let removal = Task { await jobs.removeRecordings([active, queued], root: root) }
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(FileManager.default.fileExists(atPath: active.path), "Removed before the worker finished")
        jobs.enqueue(active, force: true); jobs.enqueue(queued, force: true)
        let result = await removal.value
        precondition(result.failures.isEmpty && result.removed.count == 2)
        precondition(!FileManager.default.fileExists(atPath: active.path))
        precondition(!FileManager.default.fileExists(atPath: queued.path))
        precondition(jobs.states["active"] == nil && jobs.states["queued"] == nil)
        try await waitUntil { FileManager.default.fileExists(atPath: keep.appendingPathComponent("stabilized.mov").path) }
        precondition(FileManager.default.fileExists(atPath: keep.appendingPathComponent("video.mov").path))
        let pending = try package("pending")
        jobs.setRecording(true); jobs.enqueue(pending)
        let pendingResult = await jobs.removeRecordings([pending], root: root)
        precondition(pendingResult.failures.isEmpty)
        jobs.setRecording(false)
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(!FileManager.default.fileExists(atPath: pending.path))
        let invalid = await jobs.removeRecordings([root], root: root)
        precondition(invalid.removed.isEmpty && !invalid.failures.isEmpty)
        precondition(FileManager.default.fileExists(atPath: keep.path))
        print("PASS: active worker joined; queued jobs removed; re-enqueue blocked; unrelated job completes; paused queue deletion; invalid target rejected")
    }
    @MainActor static func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw NSError(domain: "Validation timeout", code: 1)
    }
}
