import AppKit
import SwiftUI
import UniformTypeIdentifiers
import V380

struct RecordingsView: View {
    @ObservedObject var playback: PlaybackController
    @ObservedObject var model: AppModel
    @State private var showList = false
    @State private var zoom: CGFloat = 1

    var body: some View {
        ZStack {
            VideoSurface(renderer: playback.renderer, onZoom: { z in withAnimation(.easeOut(duration: 0.12)) { zoom = z } })
                .opacity(playback.state == .playing || playback.state == .paused ? 1 : 0.35)

            centerMessage

            VStack(spacing: 0) {
                HStack {
                    DayNavigator(playback: playback)
                    ZoomBadge(zoom: zoom) { playback.renderer.view.resetZoom() }
                    Spacer()
                }
                .padding(.top, 8).padding(.leading, 10)

                HStack(alignment: .top, spacing: 0) {
                    if showList {
                        SegmentList(playback: playback)
                            .frame(width: 210)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    Spacer()
                }
                .padding(.top, 8)

                Spacer(minLength: 0)
                transportBar
            }

            if playback.exportState != .idle {
                ExportOverlay(playback: playback)
            }
        }
    }

    @ViewBuilder private var centerMessage: some View {
        switch (playback.listState, playback.state) {
        case (.loading(let text), _):
            StatusMessage(spinner: true, text: text)
        case (.failed(let text), _):
            VStack(spacing: 10) {
                StatusMessage(text: "Couldn't read the SD card.\n\(text)")
                Button("Try again") { playback.reloadList() }
            }
        case (_, .loading(let text)):
            StatusMessage(spinner: true, text: text)
        case (_, .failed(let text)):
            VStack(spacing: 10) {
                StatusMessage(text: "Playback stopped.\n\(text)")
                Button("Try again") { playback.togglePause() }
            }
        case (.idle, .idle) where playback.segments.isEmpty:
            StatusMessage(text: "No recordings on this day.")
        case (.idle, .idle):
            StatusMessage(text: "\(playback.segments.count) recordings. Click the timeline below to play.")
        case (_, .ended):
            StatusMessage(text: "End of recordings for this day.")
        default:
            EmptyView()
        }
    }

    private var transportBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                IconButton(symbol: "list.bullet", help: "Recording list") {
                    withAnimation(.easeOut(duration: 0.18)) { showList.toggle() }
                }
                IconButton(symbol: "gobackward.10", help: "Back 10 seconds") { playback.skip(-10) }
                    .disabled(playback.current == nil)
                Button(action: playback.togglePause) {
                    Image(systemName: playback.state == .playing ? "pause.fill" : "play.fill")
                        .font(.title3).frame(width: 26, height: 22)
                }
                .buttonStyle(.borderless).foregroundStyle(.white)
                .help("Play / pause (Space)")
                .disabled(playback.current == nil)
                IconButton(symbol: "goforward.10", help: "Forward 10 seconds") { playback.skip(10) }
                    .disabled(playback.current == nil)

                if let seg = playback.current {
                    Text(PlaybackController.timeString(playback.position))
                        .font(.body.monospacedDigit().weight(.semibold)).foregroundStyle(.white)
                    if let kind = seg.kind, kind != .normal {
                        Text(kind == .motion ? "Motion" : "Alarm")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(SegmentColor.of(seg).opacity(0.85), in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                Spacer()

                Menu {
                    Section("Save from here as .mp4") {
                        Button("Next 15 seconds") { startExport(15) }
                        Button("Next 30 seconds") { startExport(30) }
                        Button("Next 1 minute") { startExport(60) }
                        Button("Next 5 minutes") { startExport(300) }
                        Button("To end of this recording") { startExport(nil) }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.down").frame(width: 22, height: 18)
                }
                .menuStyle(.borderlessButton).fixedSize().foregroundStyle(.white)
                .help("Download a clip from the current position")
                .disabled(playback.current == nil)

                Menu {
                    ForEach([1.0, 2.0, 4.0, 8.0, 16.0, 32.0], id: \.self) { s in
                        Button("\(Int(s))×") { playback.setSpeed(s) }
                    }
                } label: {
                    Text("\(Int(playback.speed))×").font(.callout.monospacedDigit())
                }
                .menuStyle(.borderlessButton).fixedSize().foregroundStyle(.white)
                .help("Playback speed — 16× and 32× scan by keyframes; sound plays at 1× only")

                MuteButton(model: model)
            }
            DayTimeline(playback: playback)
                .frame(height: 30)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.black.opacity(0.6))
    }

    /// Opens a save dialog and exports `seconds` from the current position (nil = to the end of the recording).
    private func startExport(_ seconds: UInt32?) {
        guard let seg = playback.current else { return }
        let start = playback.position
        let duration = seconds ?? (seg.end > start ? seg.end - start : 0)
        guard duration > 0 else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "OpenV380 \(PlaybackController.timeString(start).replacingOccurrences(of: ":", with: "-")).mp4"
        if panel.runModal() == .OK, let url = panel.url {
            playback.exportClip(from: start, duration: duration, to: url)
        }
    }
}

/// Progress / result of a clip download, shown over the recordings view.
struct ExportOverlay: View {
    @ObservedObject var playback: PlaybackController

    var body: some View {
        VStack(spacing: 12) {
            switch playback.exportState {
            case .running(let p):
                ProgressView(value: p).frame(width: 240).tint(.white)
                Text("Saving clip… \(Int(p * 100))%").font(.callout).foregroundStyle(.white)
                Button("Cancel") { playback.cancelExport() }
            case .done(let url):
                Label("Clip saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.headline)
                Text(url.lastPathComponent).font(.caption).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]); playback.dismissExport() }
                    Button("Done") { playback.dismissExport() }.keyboardShortcut(.defaultAction)
                }
            case .failed(let message):
                Label("Couldn't save the clip", systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.headline)
                Text(message).font(.caption).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
                Button("OK") { playback.dismissExport() }.keyboardShortcut(.defaultAction)
            case .idle:
                EmptyView()
            }
        }
        .padding(22)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.45))
    }
}

