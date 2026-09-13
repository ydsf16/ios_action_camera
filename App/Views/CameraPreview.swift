import SwiftUI
import AVFoundation

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let device: AVCaptureDevice?
    let gridEnabled: Bool
    let interactionEnabled: Bool
    let focusFeedback: CameraFocusFeedback?
    var rotationChanged: (Double, Double, String) -> Void
    var focusRequested: (CGPoint, String, Bool) -> Void
    var zoomChanged: (Double, Bool) -> Void
    class PreviewView: UIView {
        var rotationChanged: ((Double, Double, String) -> Void)?
        var focusRequested: ((CGPoint, String, Bool) -> Void)?
        var zoomChanged: ((Double, Bool) -> Void)?
        var gridEnabled = false { didSet { updateOverlays() } }
        var interactionEnabled = false
        private let gridLayer = CAShapeLayer()
        private let focusLayer = CAShapeLayer()
        private let focusCaption = UILabel()
        private var feedback: CameraFocusFeedback?
        private var hideFeedback: DispatchWorkItem?
        private var feedbackVisible = false
        private var recognizers: [UIGestureRecognizer] = []

        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            isMultipleTouchEnabled = true
            gridLayer.strokeColor = UIColor.white.withAlphaComponent(0.4).cgColor
            gridLayer.lineWidth = 0.75
            gridLayer.fillColor = UIColor.clear.cgColor
            layer.addSublayer(gridLayer)
            focusLayer.strokeColor = UIColor.systemYellow.cgColor
            focusLayer.fillColor = UIColor.clear.cgColor
            focusLayer.lineWidth = 2
            layer.addSublayer(focusLayer)
            focusCaption.textColor = .systemYellow
            focusCaption.backgroundColor = UIColor.black.withAlphaComponent(0.6)
            focusCaption.font = .preferredFont(forTextStyle: .caption1)
            focusCaption.textAlignment = .center
            focusCaption.layer.cornerRadius = 5
            focusCaption.clipsToBounds = true
            focusCaption.isUserInteractionEnabled = false
            addSubview(focusCaption)
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
            hold.minimumPressDuration = 0.5
            hold.allowableMovement = 14
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
            tap.require(toFail: hold)
            recognizers = [tap, hold, pinch]
            recognizers.forEach { addGestureRecognizer($0) }
            accessibilityLabel = "相机取景画面"
            accessibilityHint = "轻点对焦，长按锁定焦点，双指缩放"
            updateOverlays()
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        @objc private func tapped(_ sender: UITapGestureRecognizer) {
            guard sender.state == .ended else { return }
            requestFocus(at: sender.location(in: self), lock: false)
        }
        @objc private func held(_ sender: UILongPressGestureRecognizer) {
            guard sender.state == .began, sender.numberOfTouches == 1 else { return }
            requestFocus(at: sender.location(in: self), lock: true)
        }
        @objc private func pinched(_ sender: UIPinchGestureRecognizer) {
            let ended = sender.state == .ended || sender.state == .cancelled || sender.state == .failed
            guard interactionEnabled || ended else { return }
            zoomChanged?(Double(sender.scale), ended)
        }
        private func requestFocus(at point: CGPoint, lock: Bool) {
            guard interactionEnabled, bounds.contains(point),
                  let device = rotationCoordinator?.device, previewLayer.connection != nil else { return }
            // AVFoundation accounts for aspect-fill cropping, preview rotation and mirroring.
            // This point is for camera control only, never for video/IMU coordinate transforms.
            let capturePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: point)
            focusRequested?(capturePoint, device.uniqueID, lock)
        }
        func display(_ value: CameraFocusFeedback?) {
            guard feedback != value else { return }
            hideFeedback?.cancel()
            feedback = value
            feedbackVisible = value != nil
            updateOverlays()
            if let value, !value.persistent {
                let hide = DispatchWorkItem { [weak self] in
                    guard self?.feedback?.id == value.id else { return }
                    self?.feedbackVisible = false
                    self?.updateOverlays()
                }
                hideFeedback = hide
                DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: hide)
            }
        }
        private func updateOverlays() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            gridLayer.frame = bounds
            let grid = UIBezierPath()
            if gridEnabled, bounds.width > 0, bounds.height > 0 {
                // Draw thirds of the actual camera image, clipped to the full-screen preview.
                let converted = previewLayer.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
                let rect = previewLayer.connection != nil && !converted.isEmpty && !converted.isInfinite && !converted.isNull ? converted : bounds
                for fraction in [CGFloat(1.0 / 3), CGFloat(2.0 / 3)] {
                    let x = rect.minX + rect.width * fraction
                    let y = rect.minY + rect.height * fraction
                    grid.move(to: CGPoint(x: x, y: rect.minY)); grid.addLine(to: CGPoint(x: x, y: rect.maxY))
                    grid.move(to: CGPoint(x: rect.minX, y: y)); grid.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
            }
            gridLayer.path = grid.cgPath
            focusLayer.frame = bounds
            focusLayer.path = nil
            focusCaption.isHidden = !feedbackVisible
            guard feedbackVisible, let feedback, bounds.width > 0, bounds.height > 0 else { return }
            let size = min(CGFloat(70), min(bounds.width, bounds.height))
            var point = feedback.point.map { previewLayer.layerPointConverted(fromCaptureDevicePoint: $0) }
                ?? CGPoint(x: bounds.midX, y: bounds.midY)
            guard point.x.isFinite, point.y.isFinite else { focusCaption.isHidden = true; return }
            point.x = max(size / 2, min(bounds.width - size / 2, point.x))
            point.y = max(size / 2, min(bounds.height - size / 2, point.y))
            let box = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
            if feedback.point != nil { focusLayer.path = UIBezierPath(roundedRect: box, cornerRadius: 5).cgPath }
            focusCaption.text = feedback.text
            let labelSize = focusCaption.sizeThatFits(CGSize(width: bounds.width - 20, height: 40))
            let width = min(bounds.width - 20, labelSize.width + 16)
            let height = labelSize.height + 10
            let x = max(10, min(bounds.width - width - 10, point.x - width / 2))
            let y = box.minY - height - 8 >= safeAreaInsets.top ? box.minY - height - 8 : box.maxY + 8
            focusCaption.frame = CGRect(x: x, y: min(bounds.height - height, y), width: width, height: height)
        }
        private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
        private var previewObservation: NSKeyValueObservation?
        private var captureObservation: NSKeyValueObservation?
        private var reportedCaptureAngle: CGFloat?
        private var reportedPreviewAngle: CGFloat?
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        func configure(device: AVCaptureDevice?) {
            guard rotationCoordinator?.device !== device else { updateOrientation(); return }
            previewObservation = nil; captureObservation = nil; rotationCoordinator = nil
            reportedCaptureAngle = nil; reportedPreviewAngle = nil
            guard let device else { return }
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
            rotationCoordinator = coordinator
            // Apple delivers these notifications on main. Keep the preview and
            // capture angles separate: they differ when the interface is locked.
            previewObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] _, _ in
                self?.updateOrientation()
            }
            captureObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] _, _ in
                self?.updateOrientation()
            }
        }
        func disconnect() {
            previewObservation = nil; captureObservation = nil; rotationCoordinator = nil
            rotationChanged = nil; focusRequested = nil; zoomChanged = nil
            hideFeedback?.cancel(); hideFeedback = nil
            feedback = nil; feedbackVisible = false
            previewLayer.session = nil
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            updateOrientation()
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            updateOrientation()
        }
        func updateOrientation() {
            defer { updateOverlays() }
            guard let coordinator = rotationCoordinator, let device = coordinator.device else { return }
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            // A detached preview layer reports zero; apply it once the view is visible.
            guard window != nil else { return }
            let captureAngle = coordinator.videoRotationAngleForHorizonLevelCapture
            if reportedCaptureAngle != captureAngle || reportedPreviewAngle != angle {
                reportedCaptureAngle = captureAngle; reportedPreviewAngle = angle
                rotationChanged?(Double(captureAngle), Double(angle), device.uniqueID)
            }
            guard let connection = previewLayer.connection else { return }
            // SwiftUI progress/timer updates must not reconfigure an unchanged camera connection.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if connection.videoRotationAngle != angle, connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            if connection.isVideoStabilizationSupported, connection.preferredVideoStabilizationMode != .off {
                connection.preferredVideoStabilizationMode = .off
            }
            CATransaction.commit()
        }
    }
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.rotationChanged = rotationChanged
        view.focusRequested = focusRequested; view.zoomChanged = zoomChanged
        view.gridEnabled = gridEnabled; view.interactionEnabled = interactionEnabled
        view.display(focusFeedback)
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.configure(device: device)
        return view
    }
    func updateUIView(_ view: PreviewView, context: Context) {
        view.rotationChanged = rotationChanged
        view.focusRequested = focusRequested; view.zoomChanged = zoomChanged
        view.gridEnabled = gridEnabled; view.interactionEnabled = interactionEnabled
        view.configure(device: device)
        view.display(focusFeedback)
    }
    static func dismantleUIView(_ view: PreviewView, coordinator: ()) {
        view.disconnect()
    }
}

