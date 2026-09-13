import Foundation
import CoreGraphics

struct CameraFocusFeedback: Equatable {
    enum Phase: Equatable { case tracking, locking, locked, unavailable, resumed }
    let id: UUID
    let point: CGPoint?
    var phase: Phase
    var text: String {
        switch phase {
        case .tracking: "自动对焦"
        case .locking: "正在对焦…"
        case .locked: "焦点已锁定 · 轻点恢复"
        case .unavailable: "此镜头不支持点按对焦"
        case .resumed: "镜头已切换，恢复自动对焦"
        }
    }
    var persistent: Bool { phase == .locking || phase == .locked }
}
