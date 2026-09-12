import Foundation

public enum CaptureExposurePolicy: String, CaseIterable, Identifiable {
    case automatic
    case motion
    public var id: String { rawValue }
    public var title: String { self == .automatic ? "自动（室内优先）" : "运动清晰（≤5 ms）" }
    public var explanation: String {
        self == .automatic
            ? "恢复系统自动曝光与 ISO，让相机适应室内灯光。曝光可能超过 5 ms，快速运动可能留下更多拖影。"
            : "曝光上限 5 ms，减少运动拖影。室内 LED 或电梯灯光下可能出现明暗闪动或条纹。"
    }
    public static func load() -> Self {
        UserDefaults.standard.string(forKey: "captureExposurePolicy").flatMap(Self.init(rawValue:)) ?? .motion
    }
    public func save() { UserDefaults.standard.set(rawValue, forKey: "captureExposurePolicy") }
}
