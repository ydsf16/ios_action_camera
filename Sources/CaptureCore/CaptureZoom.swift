import Foundation

/// UI zoom is relative to the wide camera; AVFoundation zoom is relative to the
/// active device's widest field of view. Keep this mapping separate from crop.
public struct CaptureZoom: Equatable, Sendable {
    public let multiplier: Double
    public let minimum: Double
    public let maximum: Double
    public let stops: [Double]

    public init(multiplier: Double, minimumDeviceZoom: Double, maximumDeviceZoom: Double, nativeDeviceZooms: [Double]) {
        let scale = multiplier.isFinite && multiplier > 0 ? multiplier : 1
        let lower = minimumDeviceZoom.isFinite ? max(1, minimumDeviceZoom) : 1
        let upper = maximumDeviceZoom.isFinite ? max(lower, maximumDeviceZoom) : lower
        self.multiplier = scale
        let displayMinimum = lower * scale
        // A bounded first release avoids presenting extreme digital enlargement.
        let displayMaximum = max(displayMinimum, min(upper * scale, 5))
        minimum = displayMinimum
        maximum = displayMaximum
        stops = Array(Set(([displayMinimum, 1, 2] + nativeDeviceZooms.map { $0 * scale })
            .filter { $0.isFinite && $0 >= displayMinimum && $0 <= displayMaximum }
            .map { ($0 * 100).rounded() / 100 })).sorted()
    }

    public func clamped(_ displayZoom: Double) -> Double {
        displayZoom.isFinite ? min(maximum, max(minimum, displayZoom)) : minimum
    }
    public func deviceZoom(for displayZoom: Double) -> Double { clamped(displayZoom) / multiplier }
    public func displayZoom(for deviceZoom: Double) -> Double { clamped(deviceZoom * multiplier) }
    public func zoom(at position: Double) -> Double {
        let fraction = position.isFinite ? min(1, max(0, position)) : 0
        return minimum * pow(maximum / minimum, fraction)
    }
    public func position(for displayZoom: Double) -> Double {
        maximum > minimum ? log(clamped(displayZoom) / minimum) / log(maximum / minimum) : 0
    }
    public static func label(_ value: Double) -> String { String(format: "%.1f×", value) }
}
