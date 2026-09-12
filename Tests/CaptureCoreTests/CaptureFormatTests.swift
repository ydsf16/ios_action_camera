import XCTest
@testable import CaptureCore

final class CaptureFormatTests: XCTestCase {
    func testLensFallbackPreservesFPSBeforeResolution() {
        let desired = CaptureFormat(resolution: .uhd4K, fps: 60)
        let supported = [CaptureFormat(resolution: .uhd4K, fps: 30), CaptureFormat(resolution: .fullHD, fps: 60)]
        XCTAssertEqual(desired.resolved(in: supported), supported[1])
        XCTAssertEqual(desired.resolved(in: supported + [desired]), desired)
        XCTAssertNil(desired.resolved(in: []))
    }

    func testExplicitResolutionChangeStaysAtRequestedResolution() {
        let desired = CaptureFormat(resolution: .uhd4K, fps: 60)
        let supported = [CaptureFormat(resolution: .uhd4K, fps: 24), CaptureFormat(resolution: .uhd4K, fps: 30)]
        XCTAssertEqual(desired.resolved(in: supported), supported[1])
    }

    func testSavedFormatAndInvalidPreferences() {
        let suite = "CaptureFormatTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(CaptureFormat.load(defaults: defaults), .standard)
        let selection = CaptureFormat(resolution: .fullHD, fps: 24)
        selection.save(defaults: defaults)
        XCTAssertEqual(CaptureFormat.load(defaults: defaults), selection)
        defaults.set(0, forKey: "captureFPS")
        XCTAssertEqual(CaptureFormat.load(defaults: defaults), .standard)
        defaults.set(60, forKey: "captureFPS")
        defaults.set("hd720", forKey: "captureResolution")
        XCTAssertEqual(CaptureFormat.load(defaults: defaults), CaptureFormat(resolution: .fullHD, fps: 60))
        defaults.set("unsupported", forKey: "captureResolution")
        XCTAssertEqual(CaptureFormat.load(defaults: defaults), .standard)
    }
}
