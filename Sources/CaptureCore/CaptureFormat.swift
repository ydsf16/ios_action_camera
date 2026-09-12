import Foundation

public enum CaptureResolution: String, CaseIterable, Codable, Identifiable {
    case fullHD, uhd4K
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .fullHD: "1080p"
        case .uhd4K: "4K"
        }
    }
    public var width: Int {
        switch self {
        case .fullHD: 1920
        case .uhd4K: 3840
        }
    }
    public var height: Int { width * 9 / 16 }
}

public struct CaptureFormat: Equatable, Hashable, Codable, Identifiable {
    public let resolution: CaptureResolution
    public let fps: Int
    public var id: String { "\(resolution.rawValue)-\(fps)" }
    public var label: String { "\(resolution.label) · \(fps)" }
    public static let frameRates = [24, 30, 60]
    public static let standard = Self(resolution: .uhd4K, fps: 30)
    public static let candidates = CaptureResolution.allCases.flatMap { resolution in
        frameRates.map { Self(resolution: resolution, fps: $0) }
    }

    public init(resolution: CaptureResolution, fps: Int) {
        self.resolution = resolution
        self.fps = fps
    }

    /// Lens changes keep the frame rate if possible, then choose the closest size.
    /// Resolution-picker changes pass only candidates of the requested resolution.
    public func resolved(in supported: [Self]) -> Self? {
        if supported.contains(self) { return self }
        let sameRate = supported.filter { $0.fps == fps }
        let choices = sameRate.isEmpty ? supported : sameRate
        return choices.sorted {
            let a = abs($0.resolution.width - resolution.width)
            let b = abs($1.resolution.width - resolution.width)
            if a != b { return a < b }
            if abs($0.fps - fps) != abs($1.fps - fps) { return abs($0.fps - fps) < abs($1.fps - fps) }
            if $0.resolution.width != $1.resolution.width { return $0.resolution.width < $1.resolution.width }
            return $0.fps < $1.fps
        }.first
    }

    public static func load(defaults: UserDefaults = .standard) -> Self {
        guard let raw = defaults.string(forKey: "captureResolution"),
              let resolution = raw == "hd720" ? .fullHD : CaptureResolution(rawValue: raw),
              frameRates.contains(defaults.integer(forKey: "captureFPS")) else { return .standard }
        return Self(resolution: resolution, fps: defaults.integer(forKey: "captureFPS"))
    }
    public func save(defaults: UserDefaults = .standard) {
        defaults.set(resolution.rawValue, forKey: "captureResolution")
        defaults.set(fps, forKey: "captureFPS")
    }

    /// Keep the existing 4K30/1080p30 budget and scale it with encoded frame rate.
    public static func videoBitRate(width: Int, height: Int, fps: Int) -> Int {
        let base = min(50_000_000.0, 16_000_000.0 * Double(width) * Double(height) / (1920 * 1080))
        return Int((base * Double(fps) / 30).rounded())
    }
}
