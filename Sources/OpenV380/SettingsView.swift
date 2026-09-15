import ServiceManagement
import SwiftUI
import V380

struct SettingsView: View {
    @State private var deviceId: String
    @State private var username: String
    @State private var password: String
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var testResult: (ok: Bool, message: String)?
    @State private var testing = false
    @State private var cacheMessage: String?

    private let isFirstRun: Bool
    var onSave: (CameraConfig) throws -> Void
    var onForget: () -> Void

    init(config: CameraConfig?, onSave: @escaping (CameraConfig) throws -> Void, onForget: @escaping () -> Void) {
        _deviceId = State(initialValue: config.map { String($0.deviceId) } ?? "")
        _username = State(initialValue: config?.username ?? "admin")
        _password = State(initialValue: config?.password ?? "")
        isFirstRun = config == nil
        self.onSave = onSave
        self.onForget = onForget
    }

    /// Builds a config from the fields, or explains what is wrong.
    private func validated() -> Result<CameraConfig, ValidationError> {
        // Tolerate pasted labels or spaces, e.g. "ID: 1234 5678".
        let digits = deviceId.filter(\.isNumber)
        guard !digits.isEmpty else { return .failure("Enter the Device ID (numbers only).") }
        guard let id = UInt32(digits) else {
            return .failure(ValidationError("That Device ID is too long (\(digits.count) digits). Please double-check it in V380 Pro."))
        }
        guard !password.isEmpty else { return .failure("Enter the device password.") }
        let hd = UserDefaults.standard.object(forKey: "hd") as? Bool ?? true
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(CameraConfig(deviceId: id, username: user.isEmpty ? "admin" : user,
                                     password: password, hd: hd))
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
                        Text("You only do this once. The details are stored in your Mac's Keychain.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                TextField("Device ID", text: $deviceId, prompt: Text("From the V380 Pro app"))
                TextField("Username", text: $username)
                SecureField("Device password", text: $password)
            } footer: {
                Text("The Device ID is under the camera's name in V380 Pro. The password is the camera's own password, not your V380 account. OpenV380 connects through V380's cloud, so it works from anywhere. Saved in Keychain; only OpenV380 can read it without asking you.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Open OpenV380 at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
                LabeledContent("Show live view", value: "⌃⌥V")
                Button(cacheMessage ?? "Clear Cached Data") { clearCache() }
            } footer: {
                Text("Live and recorded video stream into memory only — they never use disk storage. Clearing just removes the small system cache and the remembered relay; your camera login is kept.")
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
                if !isFirstRun {
                    Button("Forget Camera", role: .destructive, action: onForget)
                }
                Button("Test") { test() }.disabled(testing)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        // A grouped Form scrolls, so it has no natural height; give the window a real size.
        .frame(width: 440, height: isFirstRun ? 470 : 390)
    }

    private func clearCache() {
        let freed = SettingsStore.clearCache()
        let mb = ByteCountFormatter.string(fromByteCount: max(freed, 0), countStyle: .file)
        cacheMessage = "Cleared \(mb)"
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
        case .success(let valid): c = valid
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
