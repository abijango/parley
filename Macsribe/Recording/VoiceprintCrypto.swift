import Foundation
import CryptoKit
import Security

/// Encryption for the voiceprint store — biometric data must not sit in plaintext.
///
/// At rest, the store is sealed with AES-GCM under a 256-bit key kept in the
/// Keychain (generated once per machine). For sharing/backup, an export can instead
/// be wrapped with a user passphrase (HKDF-derived key + random salt).
enum VoiceprintCrypto {
    private static let service = "com.naufalmir.macsribe.voiceprints"   // TODO(app-name)
    private static let account = "store-key-v1"

    // MARK: At-rest (Keychain key)

    static func encrypt(_ plaintext: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(plaintext, using: keychainKey()).combined else {
            throw CryptoError.sealFailed
        }
        return combined
    }

    static func decrypt(_ ciphertext: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: keychainKey())
    }

    /// Fetch the store key from the Keychain, generating + storing it on first use.
    private static func keychainKey() throws -> SymmetricKey {
        if let data = readKeychain() { return SymmetricKey(data: data) }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try writeKeychain(data)
        return key
    }

    private static func readKeychain() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func writeKeychain(_ data: Data) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw CryptoError.keychain(status) }
    }

    // MARK: Passphrase-wrapped (export/import)

    /// Seal `plaintext` with a key derived from `passphrase`. Output = salt (16B) + sealed box.
    static func encrypt(_ plaintext: Data, passphrase: String) throws -> Data {
        var salt = Data(count: 16)
        let result = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard result == errSecSuccess else { throw CryptoError.randomFailed }
        let key = deriveKey(passphrase: passphrase, salt: salt)
        guard let combined = try AES.GCM.seal(plaintext, using: key).combined else { throw CryptoError.sealFailed }
        return salt + combined
    }

    static func decrypt(_ blob: Data, passphrase: String) throws -> Data {
        guard blob.count > 16 else { throw CryptoError.malformed }
        let salt = blob.prefix(16)
        let sealed = blob.dropFirst(16)
        let key = deriveKey(passphrase: passphrase, salt: salt)
        return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key)
    }

    private static func deriveKey(passphrase: String, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(passphrase.utf8)),
            salt: salt, info: Data("macsribe.voiceprints".utf8), outputByteCount: 32)
    }

    enum CryptoError: Error { case sealFailed, malformed, randomFailed, keychain(OSStatus) }
}
