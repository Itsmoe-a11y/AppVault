import Foundation
import CommonCrypto
import CryptoKit

public enum CryptoError: LocalizedError {
    case emptyPassword
    case saltGenerationFailed
    case invalidSalt
    case keyDerivationFailed
    case payloadTooShort
    case authenticationFailure(String)
    case generalError(String)

    public var errorDescription: String? {
        switch self {
        case .emptyPassword:
            return "Encryption password cannot be empty."
        case .saltGenerationFailed:
            return "Failed to generate cryptographically secure random salt."
        case .invalidSalt:
            return "Salt size is invalid (must be at least 16 bytes)."
        case .keyDerivationFailed:
            return "PBKDF2 key derivation failed."
        case .payloadTooShort:
            return "Encrypted payload is corrupted or too short (minimum 44 bytes required)."
        case .authenticationFailure(let reason):
            return "Decryption authentication failed. \(reason)"
        case .generalError(let message):
            return message
        }
    }
}

public final class CryptoService {
    public static let shared = CryptoService()

    public static let saltLength: Int = 16
    public static let nonceLength: Int = 12
    public static let tagLength: Int = 16
    public static let pbkdf2Rounds: UInt32 = 100_000

    private init() {}

    // MARK: - Key Derivation (PBKDF2 SHA-256)
    public func deriveKey(password: String, salt: Data, rounds: UInt32 = pbkdf2Rounds) -> SymmetricKey? {
        guard !password.isEmpty else { return nil }
        guard salt.count >= Self.saltLength else { return nil }
        guard let passwordData = password.data(using: .utf8) else { return nil }

        var derivedKey = [UInt8](repeating: 0, count: 32) // 256 bits

        let result = passwordData.withUnsafeBytes { passBytes -> Int32 in
            salt.withUnsafeBytes { saltBytes -> Int32 in
                guard let passPtr = passBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                      let saltPtr = saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return -1
                }

                return CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passPtr,
                    passwordData.count,
                    saltPtr,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    rounds,
                    &derivedKey,
                    derivedKey.count
                )
            }
        }

        guard result == kCCSuccess else { return nil }

        let key = SymmetricKey(data: derivedKey)

        // Secure memory erasure of raw key buffer
        derivedKey.withUnsafeMutableBytes { rawBytes in
            if let addr = rawBytes.baseAddress {
                memset_s(addr, rawBytes.count, 0, rawBytes.count)
            }
        }

        return key
    }

    // MARK: - AES-256-GCM Encryption
    public func encrypt(data: Data, password: String) throws -> Data {
        guard !password.isEmpty else {
            throw CryptoError.emptyPassword
        }

        // 1. Generate 16 bytes of cryptographically secure random salt (CSPRNG)
        var salt = Data(count: Self.saltLength)
        let saltStatus = salt.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard saltStatus == errSecSuccess else {
            throw CryptoError.saltGenerationFailed
        }

        // 2. Derive 256-bit key using PBKDF2 SHA-256
        guard let key = deriveKey(password: password, salt: salt) else {
            throw CryptoError.keyDerivationFailed
        }

        // 3. Generate explicit 12-byte CSPRNG Nonce for AES-GCM
        let nonce = AES.GCM.Nonce()

        // 4. Encrypt with AES-GCM (Authenticated Encryption with Associated Data)
        let sealedBox = try AES.GCM.seal(data, using: key, nonce: nonce)

        // 5. Output format: [16 bytes salt] + [12 bytes nonce] + [16 bytes tag] + [ciphertext]
        var combined = Data()
        combined.reserveCapacity(Self.saltLength + Self.nonceLength + Self.tagLength + sealedBox.ciphertext.count)
        combined.append(salt)
        combined.append(contentsOf: nonce)
        combined.append(sealedBox.tag)
        combined.append(sealedBox.ciphertext)

        return combined
    }

    // MARK: - AES-256-GCM Decryption & Tag Verification
    public func decrypt(data: Data, password: String) throws -> Data {
        guard !password.isEmpty else {
            throw CryptoError.emptyPassword
        }

        // Header requires: salt(16) + nonce(12) + tag(16) = 44 bytes
        let headerSize = Self.saltLength + Self.nonceLength + Self.tagLength
        guard data.count >= headerSize else {
            throw CryptoError.payloadTooShort
        }

        let salt = data.subdata(in: 0..<Self.saltLength)
        let nonceData = data.subdata(in: Self.saltLength..<(Self.saltLength + Self.nonceLength))
        let tag = data.subdata(in: (Self.saltLength + Self.nonceLength)..<headerSize)
        let ciphertext = data.subdata(in: headerSize..<data.count)

        guard let key = deriveKey(password: password, salt: salt) else {
            throw CryptoError.keyDerivationFailed
        }

        do {
            let nonce = try AES.GCM.Nonce(data: nonceData)
            let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(sealedBox, using: key)
        } catch CryptoKitError.authenticationFailure {
            throw CryptoError.authenticationFailure("The password may be incorrect, or the backup archive has been modified or corrupted.")
        } catch {
            throw CryptoError.generalError("Decryption failed: \(error.localizedDescription)")
        }
    }
}
