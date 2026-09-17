import Foundation
import V380

/// Shared state for the camera window: which cameras exist, which tab is showing, the mode, and whether sound is on.
final class AppModel: ObservableObject {
    enum Mode: String { case live, recordings }

    /// A single camera, or every camera's live view at once.
    enum Selection: Hashable {
        case camera(UUID)
        case grid
    }

    @Published private(set) var mode: Mode = .live
    @Published private(set) var cameras: [SavedCamera]
    @Published private(set) var selection: Selection = .grid
    @Published private(set) var muted = true
    /// True once we've determined this camera's audio can't be decoded (encrypted) for the current mode.
    @Published private(set) var audioUnavailable = false

    let playback = PlaybackController()
    private var liveControllers: [UUID: LiveController] = [:]
    private var windowOpen = false

    private static let selectionKey = "selectedCamera"

    init(cameras: [SavedCamera]) {
        self.cameras = cameras
        playback.audio.onNoiseDetected = { [weak self] in
            guard self?.mode == .recordings else { return }
            self?.audioUnavailable = true
        }
        let saved = UserDefaults.standard.string(forKey: Self.selectionKey)
        if saved == "grid", cameras.count > 1 {
            selection = .grid
        } else if let id = saved.flatMap(UUID.init(uuidString:)), cameras.contains(where: { $0.id == id }) {
            selection = .camera(id)
        } else {
            selection = cameras.first.map { .camera($0.id) } ?? .grid
        }
        updatePlaybackCamera()
    }

    var hasCameras: Bool { !cameras.isEmpty }

    var selectedCamera: SavedCamera? {
        guard case .camera(let id) = selection else { return nil }
        return cameras.first { $0.id == id }
    }

    /// The live stream for one camera; created on first use.
    func liveController(for id: UUID) -> LiveController {
        if let existing = liveControllers[id] { return existing }
        let controller = LiveController() // starts muted
        if !muted, selection == .camera(id) { controller.setMuted(false) }
        controller.audio.onNoiseDetected = { [weak self] in
            guard let self, self.mode == .live, self.selection == .camera(id) else { return }
            self.audioUnavailable = true
        }
        liveControllers[id] = controller
        return controller
    }

    /// The live stream of the camera on screen (nil on the grid).
    var selectedLive: LiveController? { selectedCamera.map { liveController(for: $0.id) } }

    func select(_ newSelection: Selection) {
        switch newSelection {
        case .grid: guard mode == .live, cameras.count > 1 else { return }
        case .camera(let id): guard cameras.contains(where: { $0.id == id }) else { return }
        }
        guard newSelection != selection else { return }
        setSelection(newSelection)
        refreshStreams()
    }

    private func setSelection(_ newSelection: Selection) {
        selection = newSelection
        audioUnavailable = false
        switch newSelection {
        case .grid: UserDefaults.standard.set("grid", forKey: Self.selectionKey)
        case .camera(let id): UserDefaults.standard.set(id.uuidString, forKey: Self.selectionKey)
        }
        updatePlaybackCamera()
        applyMute()
    }

    /// Only one kind of stream at a time, so the cameras' Wi-Fi is not split between live and playback.
    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        // Recordings belong to one camera; leave the grid for the first one.
        if newMode == .recordings, selection == .grid, let first = cameras.first {
            setSelection(.camera(first.id))
        }
        audioUnavailable = false
        switch newMode {
        case .live:
            playback.stop()
        case .recordings:
            if windowOpen, playback.segments.isEmpty, playback.listState == .idle { playback.reloadList() }
        }
        refreshStreams()
    }

    func setMuted(_ value: Bool) {
        muted = value
        applyMute()
        playback.audio.muted = value
    }

    /// Only the camera on screen plays sound; the grid is silent.
    private func applyMute() {
        for (id, controller) in liveControllers {
            controller.setMuted(muted || selection != .camera(id))
        }
    }

    func windowOpened() {
        windowOpen = true
        if mode == .recordings, playback.segments.isEmpty, playback.listState == .idle { playback.reloadList() }
        refreshStreams()
    }

    /// Closing the window drops every connection and returns to muted.
    func windowClosed() {
        windowOpen = false
        liveControllers.values.forEach { $0.stop() }
        playback.stop()
        setMuted(true)
    }

    func reconnect() {
        switch mode {
        case .live:
            for camera in visibleLiveCameras {
                liveController(for: camera.id).start(streamConfig(for: camera))
            }
        case .recordings:
            playback.reloadList()
        }
    }

    /// Switches the camera on screen between HD and SD, and remembers it for that camera.
    func setHD(_ hd: Bool) {
        guard var camera = selectedCamera, camera.config.hd != hd else { return }
        camera.config.hd = hd
        UserDefaults.standard.set(hd, forKey: "hd") // default for cameras added later
        try? save(camera)
    }

    // MARK: - Adding, editing, removing cameras

    /// Adds or updates a camera and shows it.
    func save(_ camera: SavedCamera) throws {
        var updated = cameras
        if let index = updated.firstIndex(where: { $0.id == camera.id }) {
            updated[index] = camera
        } else {
            updated.append(camera)
        }
        try SettingsStore.saveCameras(updated)
        cameras = updated
        updatePlaybackCamera()
        if selection != .camera(camera.id) { setSelection(.camera(camera.id)) }
        refreshStreams()
    }

    func remove(_ id: UUID) throws {
        let updated = cameras.filter { $0.id != id }
        try SettingsStore.saveCameras(updated)
        cameras = updated
        liveControllers.removeValue(forKey: id)?.stop()
        if selection == .camera(id) || (selection == .grid && updated.count < 2) {
            setSelection(updated.first.map { .camera($0.id) } ?? .grid)
        } else {
            updatePlaybackCamera()
        }
        refreshStreams()
    }

    // MARK: - Streams

    private var visibleLiveCameras: [SavedCamera] {
        guard windowOpen, mode == .live else { return [] }
        if selection == .grid { return cameras }
        return selectedCamera.map { [$0] } ?? []
    }

    /// Grid tiles are small, so they use the lighter SD stream.
    private func streamConfig(for camera: SavedCamera) -> CameraConfig {
        var config = camera.config
        if selection == .grid { config.hd = false }
        return config
    }

    /// Starts the streams on screen and stops the rest.
    private func refreshStreams() {
        let visible = visibleLiveCameras
        for (id, controller) in liveControllers
        where controller.activeConfig != nil && !visible.contains(where: { $0.id == id }) {
            controller.stop()
        }
        for camera in visible {
            let controller = liveController(for: camera.id)
            let wanted = streamConfig(for: camera)
            if controller.activeConfig != wanted { controller.start(wanted) }
        }
    }

    private func updatePlaybackCamera() {
        let camera = selectedCamera ?? cameras.first
        playback.fileLabel = cameras.count > 1 ? camera?.name : nil
        playback.setCamera(camera?.config)
        if windowOpen, mode == .recordings, playback.segments.isEmpty, playback.listState == .idle {
            playback.reloadList()
        }
    }
}
