import Foundation

public enum ExportResolution: String, CaseIterable, Codable, Identifiable, Sendable {
    case fullHD, action2_8K
    public var id: String { rawValue }
    public var label: String { self == .fullHD ? "1080p（高清）" : "2.8K" }
    public var width: Int { self == .fullHD ? 1920 : 2816 }
}

public enum StabilizationPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case natural, standard, strong
    public var id: String { rawValue }
    public var label: String { switch self { case .natural: "自然"; case .standard: "标准"; case .strong: "强力" } }
    public var detail: String { switch self {
        case .natural: "保留运镜和更多视野"
        case .standard: "兼顾稳定和视野，适合日常拍摄"
        case .strong: "更稳，画面可能裁切更多"
    } }
    public var seconds: Double { switch self { case .natural: 0.3; case .standard: 0.8; case .strong: 3 } }
    public var crop: Double { switch self { case .natural: 1.5; case .standard: 2; case .strong: 2.5 } }
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
    public var automaticAdjustment: Bool = true
    public var exportResolution: ExportResolution = .action2_8K
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case strength, smoothingSeconds, maxCrop, dynamicCrop, allowBlackBorders, exportResolution, zoomTransitionSeconds, horizonLock, automaticAdjustment
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
        // Existing custom settings retain their original crop/edge policy.
        automaticAdjustment = try values.decodeIfPresent(Bool.self, forKey: .automaticAdjustment) ?? false
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
        try values.encode(automaticAdjustment, forKey: .automaticAdjustment)
    }
    public var preset: StabilizationPreset? {
        guard automaticAdjustment, dynamicCrop, !allowBlackBorders, zoomTransitionSeconds == 2 else { return nil }
        return StabilizationPreset.allCases.first { abs($0.seconds - smoothingSeconds) < 1e-9 && $0.crop == maxCrop }
    }
    public mutating func applyPreset(_ preset: StabilizationPreset) {
        smoothingSeconds = preset.seconds; maxCrop = preset.crop
        dynamicCrop = true; allowBlackBorders = false; zoomTransitionSeconds = 2
        automaticAdjustment = true
    }
    public func recommended() -> Self {
        var value = self; value.applyPreset(.standard); return value
    }
    public var isValid: Bool {
        smoothingSeconds.isFinite && (0...10).contains(smoothingSeconds)
            && maxCrop.isFinite && (1...5).contains(maxCrop)
            && zoomTransitionSeconds.isFinite && (0.5...10).contains(zoomTransitionSeconds)
    }
    private static let outputDefaultMigrationKey = "stabilizationOutputDefault2_8K_v1"
    public static func defaults(storage: UserDefaults = .standard) -> Self {
        var value = Self()
        if let data = storage.data(forKey: "stabilizationDefaults"),
           let saved = try? JSONDecoder().decode(Self.self, from: data), saved.isValid {
            value = saved
        }
        // Upgrade the old global 1080p default once; saved clip settings stay intact.
        // Subsequent explicit size choices are retained by saveDefaults.
        if !storage.bool(forKey: outputDefaultMigrationKey) {
            value.exportResolution = .action2_8K
            try? value.saveDefaults(storage: storage)
        }
        return value
    }
    public static func load(directory: URL) -> Self {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("stabilization-options.json")),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.isValid else { return defaults() }
        return value
    }
    public func saveDefaults(storage: UserDefaults = .standard) throws {
        guard isValid else { throw InputError("稳定参数无效。") }
        storage.set(try JSONEncoder().encode(self), forKey: "stabilizationDefaults")
        storage.set(true, forKey: Self.outputDefaultMigrationKey)
    }
    public func save(directory: URL) throws {
        guard isValid else { throw InputError("稳定参数无效。") }
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent("stabilization-options.json"), options: .atomic)
    }
}
