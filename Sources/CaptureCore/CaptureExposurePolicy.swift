import Foundation

public enum CaptureExposurePolicy: String, CaseIterable, Identifiable {
    case automatic
    case balanced
    case motion
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .automatic: "自动（室内优先）"
        case .balanced: "室内折中（≤10 ms）"
        case .motion: "运动清晰（≤5 ms）"
        }
    }
    public var explanation: String {
        switch self {
        case .automatic:
            "恢复系统自动曝光与 ISO，让相机适应室内灯光。曝光可能超过 10 ms，快速运动可能留下更多拖影。"
        case .balanced:
            "自动曝光上限 10 ms，减少长曝光拖影；暗处可能增加噪点或变暗。实际曝光由系统选择，若灯光仍闪动，请切回自动模式。"
        case .motion:
            "曝光上限 5 ms，减少运动拖影。室内 LED 或电梯灯光下可能出现明暗闪动或条纹。"
        }
    }
    public var maximumExposureMilliseconds: Int64? {
        switch self {
        case .automatic: nil
        case .balanced: 10
        case .motion: 5
        }
    }
    public static func load() -> Self {
        UserDefaults.standard.string(forKey: "captureExposurePolicy").flatMap(Self.init(rawValue:)) ?? .motion
    }
    public func save() { UserDefaults.standard.set(rawValue, forKey: "captureExposurePolicy") }
}
