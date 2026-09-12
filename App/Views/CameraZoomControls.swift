import SwiftUI

struct CameraZoomControls: View {
    @ObservedObject var camera: CaptureService
    @State private var expanded = false
    @State private var dragging = false
    @State private var position = 0.0
    private var enabled: Bool { camera.phase == .ready || camera.phase == .recording }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                ForEach(camera.zoomRange.stops, id: \.self) { stop in
                    Button { camera.setZoom(stop, smooth: true) } label: {
                        Text(stop.formatted(.number.precision(.fractionLength(0...1))) + "×")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(abs(camera.zoom - stop) < 0.04 ? .yellow : .white)
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.45), in: Circle())
                    }.accessibilityLabel("变焦至 \(CaptureZoom.label(stop))")
                }
                Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                    HStack(spacing: 5) {
                        Text(CaptureZoom.label(camera.zoom)).monospacedDigit()
                        Image(systemName: expanded ? "chevron.down" : "slider.horizontal.3").font(.caption)
                    }.font(.subheadline.weight(.semibold)).foregroundStyle(.yellow)
                        .padding(.horizontal, 12).frame(minHeight: 44)
                        .background(.black.opacity(0.55), in: Capsule())
                }.accessibilityLabel(expanded ? "收起变焦滑条" : "展开变焦滑条")
                    .accessibilityValue(CaptureZoom.label(camera.zoom)).accessibilityIdentifier("zoomControl")
            }
            if expanded, camera.zoomRange.maximum > camera.zoomRange.minimum {
                VStack(spacing: 2) {
                    Slider(value: Binding(get: { dragging ? position : camera.zoomRange.position(for: camera.zoom) }, set: {
                        position = $0
                        camera.setZoom(camera.zoomRange.zoom(at: $0))
                    }), in: 0...1, onEditingChanged: { editing in
                        if editing { position = camera.zoomRange.position(for: camera.zoom) }
                        dragging = editing
                    })
                    .tint(.yellow).accessibilityLabel("拍摄变焦")
                    .accessibilityValue(CaptureZoom.label(camera.zoom))
                    HStack {
                        Text(CaptureZoom.label(camera.zoomRange.minimum))
                        Spacer()
                        Text(CaptureZoom.label(camera.zoomRange.maximum))
                    }.font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                }.padding(.horizontal, 16).padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: 320).padding(.horizontal, 20)
            }
        }.disabled(!enabled)
    }
}
