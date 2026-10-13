import Foundation
import Security

enum KeychainStore {
    private static let service = "app.bandal.ipad.credentials"
    static func read(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func write(_ value: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        if value.isEmpty { SecItemDelete(query as CFDictionary); return }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            let status = SecItemAdd(query.merging(attributes, uniquingKeysWith: { _, b in b }) as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError.status(status) }
        } else if result != errSecSuccess { throw KeychainError.status(result) }
    }
    enum KeychainError: LocalizedError { case status(OSStatus); var errorDescription: String? { if case .status(let status) = self { return "비밀키 저장 실패 (\(status))" }; return nil } }
}
