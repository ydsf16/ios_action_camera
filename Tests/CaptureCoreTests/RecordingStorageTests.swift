import XCTest
@testable import CaptureCore

final class RecordingStorageTests: XCTestCase {
    func testDeleteWholePackagePreservesOtherClipsAndExternalCopy() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Recordings", isDirectory: true)
        let first = try makeClip(root: root, name: "first", date: Date(timeIntervalSince1970: 200))
        let second = try makeClip(root: root, name: "second", date: Date(timeIntervalSince1970: 100))
        let exported = base.appendingPathComponent("photo-library-copy.mov")
        try FileManager.default.copyItem(at: first.appendingPathComponent("video.mov"), to: exported)
        let clips = try RecordingStorage.load(root: root)
        XCTAssertEqual(clips.map(\.id), ["first", "second"])
        XCTAssertTrue(clips[0].canPlay)
        XCTAssertGreaterThan(clips[0].allocatedBytes, 0)
        let result = RecordingStorage.remove([first, first], root: root)
        XCTAssertEqual(result.removed, [first])
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.appendingPathComponent("gyro.csv").path))
        XCTAssertEqual(try Data(contentsOf: exported), Data(repeating: 7, count: 8192))
        XCTAssertTrue(RecordingStorage.remove([first], root: root).failures.isEmpty)
    }

    func testInvalidTargetsAndSymlinksCannotDeleteOutsidePackage() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Recordings", isDirectory: true)
        let clip = try makeClip(root: root, name: "clip", date: Date())
        let outside = base.appendingPathComponent("keep", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let marker = outside.appendingPathComponent("keep.txt")
        try Data("preserved".utf8).write(to: marker)
        let link = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let invalid = RecordingStorage.remove([root, outside, link, clip.appendingPathComponent("video.mov")], root: root)
        XCTAssertEqual(invalid.failures.count, 4)
        XCTAssertTrue(invalid.removed.isEmpty)
        // A symlink inside a selected package is unlinked, never followed to delete its target.
        try FileManager.default.createSymbolicLink(at: clip.appendingPathComponent("external"), withDestinationURL: outside)
        let partial = RecordingStorage.remove([clip, outside], root: root)
        XCTAssertEqual(partial.removed, [clip])
        XCTAssertEqual(partial.failures.count, 1)
        XCTAssertEqual(try String(contentsOf: marker), "preserved")
    }

    func testInterruptedRecordingRemainsVisibleButCannotPlay() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let clip = try makeClip(root: base, name: "unfinished", date: Date())
        var manifest = try RecordingManifest.read(from: clip.appendingPathComponent("manifest.json"))
        manifest.status = "recording"
        manifest.id = "legacy-id"
        try manifest.write(to: clip.appendingPathComponent("manifest.json"))
        let clips = try RecordingStorage.load(root: base)
        XCTAssertEqual(clips.count, 1)
        XCTAssertEqual(clips[0].id, "unfinished")
        XCTAssertFalse(clips[0].canPlay)
        XCTAssertTrue(RecordingStorage.remove([clip], root: base).failures.isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func makeClip(root: URL, name: String, date: Date) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var manifest = RecordingManifest(id: name, createdAt: date, appVersion: "test", deviceModel: "test", systemVersion: "test",
            camera: "wide", width: 1920, height: 1080, stabilizationActive: 0, intrinsicsDeliveryEnabled: true)
        manifest.status = "complete"
        try manifest.write(to: url.appendingPathComponent("manifest.json"))
        for file in ["video.mov", "stabilized.mov", "gyro.csv", "stabilized-test.partial.mov"] {
            try Data(repeating: 7, count: 8192).write(to: url.appendingPathComponent(file))
        }
        return url
    }
}
