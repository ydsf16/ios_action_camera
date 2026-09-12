import Foundation

public struct StabilizationOptions: Codable, Equatable, Sendable {
    public var strength: Double = 0.5
    public var maxCrop: Double = 2.0
    public var dynamicCrop: Bool = true
    public var allowBlackBorders: Bool = false
    public init() {}
    public var isValid: Bool {
        strength.isFinite && (0...1).contains(strength) && maxCrop.isFinite && (1...5).contains(maxCrop)
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
