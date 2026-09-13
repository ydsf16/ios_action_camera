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
            XCTAssertFalse(value.automaticAdjustment)
            XCTAssertNil(value.preset)
            let encoded = try JSONEncoder().encode(value)
            XCTAssertEqual(try JSONDecoder().decode(StabilizationOptions.self, from: encoded), value)
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertNotNil(fields["smoothingSeconds"])
            XCTAssertNil(fields["strength"])
        }
        let bad = Data("{\"strength\":1.1,\"maxCrop\":2,\"dynamicCrop\":true,\"allowBlackBorders\":false}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(StabilizationOptions.self, from: bad))
    }

    func testPresetsResetOnlyStabilizationAndPreserveHorizonAndExportChoice() throws {
        var value = StabilizationOptions()
        XCTAssertEqual(value.preset, .standard)
        value.horizonLock = true; value.exportResolution = .fullHD
        value.allowBlackBorders = true; value.dynamicCrop = false; value.automaticAdjustment = false
        for preset in StabilizationPreset.allCases {
            value.applyPreset(preset)
            XCTAssertEqual(value.preset, preset)
            XCTAssertTrue(value.automaticAdjustment)
            XCTAssertTrue(value.horizonLock)
            XCTAssertEqual(value.exportResolution, .fullHD)
            XCTAssertEqual(try JSONDecoder().decode(StabilizationOptions.self, from: JSONEncoder().encode(value)), value)
        }
        XCTAssertEqual(value.recommended().preset, .standard)
        value.automaticAdjustment = false
        XCTAssertNil(value.preset)
    }

    func testOutputDefaultUpgradePreservesEffectAndSubsequentSizeChoices() throws {
        let suite = "RoamShot-output-default-test-" + UUID().uuidString
        let storage = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { storage.removePersistentDomain(forName: suite) }
        var previous = StabilizationOptions()
        previous.exportResolution = .fullHD
        previous.applyPreset(.strong)
        previous.horizonLock = true
        let previousData = try JSONEncoder().encode(previous)
        storage.set(previousData, forKey: "stabilizationDefaults")
        CaptureFormat.standard.save(defaults: storage)

        let migrated = StabilizationOptions.defaults(storage: storage)
        var expected = previous
        expected.exportResolution = .action2_8K
        XCTAssertEqual(migrated, expected)
        XCTAssertEqual(CaptureFormat.load(defaults: storage), CaptureFormat(resolution: .uhd4K, fps: 60))
        // Existing clips/receipts still decode their actual original output choice.
        XCTAssertEqual(try JSONDecoder().decode(StabilizationOptions.self, from: previousData), previous)
        XCTAssertEqual(StabilizationOptions.defaults(storage: storage), expected)

        try previous.saveDefaults(storage: storage)
        XCTAssertEqual(StabilizationOptions.defaults(storage: storage), previous)
    }

    func testAdaptationReportsHorizonReductionAndNeverLabelsZeroCorrectionAsStable() throws {
        let report = StabilizationReport(requestedSmoothingSeconds: 3, effectiveSmoothingSeconds: 0,
            minimumCrop: 1, maximumCrop: 2, requestedHorizonPercent: 100, effectiveHorizonPercent: 0)
        XCTAssertTrue(report.horizonReduced)
        XCTAssertTrue(report.unstabilizedFallback)
        XCTAssertTrue(report.summary.contains("仅调整画幅"))
        XCTAssertTrue(report.details.contains("未能提供稳定效果"))
        let old = Data("{\"requestedSmoothingSeconds\":0.8,\"effectiveSmoothingSeconds\":0.8,\"minimumCrop\":1,\"maximumCrop\":2}".utf8)
        let legacy = try JSONDecoder().decode(StabilizationReport.self, from: old)
        XCTAssertFalse(legacy.horizonReduced)
        XCTAssertFalse(legacy.unstabilizedFallback)
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
