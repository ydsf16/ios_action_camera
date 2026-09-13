import XCTest
@testable import CaptureCore

final class RecordingLimitPolicyTests: XCTestCase {
    func testFrameBoundaryAtAllSupportedRates() {
        for fps in [24.0, 30, 60] {
            let limit = RecordingLimitPolicy.maximumDuration(hasPro: false)
            XCTAssertFalse(RecordingLimitPolicy.reached(duration: 60 - 1/fps, maximumDuration: limit))
            XCTAssertTrue(RecordingLimitPolicy.reached(duration: 60, maximumDuration: limit))
            XCTAssertTrue(RecordingLimitPolicy.reached(duration: 60 + 1/fps, maximumDuration: limit))
        }
    }
    func testPurchaseAndRefundAffectNextRecordingLimit() {
        XCTAssertNil(RecordingLimitPolicy.maximumDuration(hasPro: true))
        XCTAssertFalse(RecordingLimitPolicy.reached(duration: 600, maximumDuration: nil))
        XCTAssertEqual(RecordingLimitPolicy.maximumDuration(hasPro: false), 60)
    }
}
