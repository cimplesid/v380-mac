import SwiftUI
import V380

/// Every camera's live view at once. Double-click a tile (or use its expand button) to open that camera.
struct LiveGrid: View {
    @ObservedObject var model: AppModel
    var topInset: CGFloat = 0
    var onPinChange: (Bool) -> Void
    var onSettings: () -> Void
    @AppStorage("pinned") private var pinned = true
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let cameras = model.cameras
            let columns = Self.columns(count: cameras.count, in: geo.size)
            let rows = max(1, Int((Double(cameras.count) / Double(columns)).rounded(.up)))
            let spacing: CGFloat = 2
            let tile = CGSize(width: (geo.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns),
                              height: (geo.size.height - spacing * CGFloat(rows - 1)) / CGFloat(rows))
            VStack(spacing: spacing) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: spacing) {
                        ForEach(cameras.indices.filter { $0 / columns == row }, id: \.self) { index in
                            let camera = cameras[index]
                            LiveTile(live: model.liveController(for: camera.id), name: camera.name) {
                                model.select(.camera(camera.id))
                            }
                            .frame(width: tile.width, height: tile.height)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.top, topInset + 8)
        .overlay(alignment: .bottomTrailing) {
            if hovering {
                HStack(spacing: 8) {
                    IconButton(symbol: pinned ? "pin.fill" : "pin", help: "Keep window on top") {
                        pinned.toggle(); onPinChange(pinned)
                    }
                    IconButton(symbol: "arrow.clockwise", help: "Reconnect all") { model.reconnect() }
                    IconButton(symbol: "gearshape", help: "Settings", action: onSettings)
                }
                .padding(6)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
                .padding(10)
                .transition(.opacity)
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }

    /// The column count that makes 16:9 tiles as large as possible in `size`.
    static func columns(count: Int, in size: CGSize) -> Int {
        guard count > 1, size.width > 0, size.height > 0 else { return 1 }
        var best = 1
        var bestWidth: CGFloat = 0
        for columns in 1...count {
            let rows = CGFloat((Double(count) / Double(columns)).rounded(.up))
            let width = min(size.width / CGFloat(columns), size.height / rows * 16 / 9)
            if width > bestWidth + 0.5 { bestWidth = width; best = columns }
        }
        return best
    }
}

/// One camera in the grid: its video, name, and connection state. Always silent.
struct LiveTile: View {
    @ObservedObject var live: LiveController
    let name: String
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.black
            VideoSurface(renderer: live.renderer)
                .opacity(live.state == .live ? 1 : 0.35)

            switch live.state {
            case .connecting(let message):
                VStack(spacing: 6) {
                    ProgressView().controlSize(.small).tint(.white)
                    Text(message).font(.caption).lineLimit(2)
                }
                .foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center).padding(8)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).lineLimit(3).foregroundStyle(.white)
                    .multilineTextAlignment(.center).padding(8)
            default:
                EmptyView()
            }

            // Catches double-clicks over the video, which would otherwise go to the zoom view.
            Color.clear.contentShape(Rectangle())
                .onTapGesture(count: 2, perform: onOpen)

            VStack {
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(live.state == .live ? Color.red : Color.gray).frame(width: 7, height: 7)
                    Text(name).font(.caption.weight(.semibold)).lineLimit(1)
                    if live.state == .live {
                        Text("\(live.fps) fps").font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer(minLength: 4)
                    if hovering {
                        Button(action: onOpen) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 18, height: 16)
                        }
                        .buttonStyle(.borderless)
                        .help("Open this camera")
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
            }
        }
        .clipped()
        .onHover { hovering = $0 }
        .onAppear { live.renderer.view.resetZoom() }
    }
}
