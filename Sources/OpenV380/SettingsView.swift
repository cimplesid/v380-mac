import ServiceManagement
import SwiftUI
import V380

/// Settings window: the camera list (add, edit, remove) and general options. With no cameras yet,
/// it is just the form for the first one.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var pane: Pane?
    /// Called after a camera is saved (the window closes and shows it).
    var onSaved: () -> Void
    /// Called when the last camera is removed.
    var onAllRemoved: () -> Void

    enum Pane: Hashable {
        case camera(UUID)
        case new
    }

    init(model: AppModel, addingCamera: Bool, onSaved: @escaping () -> Void, onAllRemoved: @escaping () -> Void) {
        self.model = model
        self.onSaved = onSaved
        self.onAllRemoved = onAllRemoved
        let current = model.selectedCamera ?? model.cameras.first
        _pane = State(initialValue: addingCamera ? .new : current.map { .camera($0.id) } ?? .new)
    }

    var body: some View {
        if model.cameras.isEmpty {
            CameraForm(camera: nil, others: [], isFirstRun: true, onSave: save, onRemove: nil)
                .frame(width: 440, height: 400)
        } else {
            TabView {
                camerasPane.tabItem { Text("Cameras") }
                GeneralSettings().tabItem { Text("General") }
            }
            .padding(12)
            .frame(width: 660, height: 470)
        }
    }

    private var camerasPane: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $pane) {
                    ForEach(model.cameras) { camera in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(camera.name)
                            Text(String(camera.config.deviceId)).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(Pane.camera(camera.id))
                    }
                    if pane == .new {
                        Text("New Camera").italic().tag(Pane.new)
                    }
                }
                Divider()
                HStack {
                    Button { pane = .new } label: {
                        Label("Add Camera", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }
                .padding(8)
            }
            .frame(width: 190)

            Divider()

            switch pane {
            case .camera(let id):
                if let camera = model.cameras.first(where: { $0.id == id }) {
                    CameraForm(camera: camera, others: model.cameras.filter { $0.id != id }, isFirstRun: false,
                               onSave: save, onRemove: { remove(id) })
                        .id(id)
                }
            case .new:
                CameraForm(camera: nil, others: model.cameras, isFirstRun: false, onSave: save, onRemove: nil)
                    .id("new")
            case nil:
                Text("Select a camera").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func save(_ camera: SavedCamera) throws {
        try model.save(camera)
        pane = .camera(camera.id)
        onSaved()
    }

    private func remove(_ id: UUID) {
        do {
            try model.remove(id)
        } catch {
            Diag.log("settings: remove failed: \(error.localizedDescription)")
            return
        }
        if model.cameras.isEmpty {
            onAllRemoved()
        } else {
            pane = model.cameras.first.map { .camera($0.id) }
        }
    }
}

/// Name and login for one camera, with Test / Save / Remove.
struct CameraForm: View {
    let camera: SavedCamera?
    /// The other saved cameras, to catch adding the same device twice.
    let others: [SavedCamera]
    let isFirstRun: Bool
    var onSave: (SavedCamera) throws -> Void
    var onRemove: (() -> Void)?

    @State private var name: String
    @State private var deviceId: String
    @State private var username: String
    @State private var password: String
    @State private var testResult: (ok: Bool, message: String)?
    @State private var testing = false
    @State private var confirmRemove = false

    init(camera: SavedCamera?, others: [SavedCamera], isFirstRun: Bool,
         onSave: @escaping (SavedCamera) throws -> Void, onRemove: (() -> Void)?) {
        self.camera = camera
        self.others = others
        self.isFirstRun = isFirstRun
        self.onSave = onSave
        self.onRemove = onRemove
        _name = State(initialValue: camera?.name ?? "")
        _deviceId = State(initialValue: camera.map { String($0.config.deviceId) } ?? "")
        _username = State(initialValue: camera?.config.username ?? "admin")
        _password = State(initialValue: camera?.config.password ?? "")
    }

    private var defaultName: String { "Camera \(others.count + 1)" }

    /// Builds a camera from the fields, or explains what is wrong.
    private func validated() -> Result<SavedCamera, ValidationError> {
        // Tolerate pasted labels or spaces, e.g. "ID: 1234 5678".
        let digits = deviceId.filter(\.isNumber)
        guard !digits.isEmpty else { return .failure("Enter the Device ID (numbers only).") }
        guard let id = UInt32(digits) else {
            return .failure(ValidationError("That Device ID is too long (\(digits.count) digits). Please double-check it in V380 Pro."))
        }
        if let duplicate = others.first(where: { $0.config.deviceId == id }) {
            return .failure(ValidationError("That camera is already added as “\(duplicate.name)”."))
        }
        guard !password.isEmpty else { return .failure("Enter the device password.") }
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        var config = camera?.config ?? CameraConfig(deviceId: id, password: password,
                                                    hd: UserDefaults.standard.object(forKey: "hd") as? Bool ?? true)
        config.deviceId = id
        config.username = user.isEmpty ? "admin" : user
        config.password = password
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(SavedCamera(id: camera?.id ?? UUID(), name: trimmed.isEmpty ? camera?.name ?? defaultName : trimmed,
                                    config: config))
    }

    struct ValidationError: Error, ExpressibleByStringLiteral {
        let message: String
        init(stringLiteral value: String) { message = value }
        init(_ value: String) { message = value }
    }

    var body: some View {
        Form {
            if isFirstRun {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Connect your camera").font(.headline)
                        Text("The details are stored in your Mac's Keychain. You can add more cameras later in Settings.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                TextField("Name", text: $name, prompt: Text(camera?.name ?? defaultName))
                TextField("Device ID", text: $deviceId, prompt: Text("From the V380 Pro app"))
                TextField("Username", text: $username)
                SecureField("Device password", text: $password)
            } footer: {
                Text("The Device ID is under the camera's name in V380 Pro. The password is the camera's own password, not your V380 account. OpenV380 connects through V380's cloud, so it works from anywhere. Saved in Keychain; only OpenV380 can read it without asking you.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                if testing { ProgressView().controlSize(.small) }
                if let r = testResult {
                    Label(r.message, systemImage: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(r.ok ? .green : .red).font(.callout)
                        .fixedSize(horizontal: false, vertical: true).lineLimit(3)
                }
                Spacer()
                if onRemove != nil {
                    Button("Remove Camera", role: .destructive) { confirmRemove = true }
                }
                Button("Test") { test() }.disabled(testing)
                Button(camera == nil ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove “\(camera?.name ?? "")”?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { onRemove?() }
        } message: {
            Text("Its login is deleted from this Mac. Recordings stay on the camera's SD card.")
        }
    }

    private func save() {
        Diag.log("settings: save tapped")
        switch validated() {
        case .failure(let e):
            Diag.log("settings: validation failed: \(e.message)")
            testResult = (false, e.message)
        case .success(let c):
            do {
                try onSave(c)
                Diag.log("settings: saved")
            } catch {
                Diag.log("settings: save failed: \(error.localizedDescription)")
                testResult = (false, error.localizedDescription)
            }
        }
    }

    private func test() {
        let c: CameraConfig
        switch validated() {
        case .failure(let e): testResult = (false, e.message); return
        case .success(let valid): c = valid.config
        }
        testing = true; testResult = nil
        DispatchQueue.global().async {
            let session = V380Session(config: c)
            session.log = { Diag.log("test \($0)") }
            let result: (Bool, String)
            do { try session.authenticateAnywhere(); result = (true, "Camera accepted the login") }
            catch { result = (false, "\(error)".capitalizedFirst) }
            Diag.log("test result: \(result.1)")
            DispatchQueue.main.async { testing = false; testResult = result }
        }
    }
}

struct GeneralSettings: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var cacheMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open OpenV380 at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
                LabeledContent("Show live view", value: "⌃⌥V")
                LabeledContent("Switch camera", value: "1–9, or 0 for all")
                Button(cacheMessage ?? "Clear Cached Data") { clearCache() }
            } footer: {
                Text("Live and recorded video stream into memory only — they never use disk storage. Clearing just removes the small system cache and the remembered relays; your camera logins are kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func clearCache() {
        let freed = SettingsStore.clearCache()
        let mb = ByteCountFormatter.string(fromByteCount: max(freed, 0), countStyle: .file)
        cacheMessage = "Cleared \(mb)"
    }
}
