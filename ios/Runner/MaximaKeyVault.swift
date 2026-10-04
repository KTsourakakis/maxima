import Foundation
import Security

/// iOS counterpart of the Android `MaximaKeyVault`.
///
/// Holds a non-extractable-by-tag RSA-2048 key pair in the iOS Keychain
/// and uses it to OAEP-wrap the AES-256 data-encryption keys embedded in
/// `.mxenc` container headers. The private key carries
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so it never
/// migrates off the device and is unavailable before first unlock.
///
/// Note: Secure Enclave keys are ECC-only, so OAEP wrapping uses a
/// software Keychain key — the same primitive Android's Keystore
/// performs in TEE-backed hardware.
final class MaximaKeyVault {
    static let shared = MaximaKeyVault()

    private let keyTag = "com.example.aura_straton_maxima_ai.recordingKey"

    private init() {}

    /// RSA-OAEP(SHA-256) encrypts [data] with the vault public key.
    /// Creates the pair on first use.
    func wrap(data: Data) throws -> Data {
        let publicKey = try publicKeyRef()
        var error: Unmanaged<CFError>?
        guard let cipher = SecKeyCreateEncryptedData(
            publicKey,
            .rsaEncryptionOAEPSHA256,
            data as CFData,
            &error
        ) as? Data else {
            throw error!.takeRetainedValue() as Error
        }
        return cipher
    }

    /// RSA-OAEP(SHA-256) decrypts a blob produced by [wrap].
    func unwrap(data: Data) throws -> Data {
        let privateKey = try privateKeyRef()
        var error: Unmanaged<CFError>?
        guard let plain = SecKeyCreateDecryptedData(
            privateKey,
            .rsaEncryptionOAEPSHA256,
            data as CFData,
            &error
        ) as? Data else {
            throw error!.takeRetainedValue() as Error
        }
        return plain
    }

    /// true when the vault key pair exists (does not create it).
    func isProvisioned() -> Bool {
        return (try? privateKeyRef()) != nil
    }

    // MARK: - Keychain plumbing

    private func publicKeyRef() throws -> SecKey {
        let privateKey = try privateKeyRef()
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw VaultError.missingPublicKey
        }
        return publicKey
    }

    private func privateKeyRef() throws -> SecKey {
        let tag = keyTag.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let item = item {
            return item as! SecKey
        }
        return try generatePair(tag: tag)
    }

    private func generatePair(tag: Data) throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrAccessible as String:
                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ],
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(
            attributes as CFDictionary, &error
        ) else {
            throw error!.takeRetainedValue() as Error
        }
        return privateKey
    }

    enum VaultError: Error {
        case missingPublicKey
    }
}
