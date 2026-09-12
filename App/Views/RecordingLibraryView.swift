import SwiftUI
import AVKit

struct RecordingLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var library = RecordingLibraryModel()
    @ObservedObject private var jobs = StabilizationJobs.shared
    @State private var preview: RecordedClip?
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var deletion: ClipDeletion?

    private var selectedClips: [RecordedClip] { library.clips.filter { selection.contains($0.id) } }
    private var days: [Date] {
        Set(library.clips.map { Calendar.current.startOfDay(for: $0.manifest.createdAt) }).sorted(by: >)
    }

    var body: some View {
        NavigationStack {
            managedContent
                .alert(deletion?.title ?? "删除素材", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), presenting: deletion) { request in
                    Button("取消", role: .cancel) { deletion = nil }
                    Button("删除", role: .destructive) { deletion = nil; Task { _ = await library.remove(request.clips) } }
                } message: { Text($0.message) }
                .alert("素材提示", isPresented: Binding(get: { library.failure != nil && preview == nil }, set: { if !$0 { library.failure = nil } })) {
                    Button("知道了", role: .cancel) { library.failure = nil }
                } message: { Text(library.failure ?? "") }
        }.tint(.white)
    }

    private var managedContent: some View {
        navigationContent
            .fullScreenCover(item: $preview, onDismiss: { Task { await library.reload() } }) {
                ClipPreviewView(clip: $0, library: library)
            }
            .task { await library.reload() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await library.reload() } } }
            .onChange(of: jobs.revisions) { _, _ in Task { await library.reload() } }
            .onChange(of: library.clips.map(\.id)) { _, ids in
                selection.formIntersection(ids)
                if ids.isEmpty { selecting = false }
            }
    }

    private var navigationContent: some View {
        content
            .navigationTitle(selecting ? "选择素材" : "素材")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { libraryToolbar }
            .safeAreaInset(edge: .bottom, spacing: 0) { if selecting { selectionBar } }
            .disabled(library.deleting)
            .overlay {
                if library.deleting {
                    ProgressView("正在停止处理并删除…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .interactiveDismissDisabled(library.deleting)
    }

    @ViewBuilder private var content: some View {
        if library.loading { ProgressView("正在读取素材") }
        else if library.clips.isEmpty {
            ContentUnavailableView {
                Label("还没有视频", systemImage: "video")
            } description: { Text("拍摄的视频会保存在这里。") }
            actions: { Button("去拍摄") { dismiss() }.buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black) }
        } else { grid }
    }

    @ToolbarContentBuilder private var libraryToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if selecting {
                Button(selection.count == library.clips.count ? "取消全选" : "全选") {
                    selection = selection.count == library.clips.count ? [] : Set(library.clips.map(\.id))
                }.accessibilityIdentifier("selectAllClips")
            } else {
                Button { dismiss() } label: { Image(systemName: "chevron.down").frame(width: 32, height: 32) }
                    .accessibilityLabel("返回拍摄")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(selecting ? "取消" : "选择") { selecting.toggle(); selection.removeAll() }
                .disabled(library.clips.isEmpty).accessibilityIdentifier("selectClips")
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(days, id: \.self) { day in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(dayTitle(day)).font(.headline)
                            Spacer()
                            Text("\(clips(on: day).count) 段").font(.caption).foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            ForEach(clips(on: day)) { clip in
                                Button {
                                    if selecting { toggle(clip) } else { preview = clip }
                                } label: { ClipTile(clip: clip, selecting: selecting, selected: selection.contains(clip.id)) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("clip_\(clip.id)")
                                .accessibilityLabel("\(clip.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))，\(MediaText.duration(clip.manifest.durationSeconds))")
                                .accessibilityValue(selecting ? (selection.contains(clip.id) ? "已选择" : "未选择") : "")
                                .contextMenu {
                                    if !selecting {
                                        Button { selecting = true; selection = [clip.id] } label: { Label("选择", systemImage: "checkmark.circle") }
                                        Button(role: .destructive) { deletion = ClipDeletion(clips: [clip]) } label: { Label("删除素材", systemImage: "trash") }
                                    }
                                }
                            }
                        }
                    }
                }
            }.padding(16)
        }.refreshable { await library.reload() }
    }

    private var selectionBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(selection.isEmpty ? "选择要删除的素材" : "已选择 \(selection.count) 段").font(.subheadline.weight(.semibold))
                if !selection.isEmpty {
                    Text("约 \(MediaText.storage(selectedClips.reduce(0) { $0 + $1.allocatedBytes }))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(role: .destructive) { deletion = ClipDeletion(clips: selectedClips) } label: {
                Label("删除", systemImage: "trash").frame(minHeight: 32)
            }.buttonStyle(.bordered).tint(.red).disabled(selection.isEmpty).accessibilityIdentifier("deleteSelection")
        }.padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
    }
    private func clips(on day: Date) -> [RecordedClip] { library.clips.filter { Calendar.current.isDate($0.manifest.createdAt, inSameDayAs: day) } }
    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "今天" }
        if Calendar.current.isDateInYesterday(day) { return "昨天" }
        return day.formatted(.dateTime.year().month().day())
    }
    private func toggle(_ clip: RecordedClip) { if !selection.insert(clip.id).inserted { selection.remove(clip.id) } }
}

private struct ClipTile: View {
    let clip: RecordedClip
    let selecting: Bool
    let selected: Bool
    @ObservedObject private var jobs = StabilizationJobs.shared
    @State private var thumbnail: UIImage?
    private var badge: (text: String, symbol: String, warning: Bool) {
        if !clip.canPlay { return ("未完成", "exclamationmark.triangle", true) }
        switch jobs.states[clip.id] {
        case .queued: return ("等待处理", "clock", false)
        case let .processing(value): return ("\(Int(min(1, max(0, value)) * 100))%", "circle.dotted", false)
        case .ready: return ("已稳定", "checkmark", false)
        case .failed: return ("待重试", "arrow.clockwise", true)
        default:
            return FileManager.default.fileExists(atPath: clip.directory.appendingPathComponent(StabilizationProcessor.filename).path)
                ? ("已稳定", "checkmark", false) : ("原片", "video", false)
        }
    }
    var body: some View {
        Color.white.opacity(0.07)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    if let thumbnail {
                        Image(uiImage: thumbnail).resizable().scaledToFill().frame(width: proxy.size.width, height: proxy.size.height).clipped()
                    } else {
                        Image(systemName: clip.canPlay ? "video" : "exclamationmark.triangle")
                            .font(.title2).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .overlay(alignment: .bottom) { LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom).frame(height: 64) }
            .overlay(alignment: .topLeading) {
                Label(badge.text, systemImage: badge.symbol).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(badge.warning ? .yellow : .white).padding(.horizontal, 7).padding(.vertical, 5)
                    .background(.black.opacity(0.6), in: Capsule()).padding(8)
            }
            .overlay(alignment: .bottomTrailing) {
                Text(MediaText.duration(clip.manifest.durationSeconds)).font(.caption.weight(.medium).monospacedDigit()).padding(10)
            }
            .overlay { if selected { Color.yellow.opacity(0.12) } }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? .yellow : .clear, lineWidth: 3) }
            .overlay(alignment: .topTrailing) {
                if selecting {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.title2).foregroundStyle(selected ? .yellow : .white)
                        .background(.black.opacity(0.5), in: Circle()).padding(8)
                }
            }
            .task {
                guard clip.canPlay else { return }
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clip.video))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 500, height: 500)
                if let image = try? await generator.image(at: .zero), !Task.isCancelled { thumbnail = UIImage(cgImage: image.image) }
            }
    }
}
