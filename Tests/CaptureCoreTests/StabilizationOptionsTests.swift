import XCTest
@testable import CaptureCore

final class StabilizationOptionsTests: XCTestCase {
    func testLegacyMigrationPreservesActualSmoothingIncludingOldZero() throws {
        for legacy in [0.0, 0.5, 0.9, 1.0] {
            let json = "{\"strength\":\(legacy),\"maxCrop\":3.5,\"dynamicCrop\":true,\"allowBlackBorders\":true}"
            let value = try JSONDecoder().decode(StabilizationOptions.self, from: Data(json.utf8))
            XCTAssertEqual(value.smoothingSeconds, 0.16 * pow(25, legacy), accuracy: 1e-12)
            XCTAssertEqual(value.zoomTransitionSeconds, 2)
            XCTAssertFalse(value.horizonLock)
            let encoded = try JSONEncoder().encode(value)
            XCTAssertEqual(try JSONDecoder().decode(StabilizationOptions.self, from: encoded), value)
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertNotNil(fields["smoothingSeconds"])
            XCTAssertNil(fields["strength"])
        }
        let bad = Data("{\"strength\":1.1,\"maxCrop\":2,\"dynamicCrop\":true,\"allowBlackBorders\":false}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(StabilizationOptions.self, from: bad))
    }

    func testOffAndExtendedStrengthSurvivePersistence() throws {
        var value = StabilizationOptions()
        value.horizonLock = true
        for (position, seconds) in [(0.0, 0.0), (1.0, 10.0)] {
            value.strength = position
            XCTAssertTrue(value.isValid)
            XCTAssertEqual(value.smoothingSeconds, seconds, accuracy: 1e-12)
            XCTAssertEqual(try JSONDecoder().decode(StabilizationOptions.self, from: JSONEncoder().encode(value)), value)
        }
        value.smoothingSeconds = 10.1
        XCTAssertFalse(value.isValid)
        value.smoothingSeconds = 0.8; value.zoomTransitionSeconds = 0
        XCTAssertFalse(value.isValid)
    }

    func testMissingOrOldExportDiagnosticsAreNotPresentedAsAnUnrestrictedResult() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("stabilized.mov"))
        let options = StabilizationOptions()
        let old = ["options": try JSONSerialization.jsonObject(with: JSONEncoder().encode(options))]
        try JSONSerialization.data(withJSONObject: old).write(to: directory.appendingPathComponent("stabilization.json"))
        XCTAssertNil(StabilizationReport.load(directory: directory))
        let report = StabilizationReport(requestedSmoothingSeconds: 0.8, effectiveSmoothingSeconds: 0.4, minimumCrop: 1.2, maximumCrop: 2)
        let new = old.merging(["stabilization": try JSONSerialization.jsonObject(with: JSONEncoder().encode(report))]) { _, new in new }
        try JSONSerialization.data(withJSONObject: new).write(to: directory.appendingPathComponent("stabilization.json"))
        XCTAssertEqual(StabilizationReport.load(directory: directory)?.stabilization, report)
        XCTAssertTrue(try XCTUnwrap(StabilizationReport.load(directory: directory)).stabilization.cropLimited)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("stabilized.mov"))
        XCTAssertNil(StabilizationReport.load(directory: directory))
    }
}
