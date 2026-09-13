// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum RecordingLimitPolicy {
    public static let freeSeconds = 60.0
    public static func maximumDuration(hasPro: Bool) -> Double? { hasPro ? nil : freeSeconds }
    public static func reached(duration: Double, maximumDuration: Double?) -> Bool {
        guard let maximumDuration else { return false }
        return duration >= maximumDuration
    }
}
