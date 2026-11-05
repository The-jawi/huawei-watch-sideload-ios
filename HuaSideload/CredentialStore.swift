import Foundation
import Security

// Secrets kept between launches: the HiChain pairing key of each watch and the optional Huawei account ID.
// They live in the Keychain (this device only; readable after the first unlock, so a background relaunch for the
// watch can still pair). Older builds kept them in UserDefaults: a value found there is copied to the Keychain on
// first read and removed from UserDefaults only after that write succeeded, so an upgrade never loses a pairing.
// If the Keychain refuses a write, the value stays in UserDefaults rather than being lost (losing the pairing key
// would mean pairing again from the PIN step).
protocol SecretBackend {
    func read(_ key: String) -> String?
    func write(_ value: String, for key: String) -> Bool
    func delete(_ key: String)
}

struct KeychainBackend: SecretBackend {
    var service = "HuaSideload"

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    func read(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String, for key: String) -> Bool {
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data,
                      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as [String: Any]
        let status = SecItemUpdate(query(key) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = query(key)
        add.merge(update) { $1 }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    func delete(_ key: String) {
        SecItemDelete(query(key) as CFDictionary)
    }
}

struct CredentialStore {
    let secure: SecretBackend
    let legacy: UserDefaults

    static let shared = CredentialStore(secure: KeychainBackend(), legacy: .standard)

    static func authTokenKey(_ watch: String) -> String { "authToken." + watch }
    static let huaweiAccountKey = "HuaSideloadHuaweiAccountId"

    func string(_ key: String) -> String? {
        if let value = secure.read(key) { return value }
        guard let old = legacy.string(forKey: key) else { return nil }
        if secure.write(old, for: key) { legacy.removeObject(forKey: key) }
        return old
    }

    func set(_ value: String?, for key: String) {
        guard let value, !value.isEmpty else {
            secure.delete(key)
            legacy.removeObject(forKey: key)
            return
        }
        if secure.write(value, for: key) {
            legacy.removeObject(forKey: key)
        } else {
            legacy.set(value, forKey: key)
        }
    }
}
