import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI
import V380

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel?
    private var settingsWindow: NSWindow?
    private var hotKey: HotKey?
    private let model = AppModel(cameras: SettingsStore.loadCameras())
    private var sizeObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "video.fill", accessibilityDescription: "OpenV380")
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        hotKey = HotKey(keyCode: kVK_ANSI_V, modifiers: controlKey | optionKey) { [weak self] in self?.toggleLive() }

        if !model.hasCameras { showSettings() }
        let args = CommandLine.arguments
        if args.contains("--recordings") { model.setMode(.recordings) }
        if args.contains("--open") || args.contains("--recordings") { showLive() }
    }

    @objc private func statusClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            let menu = NSMenu()
            menu.addItem(withTitle: "Show Live View", action: #selector(showLiveAction), keyEquivalent: "")
            menu.addItem(withTitle: "Show Recordings", action: #selector(showRecordingsAction), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Add Camera…", action: #selector(addCameraAction), keyEquivalent: "")
            menu.addItem(withTitle: "Settings…", action: #selector(showSettingsAction), keyEquivalent: ",")
            menu.addItem(withTitle: "Quit OpenV380", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            menu.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            toggleLive()
        }
    }

    @objc private func showLiveAction() { model.setMode(.live); showLive() }
    @objc private func showRecordingsAction() { model.setMode(.recordings); showLive() }
    @objc private func showSettingsAction() { showSettings() }
    @objc private func addCameraAction() { showSettings(addingCamera: true) }

    private func toggleLive() {
        if let panel, panel.isVisible { panel.close() } else { showLive() }
    }

    private func showLive() {
        guard model.hasCameras else { showSettings(); return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        model.windowOpened()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = "OpenV380"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.level = UserDefaults.standard.object(forKey: "pinned") as? Bool ?? true ? .floating : .normal
        panel.contentAspectRatio = NSSize(width: 16, height: 9)
        panel.minSize = NSSize(width: 420, height: 320)
        panel.backgroundColor = .black
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: CameraView(
            model: model,
            onPinChange: { [weak panel] pinned in panel?.level = pinned ? .floating : .normal },
            onSettings: { [weak self] in self?.showSettings() }
        ))
        panel.setFrameAutosaveName("OpenV380Live")
        if !panel.setFrameUsingName("OpenV380Live") {
            if let screen = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: screen.maxX - 660, y: screen.maxY - 380))
            }
        }
        // Match the window to the camera picture once its size is known; the grid fits any window shape (nil).
        sizeObserver = model.$selection
            .map { [weak self] selection -> AnyPublisher<CGSize?, Never> in
                guard case .camera(let id) = selection, let self else { return Just(nil).eraseToAnyPublisher() }
                return self.model.liveController(for: id).$videoSize.compactMap { $0 }.map(Optional.some).eraseToAnyPublisher()
            }
            .switchToLatest()
            .removeDuplicates()
            .sink { [weak panel] size in
                guard let panel else { return }
                guard let size else {
                    panel.contentResizeIncrements = NSSize(width: 1, height: 1) // clears the aspect-ratio lock
                    return
                }
                guard size.width > 0, size.height > 0 else { return }
                panel.contentAspectRatio = size
                let content = panel.contentRect(forFrameRect: panel.frame)
                let wanted = content.width * size.height / size.width
                if abs(wanted - content.height) > 2 {
                    var frame = panel.frameRect(forContentRect: NSRect(x: content.minX, y: content.maxY - wanted,
                                                                       width: content.width, height: wanted))
                    if let screen = panel.screen?.visibleFrame, frame.height > screen.height {
                        let scale = screen.height / frame.height
                        frame.size = NSSize(width: frame.width * scale, height: frame.height * scale)
                    }
                    panel.setFrame(frame, display: true, animate: false)
                }
            }
        return panel
    }

    func windowWillClose(_ notification: Notification) {
        // Closing the live window drops the connection so the camera's Wi-Fi is not kept busy.
        if (notification.object as? NSWindow) === panel { model.windowClosed() }
        // Rebuild settings each time so it always shows the saved values.
        if (notification.object as? NSWindow) === settingsWindow { settingsWindow = nil }
    }

    private func showSettings(addingCamera: Bool = false) {
        if let settingsWindow {
            // Reopen fresh so it lands on the new-camera form.
            guard addingCamera else {
                NSApp.activate(ignoringOtherApps: true)
                settingsWindow.makeKeyAndOrderFront(nil)
                return
            }
            settingsWindow.close()
        }
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = model.hasCameras ? "OpenV380 Settings" : "Set Up OpenV380"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: SettingsView(model: model, addingCamera: addingCamera, onSaved: { [weak self, weak window] in
            window?.close()
            self?.showLive()
        }, onAllRemoved: { [weak self, weak window] in
            guard let self else { return }
            self.panel?.close()
            window?.close()
            DispatchQueue.main.async { self.showSettings() }
        }))
        if let hosting = window.contentView { window.setContentSize(hosting.fittingSize) }
        window.center()
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
