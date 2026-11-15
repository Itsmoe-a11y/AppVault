import Foundation
import CommonCrypto
import CryptoKit

public final class CryptoService {
    public static let shared = CryptoService()

    private init() {}

    // MARK: - Key Derivation (PBKDF2 SHA-256)
    public func deriveKey(password: String, salt: Data) -> SymmetricKey? {
        guard let passwordData = password.data(using: .utf8) else { return nil }
        var derivedKey = [UInt8](repeating: 0, count: 32) // 256 bits

        let result = passwordData.withUnsafeBytes { passBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passBytes.bindMemory(to: Int8.self).baseAddress,
                    passwordData.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    100_000, // 100k rounds
                    &derivedKey,
                    derivedKey.count
                )
            }
        }

        guard result == kCCSuccess else { return nil }
        return SymmetricKey(data: derivedKey)
    }

    // MARK: - AES-256-GCM Encryption
    public func encrypt(data: Data, password: String) throws -> Data {
        // 1. Generate 16 bytes random salt
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }

        // 2. Derive 256-bit key
        guard let key = deriveKey(password: password, salt: salt) else {
            throw NSError(domain: "AppVault.Crypto", code: 500, userInfo: [NSLocalizedDescriptionKey: "Key derivation failed."])
        }

        // 3. Encrypt with AES-GCM
        let sealedBox = try AES.GCM.seal(data, using: key)

        // 4. Output format: [16 bytes salt] + [12 bytes nonce] + [16 bytes tag] + [ciphertext]
        var combined = Data()
        combined.append(salt)
        combined.append(sealedBox.nonce.withUnsafeBytes { Data($0) })
        combined.append(sealedBox.tag)
        combined.append(sealedBox.ciphertext)

        return combined
    }

    // MARK: - AES-256-GCM Decryption
    public func decrypt(data: Data, password: String) throws -> Data {
        // Must contain at least salt(16) + nonce(12) + tag(16) = 44 bytes
        guard data.count >= 44 else {
            throw NSError(domain: "AppVault.Crypto", code: 400, userInfo: [NSLocalizedDescriptionKey: "Encrypted payload is corrupted or too short."])
        }

        let salt = data.subdata(in: 0..<16)
        let nonceData = data.subdata(in: 16..<28)
        let tag = data.subdata(in: 28..<44)
        let ciphertext = data.subdata(in: 44..<data.count)

        guard let key = deriveKey(password: password, salt: salt) else {
            throw NSError(domain: "AppVault.Crypto", code: 500, userInfo: [NSLocalizedDescriptionKey: "Key derivation failed."])
        }

        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)

        return try AES.GCM.open(sealedBox, using: key)
    }
}
