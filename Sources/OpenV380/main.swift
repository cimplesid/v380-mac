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
    private let model = AppModel(config: SettingsStore.load())
    private var sizeObserver: AnyCancellable?
    private var config: CameraConfig? {
        get { model.config }
        set { model.config = newValue }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "video.fill", accessibilityDescription: "OpenV380")
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        hotKey = HotKey(keyCode: kVK_ANSI_V, modifiers: controlKey | optionKey) { [weak self] in self?.toggleLive() }

        if config == nil { showSettings() }
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

    private func toggleLive() {
        if let panel, panel.isVisible { panel.close() } else { showLive() }
    }

    private func showLive() {
        guard config != nil else { showSettings(); return }
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
            onQualityChange: { [weak self] hd in
                self?.config?.hd = hd
                if let c = self?.config { try? SettingsStore.save(c) }
                self?.model.reconnect()
            },
            onPinChange: { [weak panel] pinned in panel?.level = pinned ? .floating : .normal },
            onSettings: { [weak self] in self?.showSettings() }
        ))
        panel.setFrameAutosaveName("OpenV380Live")
        if !panel.setFrameUsingName("OpenV380Live") {
            if let screen = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: screen.maxX - 660, y: screen.maxY - 380))
            }
        }
        // Match the window to the camera picture once its size is known.
        sizeObserver = model.live.$videoSize.compactMap { $0 }.removeDuplicates().sink { [weak panel] size in
            guard let panel, size.width > 0, size.height > 0 else { return }
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

    private func showSettings() {
        if let settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = config == nil ? "Set Up OpenV380" : "OpenV380 Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: SettingsView(config: config, onSave: { [weak self, weak window] newConfig in
            guard let self else { return }
            try SettingsStore.save(newConfig)
            self.config = newConfig
            window?.close()
            self.model.live.stop()
            self.showLive()
        }, onForget: { [weak self, weak window] in
            guard let self else { return }
            SettingsStore.delete()
            self.config = nil
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
