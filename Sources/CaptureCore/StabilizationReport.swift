import Foundation

/// Result from the engine, not an estimate derived from the settings slider.
public struct StabilizationReport: Codable, Equatable, Sendable {
    public let requestedSmoothingSeconds: Double
    public let effectiveSmoothingSeconds: Double
    public let minimumCrop: Double
    public let maximumCrop: Double
    public var cropLimited: Bool { effectiveSmoothingSeconds + 1e-9 < requestedSmoothingSeconds }
    public var summary: String {
        cropLimited ? "已受裁切限制，平滑强度已降低" : requestedSmoothingSeconds == 0 ? "平滑已关闭" : "已按设定强度处理"
    }
    public init(requestedSmoothingSeconds: Double, effectiveSmoothingSeconds: Double, minimumCrop: Double, maximumCrop: Double) {
        self.requestedSmoothingSeconds = requestedSmoothingSeconds
        self.effectiveSmoothingSeconds = effectiveSmoothingSeconds
        self.minimumCrop = minimumCrop; self.maximumCrop = maximumCrop
    }
    public struct Receipt: Decodable, Sendable {
        public let options: StabilizationOptions
        public let stabilization: StabilizationReport
    }
    public static func load(directory: URL) -> Receipt? {
        // Old exports have no diagnostics. Do not infer that they were unconstrained.
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("stabilized.mov").path),
              let data = try? Data(contentsOf: directory.appendingPathComponent("stabilization.json")),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data) else { return nil }
        let r = receipt.stabilization
        guard receipt.options.isValid,
              [r.requestedSmoothingSeconds, r.effectiveSmoothingSeconds, r.minimumCrop, r.maximumCrop].allSatisfy(\.isFinite),
              (0...10).contains(r.requestedSmoothingSeconds),
              r.effectiveSmoothingSeconds >= 0, r.effectiveSmoothingSeconds <= r.requestedSmoothingSeconds,
              r.minimumCrop >= 1, r.maximumCrop >= r.minimumCrop, r.maximumCrop <= 5.000001 else { return nil }
        return receipt
    }
}
