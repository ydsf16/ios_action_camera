// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

@MainActor
final class StabilizationJobs: ObservableObject {
    static let shared = StabilizationJobs()
    enum State { case queued, processing(Double), ready, failed(String) }
    @Published private(set) var states: [String: State] = [:]
    @Published private(set) var revisions: [String: Int] = [:]
    @Published private(set) var parameterConflicts: Set<String> = []
    private struct Job { let directory: URL; let options: StabilizationOptions }
    private var pending: [Job] = []
    private var active: URL?
    private var activeJob: Job?
    private var resumeAfterBackground = false
    private var control: ProcessingControl?
    private var worker: Task<Void, Never>?
    private var deleting: Set<URL> = []
    private var recording = false
    private var foreground = true

    func enqueue(_ directory: URL, options: StabilizationOptions? = nil, force: Bool = false) {
        guard !deleting.contains(directory) else { return }
        let key = directory.lastPathComponent
        if !force, FileManager.default.fileExists(atPath: directory.appendingPathComponent(StabilizationProcessor.filename).path) {
            states[key] = .ready; return
        }
        guard active != directory, !pending.contains(where: { $0.directory == directory }) else { return }
        parameterConflicts.remove(key)
        let selected = options ?? StabilizationOptions.load(directory: directory)
        do { try selected.save(directory: directory) }
        catch { states[key] = .failed(error.localizedDescription); return }
        pending.append(Job(directory: directory, options: selected)); states[key] = .queued; next()
    }
    private func updateIdleTimer() {
        #if canImport(UIKit)
        var validation = false
        #if DEBUG
        validation = ProcessInfo.processInfo.arguments.contains("--keep-awake-for-validation")
        #endif
        UIApplication.shared.isIdleTimerDisabled = foreground && (validation || recording || active != nil || !pending.isEmpty)
        #endif
    }
    func setRecording(_ value: Bool) { recording = value; control?.pause(value); if !value { next() }; updateIdleTimer() }
    func setForeground(_ value: Bool) {
        foreground = value
        if !value {
            if active != nil { resumeAfterBackground = true; control?.cancel() }
        } else { next() }
        updateIdleTimer()
    }
    func cancel(_ directory: URL) {
        pending.removeAll { $0.directory == directory }
        if active == directory { activeJob = nil; resumeAfterBackground = false; control?.cancel() }
        else { states[directory.lastPathComponent] = .failed("已取消，原片已保留。") }
        updateIdleTimer()
    }

    /// Quiesce all selected jobs before touching files; unrelated queued clips can continue.
    func removeRecordings(_ directories: [URL], root: URL) async -> RecordingDeletionResult {
        var result = RecordingDeletionResult()
        var targets: Set<URL> = []
        for directory in Set(directories) {
            do {
                _ = try RecordingStorage.validate(directory, root: root)
                guard !deleting.contains(directory) else {
                    result.failures.append("这段素材正在删除，请稍候。")
                    continue
                }
                targets.insert(directory)
            } catch { result.failures.append(error.localizedDescription) }
        }
        deleting.formUnion(targets)
        defer { deleting.subtract(targets); updateIdleTimer() }
        pending.removeAll { targets.contains($0.directory) }
        if let active, targets.contains(active) {
            let running = worker
            activeJob = nil; resumeAfterBackground = false
            control?.cancel()
            await running?.value
        }
        let selected = Array(targets)
        let removal = await Task.detached(priority: .userInitiated) {
            RecordingStorage.remove(selected, root: root)
        }.value
        for directory in removal.removed {
            states.removeValue(forKey: directory.lastPathComponent)
            revisions.removeValue(forKey: directory.lastPathComponent)
            parameterConflicts.remove(directory.lastPathComponent)
        }
        for directory in targets where !removal.removed.contains(directory) {
            states[directory.lastPathComponent] = .failed("删除未完成，素材仍保留，可重新处理或重试删除。")
        }
        result.removed += removal.removed
        result.failures += removal.failures
        return result
    }
    private func next() {
        guard active == nil, !recording, foreground, !pending.isEmpty else { return }
        let job = pending.removeFirst()
        let directory = job.directory
        let token = ProcessingControl()
        active = directory; activeJob = job; resumeAfterBackground = false; control = token
        updateIdleTimer()
        states[directory.lastPathComponent] = .processing(0)
        worker = Task.detached(priority: .utility) { [weak self] in
            let result: Result<URL,Error>
            do {
                let url = try await StabilizationProcessor.process(directory: directory, options: job.options, control: token) { fraction in
                    Task { @MainActor [weak self] in
                        if self?.active == directory, self?.deleting.contains(directory) == false {
                            self?.states[directory.lastPathComponent] = .processing(fraction)
                        }
                    }
                }
                result = .success(url)
            } catch { result = .failure(error) }
            await self?.finished(directory, result: result)
        }
    }
    private func finished(_ directory: URL, result: Result<URL,Error>) {
        if !deleting.contains(directory) {
            switch result {
            case .success:
                states[directory.lastPathComponent] = .ready
                revisions[directory.lastPathComponent, default: 0] += 1
            case let .failure(error):
                if error is CancellationError, resumeAfterBackground, let job = activeJob {
                    pending.insert(job, at: 0)
                    states[directory.lastPathComponent] = .queued
                    break
                }
                if error is StabilizationProcessor.ParameterConflict { parameterConflicts.insert(directory.lastPathComponent) }
                let diagnostic = ["stage": "failed", "error": error.localizedDescription,
                                  "updated_at": ISO8601DateFormatter().string(from: Date())]
                if let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]) {
                    try? data.write(to: directory.appendingPathComponent("processing-status.json"), options: .atomic)
                }
                states[directory.lastPathComponent] = .failed(error is CancellationError ? "已取消，原片已保留。" : error.localizedDescription)
            }
        }
        active = nil; activeJob = nil; resumeAfterBackground = false; control = nil; worker = nil; next(); updateIdleTimer()
    }
}
