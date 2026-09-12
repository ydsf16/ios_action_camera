import XCTest
@testable import CaptureCore

final class StabilizationInputTests: XCTestCase {
    func testClockRateUsesRecordedPairsAndKeepsPreroll() throws {
        let host = (0..<90).map { 5000.0+Double($0)/30 }
        let video = host.map { ($0-5000)*1.000031 }
        let map = try RecordedClockMap(host:host,video:video)
        XCTAssertEqual(map.slope,1.000031,accuracy:1e-10)
        XCTAssertEqual(map.videoSeconds(for:4999.5),-0.5000155,accuracy:1e-9)
        XCTAssertLessThan(map.maxResidual,1e-10)
    }
    func testRejectsBrokenClockMapping() {
        XCTAssertThrowsError(try RecordedClockMap(host:[1,1],video:[0,1]))
        XCTAssertThrowsError(try RecordedClockMap(host:[1,2,3],video:[0,1.05,2]))
        XCTAssertThrowsError(try RecordedClockMap(host:[1,2,3],video:[0,2,4]))
    }
}
