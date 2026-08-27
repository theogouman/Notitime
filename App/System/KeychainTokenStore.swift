import Foundation
import Security
import NotitimeCore

/// Les tokens vivent exclusivement dans le Keychain (principe III).
///
/// `kSecAttrAccessibleAfterFirstUnlock` est délibéré : la file d'envoi doit
/// pouvoir repartir après un redémarrage sans que l'utilisateur ait à intervenir,
/// tout en gardant les tokens chiffrés au repos (R-07).
struct KeychainTokenStore: TokenStore {

    enum Key: String {
        case access = "notion.accessToken"
        case refresh = "notion.refreshToken"
    }

    struct KeychainError: Error { let status: OSStatus }

    private let service: String

    init(service: String = "com.notitime.app") {
        self.service = service
    }

    func accessToken() async throws -> String? { try read(.access) }
    func refreshToken() async throws -> String? { try read(.refresh) }

    func store(accessToken: String, refreshToken: String) async throws {
        try write(.access, value: accessToken)
        try write(.refresh, value: refreshToken)
    }

    func clear() async throws {
        try delete(.access)
        try delete(.refresh)
    }

    // MARK: - Accès brut

    private func query(_ key: Key) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key.rawValue]
    }

    private func read(_ key: Key) throws -> String? {
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    private func write(_ key: Key, value: String) throws {
        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query(key)
            insert.merge(attributes) { current, _ in current }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
            return
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private func delete(_ key: Key) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}
