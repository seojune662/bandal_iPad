import CryptoKit
import Foundation
import Security

/// The original registry still owns its atomic encrypted file and schema. Its
/// encryption key is device-only Keychain data, never a JSCore or renderer value.
final class DesktopMCPVault {
    struct Storage {
        var read: (String) throws -> Data?
        var write: (String, Data) throws -> Void
        static let live = Storage(read: { account in
            var query = DesktopCredentialsService.keychainQuery("mcp-vault:" + account)
            query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
            var value: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &value)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = value as? Data else { throw DesktopRuntimeError("MCP 보안 저장소를 열지 못했습니다.") }; return data
        }, write: { account, value in
            var query = DesktopCredentialsService.keychainQuery("mcp-vault:" + account)
            query[kSecValueData as String] = value
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            // Add-only: a concurrent initializer must never replace a key used
            // to encrypt an existing registry.
            let status = SecItemAdd(query as CFDictionary, nil)
            guard status == errSecSuccess || status == errSecDuplicateItem else { throw DesktopRuntimeError("MCP 보안 키를 저장하지 못했습니다.") }
        })
    }
    private let namespace: String
    private let storage: Storage
    private let lock = NSLock()
    init(namespace: String, storage: Storage = .live) { self.namespace = namespace; self.storage = storage }
    private func key(create: Bool) throws -> SymmetricKey {
        lock.lock(); defer { lock.unlock() }
        if let data = try storage.read(namespace) {
            guard data.count == 32 else { throw DesktopRuntimeError("MCP 보안 키 형식이 올바르지 않습니다. 기존 데이터는 보존했습니다.") }; return SymmetricKey(data: data)
        }
        guard create else { throw DesktopRuntimeError("MCP 보안 키를 찾지 못했습니다. 기존 데이터는 보존했습니다.") }
        let generated = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try storage.write(namespace, generated)
        guard let stored = try storage.read(namespace), stored.count == 32 else { throw DesktopRuntimeError("MCP 보안 키 저장을 확인하지 못했습니다.") }
        return SymmetricKey(data: stored)
    }
    func available() -> Bool { do { _ = try key(create: true); return true } catch { return false } }
    func encrypt(_ plaintext: String) throws -> String {
        let data = Data(plaintext.utf8)
        guard data.count <= 2 * 1024 * 1024 else { throw DesktopRuntimeError("MCP 설정 저장 한도를 초과했습니다.") }
        guard let sealed = try AES.GCM.seal(data, using: key(create: true), authenticating: Data(namespace.utf8)).combined else { throw DesktopRuntimeError("MCP 설정을 암호화하지 못했습니다.") }; return sealed.base64EncodedString()
    }
    func decrypt(_ ciphertext: String) throws -> String {
        guard ciphertext.utf8.count <= 3 * 1024 * 1024, let bytes = Data(base64Encoded: ciphertext) else { throw DesktopRuntimeError("MCP 암호화 데이터를 확인해 주세요.") }
        do {
            let data = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key(create: false), authenticating: Data(namespace.utf8))
            guard let value = String(data: data, encoding: .utf8) else { throw DesktopRuntimeError("MCP 설정을 읽지 못했습니다.") }; return value
        } catch { throw DesktopRuntimeError("MCP 설정을 복호화하지 못했습니다. 기존 데이터는 보존했습니다.") }
    }
}
