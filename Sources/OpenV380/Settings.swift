import Foundation
import Security
import V380

/// Camera settings (IP, device ID, username, password) live in one macOS Keychain item.
/// The item's access list trusts only the signed OpenV380 app; any other program reading it
/// triggers a macOS prompt that the user must approve.
enum SettingsStore {
    private static let service = "com.openv380.mac"
    private static let account = "camera"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> CameraConfig? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(CameraConfig.self, from: data)
    }

    static func save(_ config: CameraConfig) throws {
        let data = try JSONEncoder().encode(config)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "OpenV380 camera login"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            throw NSError(domain: "OpenV380", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Could not save to Keychain: \(message)"])
        }
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
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
        // Cached connection hints — dropping them just means a fresh relay lookup next connect.
        for key in ["v380.relay", "v380.endpoint", "v380.loginVariant"] {
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
