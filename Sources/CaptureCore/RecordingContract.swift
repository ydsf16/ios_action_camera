import Foundation

public struct MediaTime: Codable, Equatable {
    public let value: Int64
    public let timescale: Int32
    public var seconds: Double { Double(value) / Double(timescale) }
    public init(value: Int64, timescale: Int32) {
        self.value = value
        self.timescale = timescale
    }
}

/// Keep the source PTS origin; never independently zero the IMU stream.
public struct VideoTimeline {
    public private(set) var firstPTS: MediaTime?
    public private(set) var lastSeconds: Double?

    public init() {}

    public mutating func accept(_ pts: MediaTime) throws -> Double {
        guard pts.timescale > 0, pts.seconds.isFinite else { throw ContractError.invalidTime }
        if let lastSeconds, pts.seconds <= lastSeconds { throw ContractError.nonMonotonicTime }
        if firstPTS == nil { firstPTS = pts }
        lastSeconds = pts.seconds
        return pts.seconds - firstPTS!.seconds
    }
}

public enum ContractError: Error {
    case invalidTime, nonMonotonicTime
}

public struct RecordingManifest: Codable {
    public var schemaVersion = 1
    public var id: String
    public var createdAt: Date
    public var status = "recording"
    public var appVersion: String
    public var appBuild: String?
    public var deviceModel: String
    public var systemVersion: String
    public var camera: String
    public var width: Int
    public var height: Int
    public var requestedFPS = 30
    public var displayRotationDegrees = 90
    public var pixelBufferRotationDegrees = 0
    public var mirrored = false
    public var videoCodec = "h264"
    public var audioCodec = "aac"
    public var stabilizationRequested = "off"
    public var stabilizationActive: Int
    public var intrinsicsDeliveryEnabled: Bool
    public var firstVideoPTS: MediaTime?
    public var firstVideoHostSeconds: Double?
    public var durationSeconds = 0.0
    public var videoFrames = 0
    public var framesWithIntrinsics = 0
    public var droppedVideoFrames = 0
    public var audioBuffers = 0
    public var droppedAudioBuffers = 0
    public var gyroSamples = 0
    public var accelerometerSamples = 0
    public var gravitySamples = 0
    public var stopReason: String?
    public var error: String?
    public var clockMapping = "host_sec = CMSyncConvertTime(source_pts, session.synchronizationClock, CMClockGetHostTimeClock()); video_sec = source_pts - firstVideoPTS"
    public var motionClock = "CoreMotion seconds since boot; original timestamps, including preroll"
    public var axes = "Unmodified CoreMotion device axes: x right, y top, z out of screen in portrait. No sign changes. Intrinsics refer to unrotated encoded pixel buffer."
    public var accelerationUnit = "g (includes gravity); gravity.csv is CoreMotion gravity in g"
    public var angularVelocityUnit = "rad/s"
    public var gravityReferenceFrame = "xArbitraryZVertical"
    // Optional fields preserve decoding of existing recording packages.
    public var exposurePolicy: String?
    public var captureBufferStrategy: String?
    public var maximumAutoExposureSeconds: Double?
    public var continuousAutoFocusEnabled: Bool?
    public var systemTimestampSynchronizationEnabled: Bool?
    public var hardwareTriggeredSynchronizationEnabled: Bool?
    public var exposureSource = "AVCaptureDevice property sampled at callback; not guaranteed frame-exact"
    public var rollingShutterReadoutMS: Double?
    public var warnings: [String] = []

    public init(id: String, createdAt: Date, appVersion: String, deviceModel: String,
                systemVersion: String, camera: String, width: Int, height: Int,
                stabilizationActive: Int, intrinsicsDeliveryEnabled: Bool) {
        self.id = id; self.createdAt = createdAt; self.appVersion = appVersion
        self.deviceModel = deviceModel; self.systemVersion = systemVersion
        self.camera = camera; self.width = width; self.height = height
        self.stabilizationActive = stabilizationActive
        self.intrinsicsDeliveryEnabled = intrinsicsDeliveryEnabled
    }

    public static func read(from url: URL) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Self.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Bounded history supplies motion samples before the first video frame.
public struct SampleHistory {
    private var samples: [(time: Double, row: String)] = []
    public let capacity: Int
    public init(capacity: Int = 100) { self.capacity = max(1, capacity) }
    public mutating func append(time: Double, row: String) {
        guard time.isFinite else { return }
        samples.append((time, row))
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }
    public func rows(since cutoff: Double) -> [String] {
        samples.filter { $0.time >= cutoff }.map(\.row)
    }
    public mutating func clear() { samples.removeAll(keepingCapacity: true) }
}

/// A failed flush propagates to the recording instead of silently losing telemetry.
public final class CSVFile {
    private let handle: FileHandle
    private var buffer = Data()
    private var closed = false
    public init(url: URL, header: String) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data((header + "\n").utf8))
    }
    public func append(_ row: String) throws {
        guard !closed else { throw CocoaError(.fileWriteUnknown) }
        buffer.append(contentsOf: (row + "\n").utf8)
        if buffer.count >= 32_768 { try flush() }
    }
    public func flush() throws {
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        }
    }
    public func close() throws {
        guard !closed else { return }
        try flush(); try handle.synchronize(); try handle.close()
        closed = true
    }
    deinit { try? handle.close() }
}
