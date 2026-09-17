import Foundation
import Security
import V380

/// A camera the user has added. The id only exists on this Mac.
struct SavedCamera: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var config: CameraConfig
}

/// Camera logins (name, device ID, username, password) live in one macOS Keychain item.
/// The item's access list trusts only the signed OpenV380 app; any other program reading it
/// triggers a macOS prompt that the user must approve.
enum SettingsStore {
    private static let service = "com.openv380.mac"
    private static let account = "cameras"
    /// Before multi-camera support: a single CameraConfig.
    private static let legacyAccount = "camera"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func read(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    static func loadCameras() -> [SavedCamera] {
        if let data = read(account) {
            return (try? JSONDecoder().decode([SavedCamera].self, from: data)) ?? []
        }
        // Carry the single camera from earlier versions over to the list.
        guard let data = read(legacyAccount), let config = try? JSONDecoder().decode(CameraConfig.self, from: data) else {
            return []
        }
        let cameras = [SavedCamera(name: "Camera 1", config: config)]
        if (try? saveCameras(cameras)) != nil { SecItemDelete(query(legacyAccount) as CFDictionary) }
        return cameras
    }

    static func saveCameras(_ cameras: [SavedCamera]) throws {
        guard !cameras.isEmpty else { deleteAll(); return }
        let data = try JSONEncoder().encode(cameras)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query(account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(account)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "OpenV380 camera logins"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            throw NSError(domain: "OpenV380", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Could not save to Keychain: \(message)"])
        }
    }

    static func deleteAll() {
        SecItemDelete(query(account) as CFDictionary)
        SecItemDelete(query(legacyAccount) as CFDictionary)
    }

    /// OpenV380 never writes video to disk — recordings stream into memory. This only clears the
    /// tiny system cache folder and the remembered connection hints (relay, login variant).
    /// The camera login and preferences are kept. Returns roughly how many bytes were freed.
    @discardableResult
    static func clearCache() -> Int64 {
        var freed: Int64 = 0
        let fm = FileManager.default
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent(service) {
            freed += directorySize(caches)
            try? fm.removeItem(at: caches)
        }
        // Cached connection hints (global and per device) — dropping them just means a fresh relay lookup next connect.
        for key in UserDefaults.standard.dictionaryRepresentation().keys
        where ["v380.relay", "v380.endpoint", "v380.loginVariant"].contains(where: { key.hasPrefix($0) }) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        return freed
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}
