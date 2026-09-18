import Foundation

/// Result from the engine, not an estimate derived from the settings slider.
public struct StabilizationReport: Codable, Equatable, Sendable {
    public let requestedSmoothingSeconds: Double
    public let effectiveSmoothingSeconds: Double
    public let minimumCrop: Double
    public let maximumCrop: Double
    public let requestedHorizonPercent: Double?
    public let effectiveHorizonPercent: Double?
    /// Absent on receipts created before local crop-aware smoothing was introduced.
    public let locallyAdjusted: Bool?
    public var cropLimited: Bool { effectiveSmoothingSeconds + 1e-9 < requestedSmoothingSeconds }
    public var horizonReduced: Bool { (effectiveHorizonPercent ?? 0) + 1e-9 < (requestedHorizonPercent ?? 0) }
    public var localAdjustmentApplied: Bool { locallyAdjusted ?? false }
    public var adjusted: Bool { cropLimited || horizonReduced || localAdjustmentApplied }
    public var unstabilizedFallback: Bool {
        (requestedSmoothingSeconds > 0 || (requestedHorizonPercent ?? 0) > 0)
            && effectiveSmoothingSeconds == 0 && effectiveHorizonPercent == 0
    }
    public var summary: String {
        if unstabilizedFallback { return "运动超出稳定范围 · 仅调整画幅" }
        if localAdjustmentApplied && !horizonReduced { return "已局部适配剧烈运动" }
        if adjusted { return "已根据运动自动调整" }
        return requestedSmoothingSeconds == 0 && (effectiveHorizonPercent ?? 0) == 0 ? "平滑已关闭" : "已按设定效果处理"
    }
    public var details: String {
        var parts: [String] = []
        if unstabilizedFallback { parts.append("本次未能提供稳定效果，已保留原片及画幅调整后的结果。") }
        if localAdjustmentApplied { parts.append("为避免黑边，仅在接近裁切上限的区间减弱了稳定修正。") }
        if cropLimited { parts.append(String(format: "为保留画面，平滑从 %.2f 秒调整为 %.2f 秒。", requestedSmoothingSeconds, effectiveSmoothingSeconds)) }
        if horizonReduced { parts.append(String(format: "保持水平从 %.0f%% 调整为 %.0f%%。", requestedHorizonPercent ?? 0, effectiveHorizonPercent ?? 0)) }
        parts.append(String(format: "实际裁切 %.1f× – %.1f×。", minimumCrop, maximumCrop))
        return parts.joined(separator: "\n")
    }
    public init(requestedSmoothingSeconds: Double, effectiveSmoothingSeconds: Double, minimumCrop: Double, maximumCrop: Double,
                requestedHorizonPercent: Double? = nil, effectiveHorizonPercent: Double? = nil, locallyAdjusted: Bool? = false) {
        self.requestedSmoothingSeconds = requestedSmoothingSeconds
        self.effectiveSmoothingSeconds = effectiveSmoothingSeconds
        self.minimumCrop = minimumCrop; self.maximumCrop = maximumCrop
        self.requestedHorizonPercent = requestedHorizonPercent; self.effectiveHorizonPercent = effectiveHorizonPercent
        self.locallyAdjusted = locallyAdjusted
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
        if let requested = r.requestedHorizonPercent, let effective = r.effectiveHorizonPercent {
            guard requested.isFinite, effective.isFinite, (0...100).contains(requested), (0...requested).contains(effective) else { return nil }
        } else if r.requestedHorizonPercent != nil || r.effectiveHorizonPercent != nil { return nil }
        return receipt
    }
}
