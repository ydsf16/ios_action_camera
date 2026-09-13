import Foundation

public enum ExportResolution: String, CaseIterable, Codable, Identifiable, Sendable {
    case fullHD, action2_8K
    public var id: String { rawValue }
    public var label: String { self == .fullHD ? "1080p（高清）" : "2.8K" }
    public var width: Int { self == .fullHD ? 1920 : 2816 }
}

public struct StabilizationOptions: Codable, Equatable, Sendable {
    /// Store the physical smoothing parameter so future UI scales cannot alter old clips.
    public var smoothingSeconds: Double = 0.8
    public var strength: Double {
        get { log1p(smoothingSeconds / 0.1) / log(101) }
        set { smoothingSeconds = newValue == 1 ? 10 : 0.1 * expm1(newValue * log(101)) }
    }
    public var strengthLabel: String {
        if smoothingSeconds == 0 { return "关闭" }
        if smoothingSeconds < 0.5 { return "自然" }
        if smoothingSeconds < 2 { return "标准" }
        if smoothingSeconds < 4 { return "强" }
        return "超强"
    }
    public var maxCrop: Double = 2.0
    public var dynamicCrop: Bool = true
    public var allowBlackBorders: Bool = false
    public var zoomTransitionSeconds: Double = 2
    public var horizonLock: Bool = false
    public var exportResolution: ExportResolution = .action2_8K
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case strength, smoothingSeconds, maxCrop, dynamicCrop, allowBlackBorders, exportResolution, zoomTransitionSeconds, horizonLock
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let seconds = try values.decodeIfPresent(Double.self, forKey: .smoothingSeconds) {
            smoothingSeconds = seconds
        } else {
            let legacy = try values.decode(Double.self, forKey: .strength)
            guard legacy.isFinite, (0...1).contains(legacy) else { throw InputError("旧版稳定参数无效。") }
            // Old 0% meant 0.16 s, not off. Preserve the requested effect exactly.
            smoothingSeconds = 0.16 * pow(25, legacy)
        }
        maxCrop = try values.decode(Double.self, forKey: .maxCrop)
        dynamicCrop = try values.decode(Bool.self, forKey: .dynamicCrop)
        allowBlackBorders = try values.decode(Bool.self, forKey: .allowBlackBorders)
        // Existing per-clip/default settings retain their stabilization choices.
        exportResolution = try values.decodeIfPresent(ExportResolution.self, forKey: .exportResolution) ?? .fullHD
        zoomTransitionSeconds = try values.decodeIfPresent(Double.self, forKey: .zoomTransitionSeconds) ?? 2
        horizonLock = try values.decodeIfPresent(Bool.self, forKey: .horizonLock) ?? false
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(smoothingSeconds, forKey: .smoothingSeconds)
        try values.encode(maxCrop, forKey: .maxCrop)
        try values.encode(dynamicCrop, forKey: .dynamicCrop)
        try values.encode(allowBlackBorders, forKey: .allowBlackBorders)
        try values.encode(exportResolution, forKey: .exportResolution)
        try values.encode(zoomTransitionSeconds, forKey: .zoomTransitionSeconds)
        try values.encode(horizonLock, forKey: .horizonLock)
    }
    public var isValid: Bool {
        smoothingSeconds.isFinite && (0...10).contains(smoothingSeconds)
            && maxCrop.isFinite && (1...5).contains(maxCrop)
            && zoomTransitionSeconds.isFinite && (0.5...10).contains(zoomTransitionSeconds)
    }
    public static func defaults() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "stabilizationDefaults"),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.isValid else { return Self() }
        return value
    }
    public static func load(directory: URL) -> Self {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("stabilization-options.json")),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.isValid else { return defaults() }
        return value
    }
    public func saveDefaults() throws {
        guard isValid else { throw InputError("稳定参数无效。") }
        UserDefaults.standard.set(try JSONEncoder().encode(self), forKey: "stabilizationDefaults")
    }
    public func save(directory: URL) throws {
        guard isValid else { throw InputError("稳定参数无效。") }
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent("stabilization-options.json"), options: .atomic)
    }
}
