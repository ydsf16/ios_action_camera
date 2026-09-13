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
    @Published private(set) var usesVirtualCamera = false
    @Published private(set) var previewDevice: AVCaptureDevice?
    @Published private(set) var zoom = 1.0
    @Published private(set) var zoomRange = CaptureZoom(multiplier: 1, minimumDeviceZoom: 1, maximumDeviceZoom: 1, nativeDeviceZooms: [])
    @Published private(set) var activeLensLabel = ""
    private var lastZoomPublish = 0.0
    private var zoomRequest: DispatchWorkItem?
    @Published private(set) var exposurePolicy = CaptureExposurePolicy.load()
    private var activeExposurePolicy = CaptureExposurePolicy.load()
    @Published private(set) var focusLabel = "准备中"
    @Published private(set) var focusFeedback: CameraFocusFeedback?
    private var focusSelection: CameraFocusFeedback? // capture queue only
    private var focusPrimaryID: String?
    @Published private(set) var selectedFormat = CaptureFormat.load()
    @Published private(set) var availableFormats: [CaptureFormat] = []
    var formatLabel: String { selectedFormat.label }
    var availableResolutions: [CaptureResolution] {
        CaptureResolution.allCases.filter { resolution in availableFormats.contains { $0.resolution == resolution } }
    }
    var availableFrameRates: [Int] { availableFormats.filter { $0.resolution == selectedFormat.resolution }.map(\.fps) }
    private var activeCaptureFormat = CaptureFormat.load()
    private var formatChoices: [CaptureFormat: AVCaptureDevice.Format] = [:]
    @Published private(set) var duration = 0.0
    @Published private(set) var latestDirectory: URL?
    @Published var message: String?
    @Published private(set) var permissionDenied = false

    private let queue = DispatchQueue(label: "com.grape.RoamShot.capture", qos: .userInitiated)
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
    private var recordingLimitTimeout: DispatchWorkItem?
    @Published private(set) var startingRecording = false
    private var isFinishing = false
    private var acceptsMotion = false
    private var configured = false
    private var wantsActive = false
    private var recordingRotationDegrees: Int?
    private var previewRotationDegrees: Double?
    func setCameraRotation(capture: Double, preview: Double, deviceID: String) {
        guard let degrees = RecordingRotation.quarterTurn(from: capture), preview.isFinite else { return }
        queue.async { [self] in
            // Discard delayed callbacks from a previous physical/virtual input.
            guard cameraInput?.device.uniqueID == deviceID else { return }
            guard recordingRotationDegrees != degrees || previewRotationDegrees != preview else { return }
            recordingRotationDegrees = degrees
            previewRotationDegrees = preview
            writeConfigurationReport()
        }
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

    #if DEBUG && targetEnvironment(simulator)
    // Marketing fixtures render the production controls over explicitly labeled sample media.
    // This input and its state overrides are absent from device and Release builds.
    let storeScreenshotImage: UIImage? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--store-camera-image"), i + 1 < args.count else { return nil }
        return UIImage(contentsOfFile: args[i + 1])
    }()
    #endif

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
        #if DEBUG && targetEnvironment(simulator)
        if storeScreenshotImage != nil {
            await MainActor.run {
                self.selectedFormat = .standard
                self.usesVirtualCamera = true
                self.zoomRange = CaptureZoom(multiplier: 0.5, minimumDeviceZoom: 1,
                    maximumDeviceZoom: 10, nativeDeviceZooms: [2])
                self.phase = .ready
            }
            return
        }
        #endif
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
        #if DEBUG && targetEnvironment(simulator)
        if storeScreenshotImage != nil { return }
        #endif
        if !active { beginFinishingTask() }
        queue.async { [self] in
            wantsActive = active
            if active { resumeIfPossible() }
            else {
                stopOnQueue(reason: "app_background")
                if let device = cameraInput?.device {
                    do {
                        try device.lockForConfiguration()
                        resetFocusLocked(device)
                        device.unlockForConfiguration()
                    } catch { /* Retain actual focus status if configuration is unavailable. */ }
                }
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
        var installedVirtual = false
        for type in [AVCaptureDevice.DeviceType.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera] {
            guard AVCaptureDevice.default(type, for: .video, position: .back) != nil else { continue }
            do {
                try installCamera(CameraLens(id: type.rawValue, label: "自动", type: type))
                installedVirtual = true
                break
            } catch { /* Try a compatible virtual device, then the physical fallback. */ }
        }
        if !installedVirtual { try installCamera(lens) }
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
            let choices = supportedFormats(device)
            guard let selected = activeCaptureFormat.resolved(in: CaptureFormat.candidates.filter { choices[$0] != nil }),
                  let format = choices[selected] else { throw CaptureFailure.message("此镜头没有支持的录制格式。") }
            try configureFormat(device, selection: selected, format: format)
            cameraInput = replacement
            try configureVideoConnection()
            if device.isVirtualDevice, videoOutput.connection(with: .video)?.isCameraIntrinsicMatrixDeliveryEnabled != true {
                throw CaptureFailure.message("此虚拟相机格式不支持逐帧内参，无法用于稳定处理。")
            }
            let changed = selected != activeCaptureFormat
            recordingRotationDegrees = nil
            previewRotationDegrees = nil
            activeCaptureFormat = selected; formatChoices = choices
            selected.save()
            let focus = device.focusMode == .continuousAutoFocus ? "连续自动对焦" : "此镜头为固定对焦"
            publish {
                $0.focusLabel = focus; $0.selectedLens = lens.id; $0.selectedFormat = selected
                $0.usesVirtualCamera = device.isVirtualDevice
                $0.previewDevice = device
                $0.availableFormats = CaptureFormat.candidates.filter { choices[$0] != nil }
                if changed { $0.message = "此镜头已使用支持的格式：\(selected.label) fps。" }
            }
            publishZoom(device, force: true)
        } catch {
            if session.inputs.contains(replacement) { session.removeInput(replacement) }
            cameraInput = previous
            // Re-adding an input resets frame durations; restore them on rollback.
            if let previous, session.canAddInput(previous) {
                session.addInput(previous)
                if let format = formatChoices[activeCaptureFormat] {
                    try configureFormat(previous.device, selection: activeCaptureFormat, format: format)
                    try configureVideoConnection()
                }
            }
            throw error
        }
    }

    private func configureVideoConnection() throws {
        guard let connection = videoOutput.connection(with: .video) else { throw CaptureFailure.message("视频连接不可用。") }
        if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
        guard connection.isVideoRotationAngleSupported(0) else { throw CaptureFailure.message("无法保持相机原始像素方向。") }
        connection.videoRotationAngle = 0
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        if connection.isCameraIntrinsicMatrixDeliverySupported { connection.isCameraIntrinsicMatrixDeliveryEnabled = true }
    }

    private func supportedFormats(_ device: AVCaptureDevice) -> [CaptureFormat: AVCaptureDevice.Format] {
        var choices: [CaptureFormat: AVCaptureDevice.Format] = [:]
        for candidate in CaptureFormat.candidates {
            choices[candidate] = device.formats.first { format in
                let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return size.width == candidate.resolution.width && size.height == candidate.resolution.height
                    && CMFormatDescriptionGetMediaSubType(format.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                    && format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(candidate.fps) && $0.maxFrameRate >= Double(candidate.fps) }
            }
        }
        return choices
    }

    /// Called inside a session configuration transaction. Only native SDR formats are offered.
    private func configureFormat(_ device: AVCaptureDevice, selection: CaptureFormat, format: AVCaptureDevice.Format) throws {
        if let limit = activeExposurePolicy.maximumExposureMilliseconds,
           format.minExposureDuration.seconds > Double(limit) / 1000 {
            throw CaptureFailure.message("此格式不支持当前曝光上限，请先切换曝光模式。")
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = format
        if #available(iOS 18.0, *), device.activeFormat.isAutoVideoFrameRateSupported { device.isAutoVideoFrameRateEnabled = false }
        let duration = CMTime(value: 1, timescale: CMTimeScale(selection.fps))
        if CMTimeCompare(duration, device.activeVideoMaxFrameDuration) > 0 {
            device.activeVideoMaxFrameDuration = duration
            device.activeVideoMinFrameDuration = duration
        } else {
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        }
        device.automaticallyAdjustsVideoHDREnabled = false
        if format.isVideoHDRSupported { device.isVideoHDREnabled = false }
        let zoomRange = Self.zoomConfiguration(device)
        device.cancelVideoZoomRamp()
        device.videoZoomFactor = CGFloat(zoomRange.deviceZoom(for: 1))
        if device.isVirtualDevice, device.primaryConstituentDeviceSwitchingBehavior != .unsupported {
            device.setPrimaryConstituentDeviceSwitchingBehavior(.auto, restrictedSwitchingBehaviorConditions: [])
        }
        resetFocusLocked(device)
        try applyRecordingControlsLocked(device)
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
    }

    func selectResolution(_ resolution: CaptureResolution) {
        queue.async { [self] in
            let desired = CaptureFormat(resolution: resolution, fps: activeCaptureFormat.fps)
            let supported = CaptureFormat.candidates.filter { $0.resolution == resolution && formatChoices[$0] != nil }
            if let selected = desired.resolved(in: supported) { selectFormatOnQueue(selected) }
        }
    }

    func selectFrameRate(_ fps: Int) {
        queue.async { [self] in selectFormatOnQueue(CaptureFormat(resolution: activeCaptureFormat.resolution, fps: fps)) }
    }

    private func selectFormatOnQueue(_ selection: CaptureFormat) {
        guard configured, wantsActive, recorder == nil, !isFinishing,
              let device = cameraInput?.device, let format = formatChoices[selection], selection != activeCaptureFormat else { return }
        let previous = activeCaptureFormat
        let previousFormat = device.activeFormat
        publish { $0.phase = .preparing }
        session.stopRunning()
        session.beginConfiguration()
        do {
            try configureFormat(device, selection: selection, format: format)
            try configureVideoConnection()
            if device.isVirtualDevice, videoOutput.connection(with: .video)?.isCameraIntrinsicMatrixDeliveryEnabled != true {
                throw CaptureFailure.message("此格式无法提供稳定所需的逐帧内参，请选择其他格式。")
            }
            activeCaptureFormat = selection
            selection.save()
            publish { $0.selectedFormat = selection }
        } catch {
            let failure = error
            do {
                try configureFormat(device, selection: previous, format: previousFormat)
                try configureVideoConnection()
            } catch {
                // Leave a clean, retryable session if restoration itself fails.
                session.inputs.forEach(session.removeInput); session.outputs.forEach(session.removeOutput)
                cameraInput = nil; configured = false
                session.commitConfiguration()
                stopMotion()
                publish { $0.previewDevice = nil; $0.phase = .unavailable; $0.message = "恢复相机配置失败，请重新进入应用。" }
                return
            }
            publish { $0.message = failure.localizedDescription }
        }
        session.commitConfiguration()
        publishZoom(device, force: true)
        resumeIfPossible()
    }

    static func zoomConfiguration(_ device: AVCaptureDevice) -> CaptureZoom {
        let multiplier: Double
        if #available(iOS 18.0, *) { multiplier = Double(device.displayVideoZoomFactorMultiplier) }
        else if device.isVirtualDevice,
                let wide = device.constituentDevices.firstIndex(where: { $0.deviceType == .builtInWideAngleCamera }), wide > 0,
                wide - 1 < device.virtualDeviceSwitchOverVideoZoomFactors.count {
            multiplier = 1 / device.virtualDeviceSwitchOverVideoZoomFactors[wide - 1].doubleValue
        } else { multiplier = device.deviceType == .builtInUltraWideCamera ? 0.5 : 1 }
        return CaptureZoom(multiplier: multiplier,
            minimumDeviceZoom: Double(device.minAvailableVideoZoomFactor),
            maximumDeviceZoom: Double(device.maxAvailableVideoZoomFactor),
            nativeDeviceZooms: [1] + device.virtualDeviceSwitchOverVideoZoomFactors.map(\.doubleValue))
    }

    /// Coalesce gesture updates on the capture queue; never stop/reconfigure the
    /// session or reset its clock while changing zoom during a recording.
    func setZoom(_ value: Double, smooth: Bool = false) {
        #if DEBUG && targetEnvironment(simulator)
        if storeScreenshotImage != nil {
            publish { $0.zoom = $0.zoomRange.clamped(value) }
            return
        }
        #endif
        guard value.isFinite else { return }
        queue.async { [self] in
            zoomRequest?.cancel()
            let request = DispatchWorkItem { [weak self] in
                guard let self, self.configured, self.wantsActive, self.session.isRunning, !self.isFinishing,
                      let device = self.cameraInput?.device else { return }
                do {
                    let range = Self.zoomConfiguration(device)
                    let target = CGFloat(range.deviceZoom(for: value))
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }
                    if smooth { device.ramp(toVideoZoomFactor: target, withRate: 3) }
                    else { device.videoZoomFactor = target }
                    self.publishZoom(device, force: true)
                } catch { self.publish { $0.message = error.localizedDescription } }
            }
            zoomRequest = request
            queue.async(execute: request)
        }
    }

    /// Point comes from AVCaptureVideoPreviewLayer, already in native camera coordinates.
    /// Focus changes do not reconfigure the session, exposure, output connection or IMU.
    func focus(at point: CGPoint, deviceID: String, lock: Bool) {
        guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y) else { return }
        queue.async { [self] in
            guard configured, wantsActive, session.isRunning, !isFinishing,
                  let device = cameraInput?.device, device.uniqueID == deviceID else { return }
            let primary = device.activePrimaryConstituent ?? device
            let mode: AVCaptureDevice.FocusMode = lock ? .autoFocus : .continuousAutoFocus
            guard device.isFocusPointOfInterestSupported, device.isFocusModeSupported(mode),
                  primary.isFocusPointOfInterestSupported, primary.isFocusModeSupported(mode) else {
                let feedback = CameraFocusFeedback(id: UUID(), point: nil, phase: .unavailable)
                // Keep a previously requested lock intact when an unsupported request is rejected.
                publish { $0.focusFeedback = feedback }
                return
            }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.focusPointOfInterest = point
                // Apple's one-shot autoFocus transitions to locked when its scan completes.
                device.focusMode = mode
                focusPrimaryID = primary.uniqueID
                let selection = CameraFocusFeedback(id: UUID(), point: point, phase: lock ? .locking : .tracking)
                focusSelection = selection
                publish { $0.focusFeedback = selection }
                refreshFocusStatus(device)
                writeConfigurationReport()
            } catch { publish { $0.message = error.localizedDescription } }
        }
    }

    /// Caller holds lockForConfiguration. Format/input changes restore normal focusing.
    private func resetFocusLocked(_ device: AVCaptureDevice) {
        if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5) }
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        focusSelection = nil
        focusPrimaryID = (device.activePrimaryConstituent ?? device).uniqueID
        publish { $0.focusFeedback = nil }
    }

    /// Read actual focus mode on the existing throttled preview-frame path.
    private func refreshFocusStatus(_ device: AVCaptureDevice) {
        let primary = device.activePrimaryConstituent ?? device
        if let previous = focusPrimaryID, previous != primary.uniqueID,
           let selection = focusSelection, selection.point != nil {
            let primaryID = primary.uniqueID
            // publishZoom also runs while zoom configuration is locked. Defer the reset
            // and reject stale work if another tap/input change arrives in the meantime.
            queue.async { [weak self] in
                guard let self, self.cameraInput?.device === device,
                      self.focusSelection?.id == selection.id,
                      (device.activePrimaryConstituent ?? device).uniqueID == primaryID else { return }
                do {
                    try device.lockForConfiguration()
                    self.resetFocusLocked(device)
                    device.unlockForConfiguration()
                    let feedback = CameraFocusFeedback(id: UUID(), point: nil, phase: .resumed)
                    self.publish { $0.focusFeedback = feedback }
                    self.writeConfigurationReport()
                } catch { self.publish { $0.message = error.localizedDescription } }
            }
        }
        focusPrimaryID = primary.uniqueID
        if var selection = focusSelection, selection.phase == .locking,
           device.focusMode == .locked, !device.isAdjustingFocus, !primary.isAdjustingFocus {
            selection.phase = .locked
            focusSelection = selection
            publish { $0.focusFeedback = selection }
            writeConfigurationReport()
        }
        if var selection = focusSelection, selection.phase == .locked, device.focusMode != .locked {
            selection.phase = .tracking
            focusSelection = selection
            publish { $0.focusFeedback = selection }
        }
        let label: String
        if !primary.isFocusModeSupported(.continuousAutoFocus) && !primary.isFocusModeSupported(.autoFocus) {
            label = "此镜头为固定对焦"
        } else if focusSelection?.phase == .locking {
            label = "正在对焦后锁定"
        } else if device.focusMode == .locked {
            label = "焦点已锁定"
        } else {
            label = "连续自动对焦"
        }
        publish { if $0.focusLabel != label { $0.focusLabel = label } }
    }

    private func publishZoom(_ device: AVCaptureDevice, force: Bool = false) {
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        guard force || now - lastZoomPublish >= 0.1 else { return }
        lastZoomPublish = now
        let range = Self.zoomConfiguration(device)
        let value = range.displayZoom(for: Double(device.videoZoomFactor))
        let primary = device.activePrimaryConstituent ?? device
        let label: String
        switch primary.deviceType {
        case .builtInUltraWideCamera: label = "超广角"
        case .builtInWideAngleCamera: label = "广角"
        case .builtInTelephotoCamera: label = "长焦"
        default: label = "自动"
        }
        refreshFocusStatus(device)
        publish {
            if $0.zoomRange != range { $0.zoomRange = range }
            if abs($0.zoom - value) > 0.001 { $0.zoom = value }
            if $0.activeLensLabel != label { $0.activeLensLabel = label }
        }
    }

    /// Caller holds the device configuration lock. Reapply after format changes.
    private func applyRecordingControlsLocked(_ device: AVCaptureDevice, policy: CaptureExposurePolicy? = nil) throws {
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
        let size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let report: [String: Any] = ["focus_mode": device.focusMode.rawValue,
            "focus_point": [device.focusPointOfInterest.x, device.focusPointOfInterest.y],
            "focus_adjusting": device.isAdjustingFocus,
            "user_focus_lock_requested": focusSelection?.persistent ?? false,
            "camera": device.deviceType.rawValue, "virtual_camera": device.isVirtualDevice,
            "constituent_devices": device.constituentDevices.map { $0.deviceType.rawValue },
            "active_camera_observed": (device.activePrimaryConstituent ?? device).deviceType.rawValue,
            "zoom_observed": device.videoZoomFactor,
            "display_zoom_multiplier": Self.zoomConfiguration(device).multiplier,
            "intrinsics_delivery_enabled": videoOutput.connection(with: .video)?.isCameraIntrinsicMatrixDeliveryEnabled ?? false,
            "stabilization_active": videoOutput.connection(with: .video)?.activeVideoStabilizationMode.rawValue ?? -1,
            "width": size.width, "height": size.height, "requested_fps": activeCaptureFormat.fps,
            "orientation_source": "AVCaptureDevice.RotationCoordinator",
            "capture_rotation_degrees": recordingRotationDegrees as Any? ?? NSNull(),
            "preview_rotation_degrees": previewRotationDegrees as Any? ?? NSNull(),
            "min_frame_duration_seconds": device.activeVideoMinFrameDuration.seconds,
            "max_frame_duration_seconds": device.activeVideoMaxFrameDuration.seconds,
            "available_formats": CaptureFormat.candidates.filter { formatChoices[$0] != nil }.map {
                ["resolution": $0.resolution.label, "width": $0.resolution.width, "height": $0.resolution.height, "fps": $0.fps] as [String: Any]
            },
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

    @MainActor func startRecording() {
        guard phase == .ready, !startingRecording else { return }
        startingRecording = true
        Task {
            let entitled = await ProAccess.shared.refresh()
            let maximumDuration = RecordingLimitPolicy.maximumDuration(hasPro: entitled)
            startingRecording = false
            startRecording(maximumDuration: maximumDuration)
        }
    }
    private func startRecording(maximumDuration: Double?) {
        queue.async { [self] in
            guard wantsActive, session.isRunning, !session.isInterrupted, recorder == nil, !isFinishing,
                  let device = cameraInput?.device, let connection = videoOutput.connection(with: .video) else { return }
            do {
                guard let recordingRotationDegrees else { throw CaptureFailure.message("正在确定拍摄方向，请稍后重试。") }
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
                let frameDuration = CMTime(value: 1, timescale: CMTimeScale(activeCaptureFormat.fps))
                guard CMTimeCompare(device.activeVideoMinFrameDuration, frameDuration) == 0,
                      CMTimeCompare(device.activeVideoMaxFrameDuration, frameDuration) == 0 else {
                    throw CaptureFailure.message("相机帧率与所选格式不一致，请重新选择录制格式。")
                }
                do {
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }
                    try applyRecordingControlsLocked(device)
                }
                let recording = try RecordingWriter(root: Self.recordingsRoot, device: device, connection: connection, rotationDegrees: recordingRotationDegrees, exposurePolicy: activeExposurePolicy.rawValue, captureFormat: activeCaptureFormat, maximumDuration: maximumDuration)
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
        recordingLimitTimeout?.cancel(); recordingLimitTimeout = nil
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
        if output === videoOutput, let device = cameraInput?.device { publishZoom(device) }
        guard let recording = recorder, !isFinishing else { return }
        do {
            if output === videoOutput, let device = cameraInput?.device {
                if recording.reachedLimit(before: sampleBuffer) {
                    stopOnQueue(reason: "free_recording_limit"); return
                }
                let wasFirstFrame = recording.manifest.videoFrames == 0
                try recording.appendVideo(sampleBuffer, device: device, connection: connection, clock: session.synchronizationClock)
                if wasFirstFrame, recording.manifest.videoFrames > 0, let limit = recording.maximumDuration {
                    // Fallback if the camera stops delivering callbacks near the limit.
                    let timeout = DispatchWorkItem { [weak self, weak recording] in
                        guard let self, let recording, self.recorder === recording else { return }
                        self.stopOnQueue(reason: "free_recording_limit")
                    }
                    recordingLimitTimeout = timeout
                    queue.asyncAfter(deadline: .now() + limit, execute: timeout)
                }
                if RecordingLimitPolicy.reached(duration: recording.manifest.durationSeconds, maximumDuration: recording.maximumDuration) {
                    publish { $0.duration = recording.manifest.durationSeconds }
                    stopOnQueue(reason: "free_recording_limit"); return
                }
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

    #if DEBUG
    private struct FocusCheckSnapshot: Sendable {
        let deviceID: String
        let mode: Int
        let x: Double
        let y: Double
        let contract: String
    }
    private func focusCheckSnapshot() async throws -> FocusCheckSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard recorder == nil, !isFinishing, session.isRunning,
                      let device = cameraInput?.device, let connection = videoOutput.connection(with: .video),
                      let clock = session.synchronizationClock else {
                    continuation.resume(throwing: InputError("对焦验证需要空闲的相机预览。")); return
                }
                let contract = "\(device.uniqueID)|\(ObjectIdentifier(clock))|\(activeCaptureFormat.id)|\(device.activeVideoMinFrameDuration)|\(device.activeVideoMaxFrameDuration)|\(device.activeMaxExposureDuration)|\(device.exposureMode.rawValue)|\(connection.videoRotationAngle)|\(connection.activeVideoStabilizationMode.rawValue)"
                continuation.resume(returning: FocusCheckSnapshot(deviceID: device.uniqueID,
                    mode: device.focusMode.rawValue, x: device.focusPointOfInterest.x,
                    y: device.focusPointOfInterest.y, contract: contract))
            }
        }
    }
    /// Device-only regression runner: exercises the same focus entry point as preview gestures.
    /// No recording, synthetic success states, or production UI controls are added.
    @MainActor func validateFocusControls() async {
        let url = Self.recordingsRoot.deletingLastPathComponent().appendingPathComponent("focus-controls-validation.json")
        var result: [String: Any] = ["passed": false]
        var originalID: String?
        do {
            for _ in 0..<50 {
                if phase == .ready { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let baseline = try await focusCheckSnapshot()
            originalID = baseline.deviceID
            focus(at: CGPoint(x: 0.37, y: 0.61), deviceID: baseline.deviceID, lock: false)
            try await Task.sleep(nanoseconds: 300_000_000)
            let tracking = try await focusCheckSnapshot()
            guard tracking.mode == AVCaptureDevice.FocusMode.continuousAutoFocus.rawValue,
                  abs(tracking.x - 0.37) < 0.0001, abs(tracking.y - 0.61) < 0.0001 else { throw InputError("点按对焦未按请求生效。") }
            focus(at: CGPoint(x: 0.37, y: 0.61), deviceID: baseline.deviceID, lock: true)
            var locked = try await focusCheckSnapshot()
            for _ in 0..<60 {
                if locked.mode == AVCaptureDevice.FocusMode.locked.rawValue { break }
                try await Task.sleep(nanoseconds: 100_000_000)
                locked = try await focusCheckSnapshot()
            }
            guard locked.mode == AVCaptureDevice.FocusMode.locked.rawValue else { throw InputError("自动对焦尚未完成锁定。") }
            focus(at: CGPoint(x: 0.1, y: 0.1), deviceID: "stale-preview-device", lock: false)
            try await Task.sleep(nanoseconds: 150_000_000)
            let stale = try await focusCheckSnapshot()
            guard stale.mode == locked.mode, stale.x == locked.x, stale.y == locked.y else { throw InputError("旧预览请求不应修改当前对焦。") }
            focus(at: CGPoint(x: 0.5, y: 0.5), deviceID: baseline.deviceID, lock: false)
            try await Task.sleep(nanoseconds: 300_000_000)
            let restored = try await focusCheckSnapshot()
            guard restored.mode == AVCaptureDevice.FocusMode.continuousAutoFocus.rawValue,
                  [tracking, locked, stale, restored].allSatisfy({ $0.contract == baseline.contract }) else { throw InputError("恢复自动对焦或采集配置保持检查失败。") }
            result = ["passed": true, "tap_point": [tracking.x, tracking.y], "tap_mode": tracking.mode,
                      "locked_mode": locked.mode, "restored_mode": restored.mode,
                      "stale_request_ignored": true, "capture_clock_format_exposure_orientation_unchanged": true]
        } catch { result["error"] = error.localizedDescription }
        if let originalID { focus(at: CGPoint(x: 0.5, y: 0.5), deviceID: originalID, lock: false) }
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]) {
            try? data.write(to: url, options: .atomic)
        }
    }
    #endif

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
