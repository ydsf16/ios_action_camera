import XCTest
@testable import CaptureCore

final class CaptureExposurePolicyTests: XCTestCase {
    func testNewInstallDefaultsToTwoMillisecondsAndPreservesSelection() {
        let suite = "CaptureExposurePolicyTests.\(UUID().uuidString)"
        guard let storage = UserDefaults(suiteName: suite) else {
            return XCTFail("Unable to create isolated defaults")
        }
        defer { storage.removePersistentDomain(forName: suite) }

        XCTAssertEqual(CaptureExposurePolicy.load(storage: storage), .fastMotion)
        CaptureExposurePolicy.motion.save(storage: storage)
        XCTAssertEqual(CaptureExposurePolicy.load(storage: storage), .motion)
    }
}
