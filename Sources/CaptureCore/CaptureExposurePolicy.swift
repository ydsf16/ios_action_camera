import Foundation

public enum CaptureExposurePolicy: String, CaseIterable, Identifiable {
    case automatic
    case balanced
    case motion
    case fastMotion
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .automatic: "自动"
        case .balanced: "≤10 ms"
        case .motion: "≤5 ms"
        case .fastMotion: "≤2 ms"
        }
    }
    public var explanation: String {
        switch self {
        case .automatic:
            "适合室内与日常拍摄。相机自动调节曝光；运动时可能有拖影，部分 LED 灯光下仍可能闪烁。"
        case .balanced:
            "曝光不超过 10 ms，兼顾进光量与运动清晰度。适合光线充足的场景；灯光下出现闪烁时，建议切回自动。"
        case .motion:
            "曝光不超过 5 ms，减少运动拖影，推荐明亮室外。暗处可能变暗或增加噪点，灯光下可能闪烁。"
        case .fastMotion:
            "曝光不超过 2 ms，适合明亮室外的快速运动。需要更充足的光线；暗处噪点和灯光闪烁可能更明显。"
        }
    }
    public var maximumExposureMilliseconds: Int64? {
        switch self {
        case .automatic: nil
        case .balanced: 10
        case .motion: 5
        case .fastMotion: 2
        }
    }
    public static func load() -> Self {
        UserDefaults.standard.string(forKey: "captureExposurePolicy").flatMap(Self.init(rawValue:)) ?? .motion
    }
    public func save() { UserDefaults.standard.set(rawValue, forKey: "captureExposurePolicy") }
}