enum SegmentColor {
    static func of(_ seg: RecordingSegment) -> Color {
        switch seg.kind {
        case .motion: return .orange
        case .alarm: return .red
        default: return Color(red: 0.35, green: 0.62, blue: 1.0)
        }
    }
}

struct DayNavigator: View {
    @ObservedObject var playback: PlaybackController

    var body: some View {
        HStack(spacing: 4) {
            IconButton(symbol: "chevron.left", help: "Previous day") { shift(-1) }
            DatePicker("", selection: Binding(get: { playback.day }, set: { playback.loadDay($0) }),
                       in: ...Date(), displayedComponents: .date)
                .labelsHidden().datePickerStyle(.field).frame(width: 110)
            IconButton(symbol: "chevron.right", help: "Next day") { shift(1) }
                .disabled(Calendar.current.isDateInToday(playback.day))
            IconButton(symbol: "arrow.clockwise", help: "Refresh list") { playback.reloadList() }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
    }

    private func shift(_ days: Int) {
        if let d = Calendar.current.date(byAdding: .day, value: days, to: playback.day) { playback.loadDay(d) }
    }
}

/// 24-hour strip of the day's recordings. Click or drag to play from that time.
struct DayTimeline: View {
    @ObservedObject var playback: PlaybackController
    @State private var hoverTime: UInt32?

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let dayStart = playback.dayStart
            let x: (UInt32) -> CGFloat = { t in CGFloat(Double(Int64(t) - Int64(dayStart)) / 86400) * w }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.12))
                    .frame(height: 14).offset(y: 2)

                ForEach(playback.segments) { seg in
                    Rectangle().fill(SegmentColor.of(seg))
                        .frame(width: max(1.5, x(seg.end) - x(seg.start)), height: 14)
                        .offset(x: x(seg.start), y: 2)
                }

                ForEach([0, 3, 6, 9, 12, 15, 18, 21], id: \.self) { h in
                    Text(String(format: "%02d", h))
                        .font(.system(size: 9).monospacedDigit()).foregroundStyle(.white.opacity(0.55))
                        .offset(x: CGFloat(h) / 24 * w + 2, y: 17)
                }

                if playback.current != nil {
                    Rectangle().fill(.white).frame(width: 2, height: 20)
                        .offset(x: x(playback.position) - 1, y: -1)
                }

                if let t = hoverTime {
                    Text(PlaybackController.timeString(t))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.white)
                        .padding(.horizontal, 4).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 3))
                        .offset(x: min(max(0, x(t) - 24), w - 52), y: -18)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hoverTime = time(at: p.x, width: w, dayStart: dayStart)
                case .ended: hoverTime = nil
                }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in hoverTime = time(at: v.location.x, width: w, dayStart: dayStart) }
                .onEnded { v in playback.play(at: time(at: v.location.x, width: w, dayStart: dayStart)) })
        }
    }

    private func time(at px: CGFloat, width: CGFloat, dayStart: UInt32) -> UInt32 {
        dayStart + UInt32(min(max(0, px / width), 0.99999) * 86400)
    }
}

struct SegmentList: View {
    @ObservedObject var playback: PlaybackController

    var body: some View {
        ScrollViewReader { proxy in
            List(playback.segments.reversed()) { seg in
                Button { playback.play(seg) } label: {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(SegmentColor.of(seg)).frame(width: 4, height: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(PlaybackController.timeString(seg.start)) – \(PlaybackController.timeString(seg.end))")
                                .font(.callout.monospacedDigit())
                            Text(Self.describe(seg)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(seg == playback.current ? Color.accentColor.opacity(0.35) : Color.clear)
                .id(seg.id)
            }
            .scrollContentBackground(.hidden)
            .background(.ultraThinMaterial.opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .padding(.leading, 10).padding(.bottom, 8)
            .onAppear { if let c = playback.current { proxy.scrollTo(c.id, anchor: .center) } }
        }
    }

    static func describe(_ seg: RecordingSegment) -> String {
        let minutes = Int(seg.duration) / 60, seconds = Int(seg.duration) % 60
        let length = minutes > 0 ? "\(minutes) min \(seconds) s" : "\(seconds) s"
        switch seg.kind {
        case .motion: return "Motion · \(length)"
        case .alarm: return "Alarm · \(length)"
        default: return length
        }
    }
}
