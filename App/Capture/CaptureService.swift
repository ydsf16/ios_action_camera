import AVFoundation
import CoreMotion
import Combine
import UIKit

enum CameraPhase: Equatable {
    case preparing, ready, recording, finishing, unavailable
}

struct CameraLens: Identifiable, Equatable {
    let id: String
    let label: String
    let type: AVCaptureDevice.DeviceType
}

/// Session configuration, delegates, writer and motion state are confined to `queue`.
/// Published UI state and the UIKit background-task token are mutated only on main.
/// This explicit queue confinement is the basis of the unchecked Sendable conformance.
final class CaptureService: NSObject, ObservableObject, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate,
                            AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    @Published private(set) var phase: CameraPhase = .preparing
    @Published private(set) var lenses: [CameraLens] = []
    @Published private(set) var selectedLens = ""
    @Published private(set) var exposurePolicy = CaptureExposurePolicy.load()
    private var activeExposurePolicy = CaptureExposurePolicy.load()
    @Published private(set) var focusLabel = "准备中"
    @Published private(set) var formatLabel = "4K · 30"
    @Published private(set) var duration = 0.0
    @Published private(set) var latestDirectory: URL?
    @Published var message: String?
    @Published private(set) var permissionDenied = false

    private let queue = DispatchQueue(label: "com.grape.MotionCam.capture", qos: .userInitiated)
    private let motion = CMMotionManager()
    private lazy var motionQueue: OperationQueue = {
        let value = OperationQueue()
        value.maxConcurrentOperationCount = 1
        value.underlyingQueue = queue
        return value
    }()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var cameraInput: AVCaptureDeviceInput?
    private var recorder: RecordingWriter?
    private var isFinishing = false
    private var acceptsMotion = false
    private var configured = false
    private var wantsActive = false
    private var recordingRotationDegrees = 90
    func setRecordingRotation(_ degrees: Int) {
        guard [0, 90, 180, 270].contains(degrees) else { return }
        queue.async { self.recordingRotationDegrees = degrees }
    }
    private var histories = ["gyro": SampleHistory(), "accelerometer": SampleHistory(), "gravity": SampleHistory()]
    private var latestMotionTime: [String: Double] = [:]
    private var observers: [NSObjectProtocol] = []
    private var startTimeout: DispatchWorkItem?
    private var lastUIPublish = 0.0
    private var lastDiskCheck = 0.0
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid // main queue only

    static var recordingsRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in
                self?.stopOnQueue(reason: "capture_interruption")
                self?.publish { $0.message = "相机被中断，当前片段已结束。"; $0.phase = .unavailable }
            }
        })
        observers.append(center.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in self?.resumeIfPossible() }
        })
        observers.append(center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.queue.async { [weak self] in
                self?.fail(error ?? CaptureFailure.message("相机发生错误，请重新进入应用。"))
            }
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func prepare() async {
        let videoAllowed = await Self.permission(.video)
        let audioAllowed = await Self.permission(.audio)
        guard videoAllowed, audioAllowed else {
            publish {
                $0.permissionDenied = true; $0.phase = .unavailable
                $0.message = "请在设置中允许访问相机和麦克风，才能录制带声音的视频。"
            }
            return
        }
        queue.async { [self] in
            do {
                if !configured { try configure() }
                // prepare() may finish after the app has already entered the background.
                if wantsActive { resumeIfPossible() }
            } catch { fail(error) }
        }
    }

    private static func permission(_ media: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: media)
        default: return false
        }
    }

    func setActive(_ active: Bool) {
        if !active { beginFinishingTask() }
        queue.async { [self] in
            wantsActive = active
            if active { resumeIfPossible() }
            else {
                stopOnQueue(reason: "app_background")
                if session.isRunning { session.stopRunning() }
                if recorder == nil { stopMotion(); endFinishingTask() }
            }
        }
    }

    private func configure() throws {
        #if targetEnvironment(simulator)
        throw CaptureFailure.message("模拟器不支持真实相机和 IMU，请在 iPhone 上测试录制。")
        #else
        guard motion.isGyroAvailable, motion.isAccelerometerAvailable, motion.isDeviceMotionAvailable else {
            throw CaptureFailure.message("此设备缺少录制运动数据所需的传感器。")
        }
        let types: [(AVCaptureDevice.DeviceType, String)] = [(.builtInUltraWideCamera, "0.5×"), (.builtInWideAngleCamera, "1×")]
        let available = types.compactMap { type, label -> CameraLens? in
            guard AVCaptureDevice.default(type, for: .video, position: .back) != nil else { return nil }
            return CameraLens(id: type.rawValue, label: label, type: type)
        }
        guard let lens = available.first else { throw CaptureFailure.message("找不到后置相机。") }
        session.beginConfiguration()
        defer {
            if !configured {
                session.inputs.forEach(session.removeInput)
                session.outputs.forEach(session.removeOutput)
                cameraInput = nil
            }
            session.commitConfiguration()
        }
        session.sessionPreset = .inputPriority
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        audioOutput.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(videoOutput), session.canAddOutput(audioOutput) else { throw CaptureFailure.message("无法添加采集输出。") }
        session.addOutput(videoOutput); session.addOutput(audioOutput)
        guard let microphone = AVCaptureDevice.default(for: .audio) else { throw CaptureFailure.message("找不到麦克风。") }
        let microphoneInput = try AVCaptureDeviceInput(device: microphone)
        guard session.canAddInput(microphoneInput) else { throw CaptureFailure.message("无法启动麦克风。") }
        session.addInput(microphoneInput)
        try installCamera(lens)
        configured = true
        publish { $0.lenses = available; $0.permissionDenied = false }
        #endif
    }

    private func installCamera(_ lens: CameraLens) throws {
        guard let device = AVCaptureDevice.default(lens.type, for: .video, position: .back) else {
            throw CaptureFailure.message("此镜头不可用。")
        }
        let replacement = try AVCaptureDeviceInput(device: device)
        let previous = cameraInput
        if let previous { session.removeInput(previous) }
        do {
            guard session.canAddInput(replacement) else { throw CaptureFailure.message("无法切换镜头。") }
            session.addInput(replacement)
            try configureFormat(device)
            cameraInput = replacement
            guard let connection = videoOutput.connection(with: .video) else { throw CaptureFailure.message("视频连接不可用。") }
            connection.preferredVideoStabilizationMode = .off
            guard connection.isVideoRotationAngleSupported(0) else { throw CaptureFailure.message("无法保持相机原始像素方向。") }
            connection.videoRotationAngle = 0
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            if connection.isCameraIntrinsicMatrixDeliverySupported { connection.isCameraIntrinsicMatrixDeliveryEnabled = true }
            let size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            let focus = device.focusMode == .continuousAutoFocus ? "连续自动对焦" : "此镜头为固定对焦"
            publish { $0.focusLabel = focus; $0.selectedLens = lens.id; $0.formatLabel = size.width >= 3840 ? "4K · 30" : "1080p · 30" }
        } catch {
            if session.inputs.contains(replacement) { session.removeInput(replacement) }
            if let previous, session.canAddInput(previous) { session.addInput(previous) }
            cameraInput = previous
            throw error
        }
    }

    private func configureFormat(_ device: AVCaptureDevice) throws {
        var selected: AVCaptureDevice.Format?
        for width in [3840, 1920] {
            selected = device.formats.first { format in
                let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return size.width == width && size.height == (width == 3840 ? 2160 : 1080)
                    && CMFormatDescriptionGetMediaSubType(format.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                    && format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
            }
            if selected != nil { break }
        }
        guard let selected else { throw CaptureFailure.message("此镜头不支持所需的 30fps SDR 格式。") }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = selected
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        device.automaticallyAdjustsVideoHDREnabled = false
        if selected.isVideoHDRSupported { device.isVideoHDREnabled = false }
        device.videoZoomFactor = 1
        try applyRecordingControlsLocked(device)
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
    }

    /// Caller holds the device configuration lock. Reapply after format changes.
    private func applyRecordingControlsLocked(_ device: AVCaptureDevice, policy: CaptureExposurePolicy? = nil) throws {
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        guard device.isExposureModeSupported(.continuousAutoExposure) else {
            throw CaptureFailure.message("此镜头不支持所需的自动曝光。")
        }
        let selected = policy ?? activeExposurePolicy
        device.exposureMode = .continuousAutoExposure
        if let milliseconds = selected.maximumExposureMilliseconds {
            let limit = CMTime(value: milliseconds, timescale: 1000)
            guard CMTimeCompare(device.activeFormat.minExposureDuration, limit) <= 0 else {
                throw CaptureFailure.message("此格式无法将曝光时间限制到 \(milliseconds) ms。")
            }
            device.activeMaxExposureDuration = CMTimeMinimum(limit, device.activeFormat.maxExposureDuration)
        } else {
            // AVFoundation explicitly defines .invalid as restoring its per-format AE default.
            device.activeMaxExposureDuration = .invalid
        }
    }

    func selectExposurePolicy(_ policy: CaptureExposurePolicy) {
        queue.async { [self] in
            guard recorder == nil, !isFinishing, let device = cameraInput?.device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                try applyRecordingControlsLocked(device, policy: policy)
                activeExposurePolicy = policy
                policy.save()
                publish { $0.exposurePolicy = policy }
                queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.writeConfigurationReport() }
            } catch { publish { $0.message = error.localizedDescription } }
        }
    }

    func selectLens(_ lens: CameraLens) {
        queue.async { [self] in
            guard recorder == nil, !isFinishing, configured else { return }
            publish { $0.phase = .preparing }
            session.stopRunning()
            session.beginConfiguration()
            do {
                try installCamera(lens)
                session.commitConfiguration()
                resumeIfPossible()
            } catch {
                session.commitConfiguration()
                resumeIfPossible()
                publish { $0.message = error.localizedDescription }
            }
        }
    }

    private func resumeIfPossible() {
        guard configured, wantsActive, !isFinishing else { return }
        if !session.isRunning { session.startRunning() }
        guard session.isRunning, !session.isInterrupted else { publish { $0.phase = .unavailable }; return }
        startMotion()
        if recorder == nil {
            writeConfigurationReport()
            publish { $0.phase = .ready }
        }
    }

    private func writeConfigurationReport() {
        guard let device = cameraInput?.device else { return }
        let maximum = device.activeMaxExposureDuration.seconds
        let report: [String: Any] = ["focus_mode": device.focusMode.rawValue,
            "continuous_autofocus": device.focusMode == .continuousAutoFocus,
            "exposure_policy": activeExposurePolicy.rawValue, "exposure_mode": device.exposureMode.rawValue,
            "max_exposure_seconds": maximum.isFinite ? maximum as Any : NSNull(),
            "observed_exposure_seconds": device.exposureDuration.seconds,
            "observed_iso": device.iso,
            "system_clock_available": session.synchronizationClock != nil,
            "hardware_triggered_sync": false, "updated_at": ISO8601DateFormatter().string(from: Date())]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            let url = Self.recordingsRoot.deletingLastPathComponent().appendingPathComponent("capture-configuration.json")
            try? data.write(to: url, options: .atomic)
        }
    }

    func startRecording() {
        queue.async { [self] in
            guard wantsActive, session.isRunning, !session.isInterrupted, recorder == nil, !isFinishing,
                  let device = cameraInput?.device, let connection = videoOutput.connection(with: .video) else { return }
            do {
                guard ProcessInfo.processInfo.thermalState != .critical else { throw CaptureFailure.message("设备温度过高，请稍后再录制。") }
                try checkDisk(minimum: 500_000_000)
                let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                guard ["gyro", "accelerometer", "gravity"].allSatisfy({ now - (latestMotionTime[$0] ?? 0) < 0.5 }) else {
                    throw CaptureFailure.message("运动传感器正在准备，请稍后重试。")
                }
                guard session.synchronizationClock != nil else { throw CaptureFailure.message("采集时钟尚未就绪，请重试。") }
                guard connection.activeVideoStabilizationMode == .off else {
                    throw CaptureFailure.message("系统视频防抖尚未关闭，请重新进入相机。")
                }
                do {
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }
                    try applyRecordingControlsLocked(device)
                }
                let recording = try RecordingWriter(root: Self.recordingsRoot, device: device, connection: connection, rotationDegrees: recordingRotationDegrees, exposurePolicy: activeExposurePolicy.rawValue)
                recorder = recording
                acceptsMotion = true
                for kind in ["gyro", "accelerometer", "gravity"] {
                    for row in histories[kind]!.rows(since: now - 0.5) { try recording.appendMotion(kind, row: row) }
                }
                lastDiskCheck = now; lastUIPublish = 0
                publish { $0.duration = 0; $0.phase = .recording }
                let timeout = DispatchWorkItem { [weak self] in
                    guard let self, recorder?.manifest.videoFrames == 0 else { return }
                    fail(CaptureFailure.message("相机未输出视频帧，请重试。"))
                }
                startTimeout = timeout
                queue.asyncAfter(deadline: .now() + 4, execute: timeout)
            } catch { fail(error) }
        }
    }

    func stopRecording() { beginFinishingTask(); queue.async { [self] in stopOnQueue(reason: "user") } }

    private func stopOnQueue(reason: String) {
        guard let recording = recorder, !isFinishing else { if recorder == nil { endFinishingTask() }; return }
        isFinishing = true; startTimeout?.cancel(); startTimeout = nil
        publish { $0.phase = .finishing }
        // Keep a short IMU tail; no further video or audio is accepted once stop is requested.
        queue.asyncAfter(deadline: .now() + 0.15) { [self] in
            acceptsMotion = false
            recording.finish(reason: reason, queue: queue) { [self] result in
                recorder = nil; isFinishing = false
                if !wantsActive { stopMotion() }
                switch result {
                case let .success(directory): publish { $0.latestDirectory = directory }
                case let .failure(error): publish { $0.message = error.localizedDescription }
                }
                let nextPhase: CameraPhase = wantsActive && session.isRunning && !session.isInterrupted ? .ready : .unavailable
                publish { $0.phase = nextPhase }
                endFinishingTask()
                resumeIfPossible()
            }
        }
    }

    private func startMotion() {
        guard !motion.isGyroActive else { return }
        motion.gyroUpdateInterval = 0.01
        motion.accelerometerUpdateInterval = 0.01
        motion.deviceMotionUpdateInterval = 0.01
        motion.startGyroUpdates(to: motionQueue) { [weak self] data, error in
            guard let self else { return }
            if let error { fail(error); return }
            guard let data else { return }
            let v = data.rotationRate
            motionSample("gyro", time: data.timestamp, row: "\(data.timestamp),\(v.x),\(v.y),\(v.z)")
        }
        motion.startAccelerometerUpdates(to: motionQueue) { [weak self] data, error in
            guard let self else { return }
            if let error { fail(error); return }
            guard let data else { return }
            let v = data.acceleration
            motionSample("accelerometer", time: data.timestamp, row: "\(data.timestamp),\(v.x),\(v.y),\(v.z)")
        }
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { [weak self] data, error in
            guard let self else { return }
            if let error { fail(error); return }
            guard let data else { return }
            let g = data.gravity, q = data.attitude.quaternion
            motionSample("gravity", time: data.timestamp, row: "\(data.timestamp),\(g.x),\(g.y),\(g.z),\(q.x),\(q.y),\(q.z),\(q.w)")
        }
    }

    private func stopMotion() {
        motion.stopGyroUpdates(); motion.stopAccelerometerUpdates(); motion.stopDeviceMotionUpdates()
        for key in Array(histories.keys) { histories[key]?.clear() }
        latestMotionTime.removeAll()
    }

    private func motionSample(_ kind: String, time: Double, row: String) {
        latestMotionTime[kind] = time
        histories[kind]?.append(time: time, row: row)
        if acceptsMotion {
            do { try recorder?.appendMotion(kind, row: row) } catch { fail(error) }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let recording = recorder, !isFinishing else { return }
        do {
            if output === videoOutput, let device = cameraInput?.device {
                try recording.appendVideo(sampleBuffer, device: device, connection: connection, clock: session.synchronizationClock)
                let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                if now - lastUIPublish > 0.2 {
                    let duration = recording.manifest.durationSeconds
                    publish { $0.duration = duration }
                    lastUIPublish = now
                }
                if now - lastDiskCheck > 2 {
                    try checkDisk(minimum: 100_000_000); lastDiskCheck = now
                    if ProcessInfo.processInfo.thermalState == .critical { throw CaptureFailure.message("设备温度过高，录制已停止。") }
                    guard ["gyro", "accelerometer", "gravity"].allSatisfy({ now - (latestMotionTime[$0] ?? 0) < 1 }) else {
                        throw CaptureFailure.message("运动数据中断，录制已停止。")
                    }
                }
            } else if output === audioOutput {
                try recording.appendAudio(sampleBuffer, clock: session.synchronizationClock)
            }
        } catch { fail(error) }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let recorder, !isFinishing else { return }
        let reason = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil)
        do { try recorder.drop("video", pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), reason: reason.map { String(describing: $0) } ?? "capture_drop") }
        catch { fail(error) }
    }

    private func checkDisk(minimum: Int64) throws {
        try FileManager.default.createDirectory(at: Self.recordingsRoot, withIntermediateDirectories: true)
        let values = try Self.recordingsRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let bytes = values.volumeAvailableCapacityForImportantUsage, bytes < minimum {
            throw CaptureFailure.message("可用空间不足，请清理存储后再录制。已有素材会保留。")
        }
    }

    private func fail(_ error: Error) {
        if let recorder {
            recorder.markError(error)
            stopOnQueue(reason: "error")
        } else {
            let nextPhase: CameraPhase = configured && session.isRunning && !session.isInterrupted ? .ready : .unavailable
            publish { $0.phase = nextPhase }
        }
        publish { $0.message = error.localizedDescription }
    }

    private func publish(_ update: @escaping (CaptureService) -> Void) { DispatchQueue.main.async { update(self) } }

    private func beginFinishingTask() {
        DispatchQueue.main.async { [self] in
            guard backgroundTask == .invalid else { return }
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish recording") { [weak self] in self?.endFinishingTask() }
        }
    }

    private func endFinishingTask() {
        DispatchQueue.main.async { [self] in
            guard backgroundTask != .invalid else { return }
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}
