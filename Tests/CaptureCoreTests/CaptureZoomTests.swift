import XCTest
@testable import CaptureCore

final class CaptureZoomTests: XCTestCase {
    func testDualWideDisplayScaleAndHardwareBounds() {
        let zoom = CaptureZoom(multiplier: 0.5, minimumDeviceZoom: 1, maximumDeviceZoom: 20, nativeDeviceZooms: [1, 2])
        XCTAssertEqual(zoom.minimum, 0.5)
        XCTAssertEqual(zoom.maximum, 10)
        XCTAssertEqual(zoom.deviceZoom(for: 1), 2)
        XCTAssertEqual(zoom.deviceZoom(for: 0), 1)
        XCTAssertEqual(zoom.deviceZoom(for: 100), 20)
        XCTAssertEqual(zoom.stops, [0.5, 1, 2])
    }
    func testRestrictedRangeAndLogarithmicSlider() {
        let zoom = CaptureZoom(multiplier: 0.5, minimumDeviceZoom: 2, maximumDeviceZoom: 8, nativeDeviceZooms: [1, 2, 6])
        XCTAssertEqual(zoom.stops, [1, 2, 3])
        XCTAssertEqual(zoom.zoom(at: 0.5), 2, accuracy: 1e-10)
        XCTAssertEqual(zoom.position(for: 2), 0.5, accuracy: 1e-10)
        XCTAssertEqual(zoom.deviceZoom(for: .nan), 2)
        XCTAssertEqual(zoom.displayZoom(for: .infinity), 1)
    }
    func testTenTimesLimitDoesNotExceedHardware() {
        let tele = CaptureZoom(multiplier: 3, minimumDeviceZoom: 1, maximumDeviceZoom: 8, nativeDeviceZooms: [1])
        XCTAssertEqual(tele.maximum, 10)
        XCTAssertEqual(tele.deviceZoom(for: 10), 10.0 / 3, accuracy: 1e-10)
        let limited = CaptureZoom(multiplier: 1, minimumDeviceZoom: 1, maximumDeviceZoom: 6, nativeDeviceZooms: [])
        XCTAssertEqual(limited.maximum, 6)
        XCTAssertEqual(limited.deviceZoom(for: 10), 6)
    }
    func testInitialZoomPrefersUltraWideThenWide() {
        XCTAssertEqual(CaptureZoom(multiplier: 0.5, minimumDeviceZoom: 1, maximumDeviceZoom: 20, nativeDeviceZooms: []).initialZoom, 0.5)
        XCTAssertEqual(CaptureZoom(multiplier: 1, minimumDeviceZoom: 1, maximumDeviceZoom: 10, nativeDeviceZooms: []).initialZoom, 1)
        XCTAssertEqual(CaptureZoom(multiplier: 0.5, minimumDeviceZoom: 2, maximumDeviceZoom: 20, nativeDeviceZooms: []).initialZoom, 1)
    }
    func testFixedRangeHasNoInvalidSliderMath() {
        let zoom = CaptureZoom(multiplier: 1, minimumDeviceZoom: 1, maximumDeviceZoom: 1, nativeDeviceZooms: [])
        XCTAssertEqual(zoom.zoom(at: 0.5), 1)
        XCTAssertEqual(zoom.position(for: 1), 0)
    }
}
