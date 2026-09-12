// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct StabilizationInput: Codable {
    public struct Frame: Codable { public let timestamp_us: Int64; public let k: [Double] }
    public struct Gyro: Codable { public let timestamp_ms: Double; public let gyro: [Double] }
    public let width: Int
    public let height: Int
    public let output_width: Int
    public let output_height: Int
    public let duration_ms: Double
    public let fps: Double
    public let frames: [Frame]
    public let gyro: [Gyro]

    public static func load(directory: URL) throws -> Self {
        let manifest = try RecordingManifest.read(from: directory.appendingPathComponent("manifest.json"))
        guard manifest.status == "complete", manifest.videoFrames > 1,
              manifest.pixelBufferRotationDegrees == 0, !manifest.mirrored else {
            throw InputError("素材未完成，或像素方向不受支持。")
        }
        let table = try NumericCSV(directory.appendingPathComponent("frames.csv"))
        let host = try table.column("host_sec")
        let video = try table.column("video_sec")
        guard host.count == manifest.videoFrames, increasing(host), increasing(video), abs(video[0]) < 0.000005 else {
            throw InputError("视频时间轴或帧数不匹配。")
        }
        let sourceTimes = try zip(table.column("pts_value"),table.column("pts_timescale")).map { value, scale -> Double in
            guard scale > 0 else { throw InputError("视频 PTS 无效。") }; return value / scale
        }
        guard zip(sourceTimes,video).allSatisfy({ abs(($0.0-sourceTimes[0])-$0.1) < 0.000005 }),
              try table.column("stabilization_active").allSatisfy({ $0 == 0 }) else {
            throw InputError("视频时间原点不一致，或录制时系统防抖未关闭。")
        }
        let map = try RecordedClockMap(host: host, video: video)
        var matrices = [[Double]](repeating: [], count: host.count)
        for row in 0..<3 { for col in 0..<3 {
            let values = try table.column("k\(row)\(col)")
            for index in values.indices { matrices[index].append(values[index]) }
        }}
        guard matrices.allSatisfy({ $0[0] > 0 && $0[4] > 0 }) else { throw InputError("素材缺少有效相机内参。") }
        let motion = try NumericCSV(directory.appendingPathComponent("gyro.csv"))
        let times = try motion.column("host_sec")
        guard times.count > 2, increasing(times), times[0] <= host[0], times.last! >= host.last! else {
            throw InputError("IMU 时间范围没有完整覆盖视频。")
        }
        guard zip(times,times.dropFirst()).allSatisfy({ $0.1-$0.0 < 0.1 }) else { throw InputError("IMU 有较大的采样缺口。") }
        let gx = try motion.column("gx_rad_s"), gy = try motion.column("gy_rad_s"), gz = try motion.column("gz_rad_s")
        let width = manifest.width, height = manifest.height
        guard width >= 1920, width <= 4096, height > 0, height <= 4096 else { throw InputError("录制尺寸暂不支持。") }
        let outWidth = 1920, outHeight = Int((Double(height) * 1920 / Double(width) / 2).rounded()) * 2
        return Self(width: width, height: height, output_width: outWidth, output_height: outHeight,
            duration_ms: manifest.durationSeconds * 1000, fps: Double(manifest.requestedFPS),
            frames: video.indices.map { Frame(timestamp_us: Int64((video[$0]*1e6).rounded()), k: matrices[$0]) },
            gyro: times.indices.map { Gyro(timestamp_ms: map.videoSeconds(for: times[$0])*1000, gyro: [gx[$0],gy[$0],gz[$0]]) })
    }
    private static func increasing(_ values: [Double]) -> Bool {
        !values.isEmpty && zip(values,values.dropFirst()).allSatisfy { $0.1 > $0.0 }
    }
}

public struct InputError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Least-squares fit of recorded clock pairs. No visually estimated offset is added.
public struct RecordedClockMap {
    public let origin: Double
    public let slope: Double
    public let intercept: Double
    public let maxResidual: Double
    public init(host: [Double], video: [Double]) throws {
        guard host.count == video.count, host.count >= 2,
              (host + video).allSatisfy(\.isFinite),
              zip(host,host.dropFirst()).allSatisfy({ $0.1 > $0.0 }) else { throw InputError("时钟对应数据无效。") }
        origin = host[0]
        let x = host.map { $0-host[0] }
        let mx = x.reduce(0,+)/Double(x.count), my = video.reduce(0,+)/Double(video.count)
        let denominator = x.reduce(0) { $0 + pow($1-mx,2) }
        guard denominator > 0 else { throw InputError("时钟对应数据长度不足。") }
        slope = zip(x,video).reduce(0) { $0+($1.0-mx)*($1.1-my) } / denominator
        intercept = my-slope*mx
        let a = slope, b = intercept
        maxResidual = zip(x,video).map { abs($0.1-(a*$0.0+b)) }.max()!
        guard (0.999...1.001).contains(slope), maxResidual <= 0.001 else { throw InputError("录制时钟映射异常，请保留素材检查。") }
    }
    public func videoSeconds(for host: Double) -> Double { (host-origin)*slope+intercept }
}

private struct NumericCSV {
    let names: [String]
    let rows: [[String]]
    init(_ url: URL) throws {
        let lines = try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("#") }
        guard let header = lines.first else { throw InputError("数据文件为空：\(url.lastPathComponent)") }
        names = header.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        rows = lines.dropFirst().map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
        guard rows.allSatisfy({ $0.count == names.count }) else { throw InputError("CSV 列数不匹配。") }
    }
    func column(_ name: String) throws -> [Double] {
        guard let index = names.firstIndex(of: name) else { throw InputError("数据缺少 \(name)。") }
        return try rows.map { row in
            guard let value = Double(row[index]), value.isFinite else { throw InputError("\(name) 中有无效数据。") }
            return value
        }
    }
}
