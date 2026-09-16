import Foundation
import Security

struct KeychainService {
    static let serviceName = "com.stockdeck.app.binance"

    /// Explicit ACL that always allows the current app bundle itself to read
    /// the item without a prompt, so credentials survive dev rebuilds that
    /// keep the same bundle ID. (macOS 26 launch-through-`open` relaunches can
    /// otherwise silently fail an implicit-ACL keychain read in an accessory /
    /// background app where the "Allow access" security prompt never appears.)
    static func makeSelfAccess() -> SecAccess? {
        var trustedApp: SecTrustedApplication?
        let createStatus = SecTrustedApplicationCreateFromPath(nil, &trustedApp)
        guard createStatus == errSecSuccess, let trustedApp else { return nil }
        var access: SecAccess?
        let accessStatus = SecAccessCreate(serviceName as CFString, [trustedApp] as CFArray, &access)
        return accessStatus == errSecSuccess ? access : nil
    }

    static func save(key: String, data: Data) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        if let access = makeSelfAccess() {
            query[kSecAttrAccess as String] = access
        }

        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func load(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        if status == errSecSuccess {
            return dataTypeRef as? Data
        }
        return nil
    }

    static func delete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func saveString(_ value: String, forKey key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        return save(key: key, data: data)
    }

    static func loadString(forKey key: String) -> String? {
        guard let data = load(key: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
