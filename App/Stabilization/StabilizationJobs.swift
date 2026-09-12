// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

@MainActor
final class StabilizationJobs: ObservableObject {
    static let shared = StabilizationJobs()
    enum State { case queued, processing(Double), ready, failed(String) }
    @Published private(set) var states: [String: State] = [:]
    @Published private(set) var revisions: [String: Int] = [:]
    private struct Job { let directory: URL; let options: StabilizationOptions }
    private var pending: [Job] = []
    private var active: URL?
    private var control: ProcessingControl?
    private var recording = false
    private var foreground = true

    func enqueue(_ directory: URL, options: StabilizationOptions? = nil, force: Bool = false) {
        let key = directory.lastPathComponent
        if !force, FileManager.default.fileExists(atPath: directory.appendingPathComponent(StabilizationProcessor.filename).path) {
            states[key] = .ready; return
        }
        guard active != directory, !pending.contains(where: { $0.directory == directory }) else { return }
        let selected = options ?? StabilizationOptions.load(directory: directory)
        do { try selected.save(directory: directory) }
        catch { states[key] = .failed(error.localizedDescription); return }
        pending.append(Job(directory: directory, options: selected)); states[key] = .queued; next()
    }
    func setRecording(_ value: Bool) { recording = value; control?.pause(value); if !value { next() } }
    func setForeground(_ value: Bool) {
        foreground = value
        if !value { control?.cancel() } else { next() }
    }
    func cancel(_ directory: URL) {
        pending.removeAll { $0.directory == directory }
        if active == directory { control?.cancel() }
        else { states[directory.lastPathComponent] = .failed("已取消，原片已保留。") }
    }
    private func next() {
        guard active == nil, !recording, foreground, !pending.isEmpty else { return }
        let job = pending.removeFirst()
        let directory = job.directory
        let token = ProcessingControl()
        active = directory; control = token
        states[directory.lastPathComponent] = .processing(0)
        Task.detached(priority: .utility) { [weak self] in
            let result: Result<URL,Error>
            do {
                let url = try await StabilizationProcessor.process(directory: directory, options: job.options, control: token) { fraction in
                    Task { @MainActor [weak self] in
                        if self?.active == directory { self?.states[directory.lastPathComponent] = .processing(fraction) }
                    }
                }
                result = .success(url)
            } catch { result = .failure(error) }
            await self?.finished(directory, result: result)
        }
    }
    private func finished(_ directory: URL, result: Result<URL,Error>) {
        switch result {
        case .success:
            states[directory.lastPathComponent] = .ready
            revisions[directory.lastPathComponent, default: 0] += 1
        case let .failure(error):
            let diagnostic = ["stage": "failed", "error": error.localizedDescription,
                              "updated_at": ISO8601DateFormatter().string(from: Date())]
            if let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]) {
                try? data.write(to: directory.appendingPathComponent("processing-status.json"), options: .atomic)
            }
            states[directory.lastPathComponent] = .failed(error is CancellationError ? "处理已停止，返回前台后可重试。" : error.localizedDescription)
        }
        active = nil; control = nil; next()
    }
}
