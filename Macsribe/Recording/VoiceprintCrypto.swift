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

    /// File holding the raw 32-byte store key (0600). The Keychain isn't usable here: this is
    /// a self-signed, no-team local app, so the legacy Keychain re-prompts on every rebuild and
    /// the data-protection Keychain returns errSecMissingEntitlement (it needs a provisioning
    /// profile we can't supply). A user-only-readable key file under Application Support gives
    /// equivalent local protection for the at-rest voiceprint store without any access prompt.
    private static var keyFileURL: URL {
        AppPaths.speakersDirectory.appendingPathComponent(".store-key", isDirectory: false)
    }

    /// Fetch the store key, generating + storing it (0600) on first use.
    private static func keychainKey() throws -> SymmetricKey {
        if let data = try? Data(contentsOf: keyFileURL), data.count == 32 {
            return SymmetricKey(data: data)
        }
        purgeOldKeychainKeys()   // drop any prior Keychain-stored key (it caused the prompts)
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        AppPaths.ensureDirectory(keyFileURL.deletingLastPathComponent())
        try data.write(to: keyFileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFileURL.path)
        AppLog.log("Voiceprints: store key initialized (key file, 0600)", category: "model")
        return key
    }

    /// Best-effort removal of any previously Keychain-stored key (legacy + data-protection) so
    /// it stops prompting and doesn't linger.
    private static func purgeOldKeychainKeys() {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var dp = base
        dp[kSecUseDataProtectionKeychain as String] = true
        SecItemDelete(dp as CFDictionary)
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
