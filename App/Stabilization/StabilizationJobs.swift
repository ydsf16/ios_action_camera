// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

@MainActor
final class StabilizationJobs: ObservableObject {
    static let shared = StabilizationJobs()
    enum State { case queued, processing(Double), ready, failed(String) }
    @Published private(set) var states: [String: State] = [:]
    private var pending: [URL] = []
    private var active: URL?
    private var control: ProcessingControl?
    private var recording = false
    private var foreground = true

    func enqueue(_ directory: URL) {
        let key = directory.lastPathComponent
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(StabilizationProcessor.filename).path) {
            states[key] = .ready; return
        }
        guard active != directory, !pending.contains(directory) else { return }
        pending.append(directory); states[key] = .queued; next()
    }
    func setRecording(_ value: Bool) { recording = value; control?.pause(value); if !value { next() } }
    func setForeground(_ value: Bool) {
        foreground = value
        if !value { control?.cancel() } else { next() }
    }
    func cancel(_ directory: URL) {
        pending.removeAll { $0 == directory }
        if active == directory { control?.cancel() }
        else { states[directory.lastPathComponent] = .failed("已取消，原片已保留。") }
    }
    private func next() {
        guard active == nil, !recording, foreground, !pending.isEmpty else { return }
        let directory = pending.removeFirst()
        let token = ProcessingControl()
        active = directory; control = token
        states[directory.lastPathComponent] = .processing(0)
        Task.detached(priority: .utility) { [weak self] in
            let result: Result<URL,Error>
            do {
                let url = try await StabilizationProcessor.process(directory: directory, control: token) { fraction in
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
        case .success: states[directory.lastPathComponent] = .ready
        case let .failure(error):
            states[directory.lastPathComponent] = .failed(error is CancellationError ? "处理已停止，返回前台后可重试。" : error.localizedDescription)
        }
        active = nil; control = nil; next()
    }
}
