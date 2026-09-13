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

    func testNewFormatsKeepFrameRateNativeIntrinsicsAndTimestampGaps() throws {
        for resolution in CaptureResolution.allCases {
            for fps in [24, 60] {
                let directory = try fixture(resolution: resolution, fps: fps)
                defer { try? FileManager.default.removeItem(at: directory) }
                let input = try StabilizationInput.load(directory: directory)
                XCTAssertEqual(input.fps, Double(fps))
                XCTAssertEqual(input.width, resolution.width)
                XCTAssertEqual(input.output_width, min(resolution.width, 2816))
                XCTAssertEqual(input.output_height, min(resolution.height, 1584))
                XCTAssertEqual(input.frames.count, 4)
                XCTAssertEqual(input.frames[2].timestamp_us, Int64((3_000_000.0 / Double(fps)).rounded()))
                XCTAssertEqual(input.frames[0].k[2], Double(resolution.width) / 2)
                XCTAssertLessThan(input.gyro[0].timestamp_ms, 0)
            }
        }
    }

    func testRejectsInvalidNominalFPS() throws {
        let directory = try fixture(resolution: .fullHD, fps: 24)
        defer { try? FileManager.default.removeItem(at: directory) }
        var manifest = try RecordingManifest.read(from: directory.appendingPathComponent("manifest.json"))
        manifest.requestedFPS = 0
        try manifest.write(to: directory.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try StabilizationInput.load(directory: directory))
    }

    func testExportResolutionCapsAtSourceAndOldSettingsKeepTheirChoices() throws {
        let old = Data("{\"strength\":0.9,\"maxCrop\":3.5,\"dynamicCrop\":false,\"allowBlackBorders\":true}".utf8)
        var options = try JSONDecoder().decode(StabilizationOptions.self, from: old)
        XCTAssertEqual(options.strength, 0.9)
        XCTAssertEqual(options.maxCrop, 3.5)
        XCTAssertFalse(options.dynamicCrop)
        XCTAssertTrue(options.allowBlackBorders)
        XCTAssertEqual(options.exportResolution, .fullHD)
        options.exportResolution = .action2_8K
        XCTAssertEqual(try JSONDecoder().decode(StabilizationOptions.self, from: JSONEncoder().encode(options)), options)
        for resolution in CaptureResolution.allCases {
            let directory = try fixture(resolution: resolution, fps: 60)
            defer { try? FileManager.default.removeItem(at: directory) }
            let input = try StabilizationInput.load(directory: directory, options: options)
            XCTAssertEqual(input.output_width, resolution == .uhd4K ? 2816 : 1920)
            XCTAssertEqual(input.output_height, resolution == .uhd4K ? 1584 : 1080)
            XCTAssertEqual(input.fps, 60)
        }
    }

    private func fixture(resolution: CaptureResolution, fps: Int) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var manifest = RecordingManifest(id: "test", createdAt: Date(), appVersion: "0.5.0", deviceModel: "fixture",
            systemVersion: "17", camera: "wide", width: resolution.width, height: resolution.height,
            stabilizationActive: 0, intrinsicsDeliveryEnabled: true)
        manifest.requestedFPS = fps; manifest.status = "complete"; manifest.videoFrames = 4
        manifest.durationSeconds = 5.0 / Double(fps)
        try manifest.write(to: directory.appendingPathComponent("manifest.json"))
        let header = "pts_value,pts_timescale,host_sec,video_sec,k00,k01,k02,k10,k11,k12,k20,k21,k22,stabilization_active"
        let rows = [0, 1, 3, 4].map { frame in
            let time = Double(frame) / Double(fps)
            return "\(1000 * fps + frame),\(fps),\(1000 + time),\(time),1000,0,\(Double(resolution.width)/2),0,1000,\(Double(resolution.height)/2),0,0,1,0"
        }
        try ([header] + rows).joined(separator: "\n").write(to: directory.appendingPathComponent("frames.csv"), atomically: true, encoding: .utf8)
        let motion = (-10...30).map { "\(1000 + Double($0)/100),0,0,0" }
        try (["host_sec,gx_rad_s,gy_rad_s,gz_rad_s"] + motion).joined(separator: "\n").write(to: directory.appendingPathComponent("gyro.csv"), atomically: true, encoding: .utf8)
        return directory
    }
}
