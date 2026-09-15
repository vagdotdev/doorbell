import Foundation
import Security
import Supabase

/// A missing Keychain item is normal on first launch. Other errors must propagate.
struct MigratingAuthStorage: AuthLocalStorage {
    let directory: URL
    let service: String

    init(directory: URL, profile: String) {
        self.directory = directory
        service = "dev.vag.doorbell.auth.\(profile)"
    }
    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: key]
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    private func legacyURL(_ key: String) -> URL {
        directory.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".json")
    }
    func store(key: String, value: Data) throws {
        var item = query(key)
        item[kSecValueData as String] = value
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            try check(SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: value] as CFDictionary))
        } else { try check(status) }
        // Never delete the old file until the Keychain write succeeds.
        try? FileManager.default.removeItem(at: legacyURL(key))
    }
    func retrieve(key: String) throws -> Data? {
        var item = query(key)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecSuccess { return result as? Data }
        if status != errSecItemNotFound { try check(status) }
        guard FileManager.default.fileExists(atPath: legacyURL(key).path) else { return nil }
        let value = try Data(contentsOf: legacyURL(key))
        try store(key: key, value: value)
        return value
    }
    func remove(key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
        if FileManager.default.fileExists(atPath: legacyURL(key).path) {
            try FileManager.default.removeItem(at: legacyURL(key))
        }
    }
}
