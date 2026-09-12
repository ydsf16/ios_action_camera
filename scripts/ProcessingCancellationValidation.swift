import Foundation

@main struct ProcessingCancellationValidation {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Supply a synthetic fixture directory") }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("motioncam-cancellation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("clip", isDirectory: true)
        try FileManager.default.copyItem(at: fixture, to: directory)
        let original = try Data(contentsOf: directory.appendingPathComponent("video.mov"))
        let previous = Data("previous stabilized result".utf8)
        let output = directory.appendingPathComponent(StabilizationProcessor.filename)
        try previous.write(to: output)
        let control = ProcessingControl()
        do {
            _ = try await StabilizationProcessor.process(directory: directory, options: StabilizationOptions.load(directory: directory), control: control) { fraction in
                if fraction > 0 { control.cancel() }
            }
            fatalError("Expected cancellation")
        } catch is CancellationError { }
        let savedResult = try Data(contentsOf: output)
        precondition(savedResult == previous)
        let savedOriginal = try Data(contentsOf: directory.appendingPathComponent("video.mov"))
        precondition(savedOriginal == original)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        precondition(files.allSatisfy { !$0.contains("partial.mov") })
        let jobs = StabilizationJobs()
        jobs.enqueue(directory, force: true)
        var observedProgress = false
        for _ in 0..<6000 {
            if case let .processing(value) = jobs.states["clip"], value > 0 { observedProgress = true; break }
            if case let .failed(reason) = jobs.states["clip"] { fatalError(reason) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        precondition(observedProgress, "Expected to observe an active Metal export")
        let result = await jobs.removeRecordings([directory], root: root)
        precondition(result.failures.isEmpty && result.removed.count == 1)
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(!FileManager.default.fileExists(atPath: directory.path))
        precondition(jobs.states["clip"] == nil)
        print("PASS: real Metal/audio cancellation preserves original and previous output, clears partials; deleting active export leaves no files or queue state")
    }
}
