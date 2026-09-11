import XCTest
@testable import CaptureCore

final class RecordingContractTests: XCTestCase {
    func testVideoOriginAndDroppedFrameGapArePreserved() throws {
        var timeline = VideoTimeline()
        XCTAssertEqual(try timeline.accept(.init(value: 6_000_000, timescale: 600)), 0)
        XCTAssertEqual(try timeline.accept(.init(value: 6_000_040, timescale: 600)), 2.0 / 30, accuracy: 1e-9)
        XCTAssertEqual(timeline.firstPTS, .init(value: 6_000_000, timescale: 600))
    }

    func testRejectsInvalidAndReorderedTimestamps() throws {
        var timeline = VideoTimeline()
        XCTAssertThrowsError(try timeline.accept(.init(value: 1, timescale: 0)))
        _ = try timeline.accept(.init(value: 100, timescale: 10))
        XCTAssertThrowsError(try timeline.accept(.init(value: 100, timescale: 10)))
        XCTAssertThrowsError(try timeline.accept(.init(value: 99, timescale: 10)))
        XCTAssertEqual(try timeline.accept(.init(value: 102, timescale: 10)), 0.2, accuracy: 1e-9)
    }

    func testMotionPrerollKeepsOriginalTimestampAndBoundedMemory() {
        var history = SampleHistory(capacity: 3)
        for n in 0..<5 { history.append(time: 100 + Double(n) / 100, row: "sample\(n)") }
        XCTAssertEqual(history.rows(since: 99), ["sample2", "sample3", "sample4"])
        XCTAssertEqual(history.rows(since: 100.035), ["sample4"])
        history.clear()
        XCTAssertTrue(history.rows(since: 0).isEmpty)
    }

    func testManifestPreservesClockPairAndCSVFlushesTail() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var manifest = RecordingManifest(id: "test", createdAt: Date(), appVersion: "0.1.0",
            deviceModel: "test", systemVersion: "17", camera: "wide", width: 3840, height: 2160,
            stabilizationActive: 0, intrinsicsDeliveryEnabled: true)
        manifest.firstVideoPTS = .init(value: 123456789, timescale: 1_000_000)
        manifest.firstVideoHostSeconds = 789.012345678
        try manifest.write(to: dir.appendingPathComponent("manifest.json"))
        let copy = try RecordingManifest.read(from: dir.appendingPathComponent("manifest.json"))
        XCTAssertEqual(copy.firstVideoPTS, manifest.firstVideoPTS)
        XCTAssertEqual(copy.firstVideoHostSeconds, manifest.firstVideoHostSeconds)
        XCTAssertNil(copy.rollingShutterReadoutMS)
        let file = try CSVFile(url: dir.appendingPathComponent("gyro.csv"), header: "host_sec,gx,gy,gz")
        try file.append("789.000,1,2,3")
        try file.close()
        XCTAssertThrowsError(try file.append("790,4,5,6"))
        XCTAssertNoThrow(try file.close())
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("gyro.csv")), "host_sec,gx,gy,gz\n789.000,1,2,3\n")
    }
}
