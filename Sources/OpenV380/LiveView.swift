import SwiftUI
import V380

/// Root of the camera window: live view or recordings, with the controls both share.
struct CameraView: View {
    @ObservedObject var model: AppModel
    var onQualityChange: (Bool) -> Void
    var onPinChange: (Bool) -> Void
    var onSettings: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
            switch model.mode {
            case .live:
                LiveView(live: model.live, model: model, onQualityChange: onQualityChange,
                         onPinChange: onPinChange, onSettings: onSettings)
            case .recordings:
                RecordingsView(playback: model.playback, model: model)
            }

            HStack {
                Spacer()
                Picker("", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                    Text("Live").tag(AppModel.Mode.live)
                    Text("Recordings").tag(AppModel.Mode.recordings)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 170)
            }
            .padding(.top, 8).padding(.trailing, 10)
        }
        .background(KeyCatcher { key in
            switch key {
            case "m": model.setMuted(!model.muted); return true
            case " " where model.mode == .recordings: model.playback.togglePause(); return true
            default: return false
            }
        })
    }
}

struct MuteButton: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Button { model.setMuted(!model.muted) } label: {
            Image(systemName: symbol).frame(width: 22, height: 18)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(model.audioUnavailable ? .white.opacity(0.4) : .white)
        .help(help)
    }

    private var symbol: String {
        if model.audioUnavailable { return "speaker.slash.fill" }
        return model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
    }

    private var help: String {
        if model.audioUnavailable { return "This camera isn't sending audio (its sound is off or encrypted)" }
        return model.muted ? "Unmute (M)" : "Mute (M)"
    }
}

struct LiveView: View {
    @ObservedObject var live: LiveController
    @ObservedObject var model: AppModel
    @AppStorage("hd") private var hd = true
    @AppStorage("pinned") private var pinned = true
    @State private var hovering = false

    var onQualityChange: (Bool) -> Void
    var onPinChange: (Bool) -> Void
    var onSettings: () -> Void
    @State private var zoom: CGFloat = 1
    @State private var torchOn = false
    @State private var showPTZ = false

    var body: some View {
        ZStack {
            VideoSurface(renderer: live.renderer, onZoom: { z in withAnimation(.easeOut(duration: 0.12)) { zoom = z } })
                .opacity(live.state == .live ? 1 : 0.35)

            switch live.state {
            case .connecting(let message):
                StatusMessage(spinner: true, text: message)
            case .failed(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
                    Text(message).foregroundStyle(.white).multilineTextAlignment(.center)
                    HStack {
                        Button("Settings…", action: onSettings)
                        Button("Try again") { model.reconnect() }
                    }
                }.padding()
            default:
                EmptyView()
            }

            VStack {
                HStack {
                    statusPill
                    ZoomBadge(zoom: zoom) { live.renderer.view.resetZoom() }
                    Spacer()
                }
                Spacer()
                HStack(alignment: .bottom) {
                    if showPTZ, live.state == .live {
                        PTZPad { live.ptz($0) }.transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                    Spacer()
                }
                HStack(spacing: 8) {
                    if hovering { controls.transition(.opacity) }
                    Spacer()
                    MuteButton(model: model)
                        .padding(6)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
                }
            }
            .padding(10)
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle().fill(live.state == .live ? Color.red : Color.gray).frame(width: 8, height: 8)
            Text(live.state == .live ? "LIVE" : "OFFLINE").font(.caption.weight(.bold))
            if live.state == .live {
                Text("\(live.detail) · \(live.fps) fps").font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(.black.opacity(0.55), in: Capsule())
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(get: { hd }, set: { hd = $0; onQualityChange($0) })) {
                Text("HD").tag(true)
                Text("SD").tag(false)
            }
            .pickerStyle(.segmented).frame(width: 90).labelsHidden()
            .help("HD is sharper; SD loads faster on weak Wi-Fi")

            Button {
                torchOn.toggle(); live.setTorch(torchOn)
            } label: {
                Image(systemName: torchOn ? "lightbulb.fill" : "lightbulb")
                    .frame(width: 22, height: 18)
                    .foregroundStyle(torchOn ? .yellow : .white)
            }
            .buttonStyle(.borderless)
            .help("Toggle the camera's light")
            .disabled(live.state != .live)

            Button {
                withAnimation(.easeOut(duration: 0.15)) { showPTZ.toggle() }
            } label: {
                Image(systemName: "dpad").frame(width: 22, height: 18)
                    .foregroundStyle(showPTZ ? .yellow : .white)
            }
            .buttonStyle(.borderless)
            .help("Move the camera (pan/tilt)")
            .disabled(live.state != .live)

            IconButton(symbol: pinned ? "pin.fill" : "pin", help: "Keep window on top") {
                pinned.toggle(); onPinChange(pinned)
            }
            IconButton(symbol: "arrow.clockwise", help: "Reconnect") { model.reconnect() }
            IconButton(symbol: "gearshape", help: "Settings", action: onSettings)
        }
        .padding(6)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
    }
}

/// Directional pad for pan/tilt. Press and hold an arrow to move; release to stop.
struct PTZPad: View {
    let onMove: (V380Session.PTZ?) -> Void

    var body: some View {
        VStack(spacing: 4) {
            arrow(.up, "chevron.up")
            HStack(spacing: 4) {
                arrow(.left, "chevron.left")
                Image(systemName: "video.fill").font(.caption)
                    .frame(width: 40, height: 40).foregroundStyle(.white.opacity(0.4))
                arrow(.right, "chevron.right")
            }
            arrow(.down, "chevron.down")
        }
        .padding(8)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func arrow(_ direction: V380Session.PTZ, _ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.body.weight(.bold))
            .frame(width: 40, height: 40)
            .background(.white.opacity(0.15), in: Circle())
            .foregroundStyle(.white)
            .contentShape(Circle())
            // pressing==true on press-down, false on release — hold to move, release to stop.
            .onLongPressGesture(minimumDuration: 0.01, maximumDistance: 60,
                                pressing: { onMove($0 ? direction : nil) }, perform: {})
    }
}

/// Small "2.0×" pill with a reset button, shown while the video is zoomed in.
struct ZoomBadge: View {
    let zoom: CGFloat
    let onReset: () -> Void

    var body: some View {
        if zoom > 1.01 {
            Button(action: onReset) {
                HStack(spacing: 4) {
                    Text(String(format: "%.1f×", zoom)).font(.caption.monospacedDigit().weight(.semibold))
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption2)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.black.opacity(0.55), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Reset zoom (or double-click the video)")
            .transition(.opacity)
        }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 22, height: 18)
        }
        .buttonStyle(.borderless).foregroundStyle(.white).help(help)
    }
}

struct StatusMessage: View {
    var spinner = false
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            if spinner { ProgressView().controlSize(.large).tint(.white) }
            Text(text).font(.callout).foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center).padding(.horizontal)
        }
    }
}

/// Window-level key shortcuts without stealing focus from text fields.
struct KeyCatcher: NSViewRepresentable {
    let handler: (String) -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === view.window, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  !(event.window?.firstResponder is NSTextView),
                  let chars = event.charactersIgnoringModifiers?.lowercased() else { return event }
            return handler(chars) ? nil : event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var monitor: Any?
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
