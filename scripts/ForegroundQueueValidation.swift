// Test the production queue with a deterministic worker that models delayed cancellation.
import Foundation

final class ProcessingControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func pause(_ value: Bool) { }
    func checkpoint() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }
}
enum StabilizationProcessor {
    static let filename = "stabilized.mov"
    enum ParameterConflict: Error { case cropLimit }
    static func process(directory: URL, options: StabilizationOptions, control: ProcessingControl, progress: @escaping (Double) -> Void) async throws -> URL {
        let countURL = directory.appendingPathComponent("attempts")
        let count = (try? String(contentsOf: countURL, encoding: .utf8)).flatMap(Int.init) ?? 0
        try String(count + 1).write(to: countURL, atomically: true, encoding: .utf8)
        if count == 0 {
            do {
                while true { try control.checkpoint(); try await Task.sleep(nanoseconds: 2_000_000) }
            } catch {
                try await Task.sleep(nanoseconds: 50_000_000)
                throw error
            }
        }
        try control.checkpoint()
        let output = directory.appendingPathComponent(filename)
        try Data("stable".utf8).write(to: output)
        return output
    }
}
@main struct ForegroundQueueValidation {
    @MainActor static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw NSError(domain: "Queue validation timeout", code: 1)
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("foreground-queue-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        for scenario in ["return-after-stop", "return-before-stop", "manual-cancel", "cancel-before-background", "delete"] {
            let dir = root.appendingPathComponent(scenario)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("original".utf8).write(to: dir.appendingPathComponent("video.mov"))
            let jobs = StabilizationJobs()
            jobs.enqueue(dir)
            try await wait { FileManager.default.fileExists(atPath: dir.appendingPathComponent("attempts").path) }
            if scenario == "cancel-before-background" { jobs.cancel(dir) }
            jobs.setForeground(false)
            if scenario == "manual-cancel" { jobs.cancel(dir) }
            if scenario == "delete" {
                let result = await jobs.removeRecordings([dir], root: root)
                precondition(result.removed == [dir])
                jobs.setForeground(true)
                try await Task.sleep(nanoseconds: 100_000_000)
                precondition(!FileManager.default.fileExists(atPath: dir.path))
                continue
            }
            if scenario != "return-before-stop" { try await Task.sleep(nanoseconds: 120_000_000) }
            jobs.setForeground(true)
            if scenario == "manual-cancel" || scenario == "cancel-before-background" {
                try await wait { if case .failed = jobs.states[scenario] { return true }; return false }
                let attempts = try String(contentsOf: dir.appendingPathComponent("attempts"), encoding: .utf8)
                precondition(attempts == "1")
            } else {
                try await wait { if case .ready = jobs.states[scenario] { return true }; return false }
                let attempts = try String(contentsOf: dir.appendingPathComponent("attempts"), encoding: .utf8)
                precondition(attempts == "2")
            }
            let original = try Data(contentsOf: dir.appendingPathComponent("video.mov"))
            precondition(original == Data("original".utf8))
        }
        print("PASS: automatic restart across both foreground races; explicit cancel and deletion do not restart; originals preserved")
    }
}
