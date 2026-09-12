import XCTest
@testable import CaptureCore

final class CaptureZoomTests: XCTestCase {
    func testDualWideDisplayScaleAndHardwareBounds() {
        let zoom = CaptureZoom(multiplier: 0.5, minimumDeviceZoom: 1, maximumDeviceZoom: 20, nativeDeviceZooms: [1, 2])
        XCTAssertEqual(zoom.minimum, 0.5)
        XCTAssertEqual(zoom.maximum, 5)
        XCTAssertEqual(zoom.deviceZoom(for: 1), 2)
        XCTAssertEqual(zoom.deviceZoom(for: 0), 1)
        XCTAssertEqual(zoom.deviceZoom(for: 100), 10)
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
    func testFixedRangeHasNoInvalidSliderMath() {
        let zoom = CaptureZoom(multiplier: 1, minimumDeviceZoom: 1, maximumDeviceZoom: 1, nativeDeviceZooms: [])
        XCTAssertEqual(zoom.zoom(at: 0.5), 1)
        XCTAssertEqual(zoom.position(for: 1), 0)
    }
}
