import Foundation
import CommonCrypto
import CryptoKit

public enum CryptoError: LocalizedError {
    case emptyPassword
    case saltGenerationFailed
    case invalidSalt
    case keyDerivationFailed
    case payloadTooShort
    case invalidHeader
    case ioFailure(String)
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
            return "Encrypted payload is corrupted or too short."
        case .invalidHeader:
            return "Archive header is not a valid AppVault encrypted container."
        case .ioFailure(let reason):
            return "File I/O error during encryption: \(reason)"
        case .authenticationFailure(let reason):
            return "Decryption authentication failed. \(reason)"
        case .generalError(let message):
            return message
        }
    }
}

public final class CryptoService {
    public static let shared = CryptoService()

    // Chunked AES-256-GCM Container Magic Header: "AVENC02\0" (8 bytes)
    public static let streamMagic = Data([0x41, 0x56, 0x45, 0x4E, 0x43, 0x30, 0x32, 0x00])
    public static let saltLength: Int = 16
    public static let nonceLength: Int = 12
    public static let tagLength: Int = 16
    public static let pbkdf2Rounds: UInt32 = 100_000
    public static let streamChunkSize: Int = 1024 * 1024 // 1 MB per authenticated chunk

    private init() {}

    // MARK: - Detect Encrypted AppVault Container
    public func isEncryptedFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: Self.streamMagic.count) else { return false }
        return header == Self.streamMagic
    }

    // MARK: - Compute Streaming SHA-256 Checksum
    public func sha256Hex(forFileAt url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw CryptoError.ioFailure("Cannot open file for hashing.")
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 262_144), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

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

    // Derive deterministic unique 12-byte nonce per chunk: baseNonce(8B) + big-endian chunkIndex(4B)
    private func makeChunkNonce(basePrefix: Data, chunkIndex: UInt32) throws -> AES.GCM.Nonce {
        var nonceData = Data(capacity: 12)
        nonceData.append(basePrefix)
        var beIndex = chunkIndex.bigEndian
        withUnsafeBytes(of: &beIndex) { nonceData.append(contentsOf: $0) }
        return try AES.GCM.Nonce(data: nonceData)
    }

    // Authenticated Associated Data binding chunk sequence index and final-chunk flag
    private func makeChunkAAD(chunkIndex: UInt32, isFinal: Bool) -> Data {
        var aad = Data(capacity: 5)
        var beIndex = chunkIndex.bigEndian
        withUnsafeBytes(of: &beIndex) { aad.append(contentsOf: $0) }
        aad.append(isFinal ? 1 : 0)
        return aad
    }

    // MARK: - Streaming Chunked File Encryption (Zero OOM)
    // Format: [8B Magic "AVENC02\0"][16B Salt][8B NoncePrefix] + repeated [4B CipherLen][1B IsFinal][Ciphertext][16B Tag]
    public func encryptFile(at sourceURL: URL, to destinationURL: URL, password: String) throws {
        guard !password.isEmpty else { throw CryptoError.emptyPassword }

        guard let reader = try? FileHandle(forReadingFrom: sourceURL) else {
            throw CryptoError.ioFailure("Failed to open source file for encryption.")
        }
        defer { try? reader.close() }

        try? FileManager.default.removeItem(at: destinationURL)
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil, attributes: nil)

        guard let writer = try? FileHandle(forWritingTo: destinationURL) else {
            throw CryptoError.ioFailure("Failed to open destination file for encryption.")
        }

        var succeeded = false
        defer {
            try? writer.close()
            if !succeeded {
                try? FileManager.default.removeItem(at: destinationURL)
            }
        }

        var salt = Data(count: Self.saltLength)
        let saltStatus = salt.withUnsafeMutableBytes { buf in
            SecRandomCopyBytes(kSecRandomDefault, buf.count, buf.baseAddress!)
        }
        guard saltStatus == errSecSuccess else { throw CryptoError.saltGenerationFailed }

        var noncePrefix = Data(count: 8)
        let nonceStatus = noncePrefix.withUnsafeMutableBytes { buf in
            SecRandomCopyBytes(kSecRandomDefault, buf.count, buf.baseAddress!)
        }
        guard nonceStatus == errSecSuccess else { throw CryptoError.saltGenerationFailed }

        guard let key = deriveKey(password: password, salt: salt) else {
            throw CryptoError.keyDerivationFailed
        }

        try writer.write(contentsOf: Self.streamMagic)
        try writer.write(contentsOf: salt)
        try writer.write(contentsOf: noncePrefix)

        var chunkIndex: UInt32 = 0
        var nextChunk = try reader.read(upToCount: Self.streamChunkSize) ?? Data()

        while true {
            let lookahead = try reader.read(upToCount: Self.streamChunkSize) ?? Data()
            let isFinal = lookahead.isEmpty

            let nonce = try makeChunkNonce(basePrefix: noncePrefix, chunkIndex: chunkIndex)
            let aad = makeChunkAAD(chunkIndex: chunkIndex, isFinal: isFinal)
            let sealed = try AES.GCM.seal(nextChunk, using: key, nonce: nonce, authenticating: aad)

            var lenBE = UInt32(sealed.ciphertext.count).bigEndian
            let lenData = withUnsafeBytes(of: &lenBE) { Data($0) }
            try writer.write(contentsOf: lenData)
            try writer.write(contentsOf: Data([isFinal ? 1 : 0]))
            try writer.write(contentsOf: sealed.ciphertext)
            try writer.write(contentsOf: sealed.tag)

            if isFinal { break }
            chunkIndex &+= 1
            nextChunk = lookahead
        }

        succeeded = true
    }

    // MARK: - Streaming Chunked File Decryption (Zero OOM)
    public func decryptFile(at sourceURL: URL, to destinationURL: URL, password: String) throws {
        guard !password.isEmpty else { throw CryptoError.emptyPassword }

        guard let reader = try? FileHandle(forReadingFrom: sourceURL) else {
            throw CryptoError.ioFailure("Failed to open encrypted archive.")
        }
        defer { try? reader.close() }

        guard let magic = try reader.read(upToCount: Self.streamMagic.count), magic == Self.streamMagic else {
            throw CryptoError.invalidHeader
        }
        guard let salt = try reader.read(upToCount: Self.saltLength), salt.count == Self.saltLength,
              let noncePrefix = try reader.read(upToCount: 8), noncePrefix.count == 8 else {
            throw CryptoError.payloadTooShort
        }

        guard let key = deriveKey(password: password, salt: salt) else {
            throw CryptoError.keyDerivationFailed
        }

        try? FileManager.default.removeItem(at: destinationURL)
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil, attributes: nil)

        guard let writer = try? FileHandle(forWritingTo: destinationURL) else {
            throw CryptoError.ioFailure("Failed to create decrypted output file.")
        }

        var succeeded = false
        defer {
            try? writer.close()
            if !succeeded {
                try? FileManager.default.removeItem(at: destinationURL)
            }
        }

        var chunkIndex: UInt32 = 0
        var sawFinal = false

        while !sawFinal {
            guard let frameHeader = try reader.read(upToCount: 5), frameHeader.count == 5 else {
                throw CryptoError.authenticationFailure("Encrypted archive appears truncated.")
            }

            let cipherLen = Int(
                (UInt32(frameHeader[0]) << 24) |
                (UInt32(frameHeader[1]) << 16) |
                (UInt32(frameHeader[2]) << 8)  |
                UInt32(frameHeader[3])
            )
            let isFinal = (frameHeader[4] == 1)

            // Guard against corrupted/malicious frame length (> 16 MB per chunk)
            guard cipherLen >= 0 && cipherLen <= 16 * 1024 * 1024 else {
                throw CryptoError.authenticationFailure("Invalid encrypted chunk size.")
            }

            let ciphertext: Data
            if cipherLen > 0 {
                guard let ct = try reader.read(upToCount: cipherLen), ct.count == cipherLen else {
                    throw CryptoError.authenticationFailure("Unexpected end of encrypted archive.")
                }
                ciphertext = ct
            } else {
                ciphertext = Data()
            }

            guard let tag = try reader.read(upToCount: Self.tagLength), tag.count == Self.tagLength else {
                throw CryptoError.authenticationFailure("Missing authentication tag.")
            }

            do {
                let nonce = try makeChunkNonce(basePrefix: noncePrefix, chunkIndex: chunkIndex)
                let aad = makeChunkAAD(chunkIndex: chunkIndex, isFinal: isFinal)
                let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
                let plaintext = try AES.GCM.open(sealed, using: key, authenticating: aad)
                if !plaintext.isEmpty {
                    try writer.write(contentsOf: plaintext)
                }
            } catch CryptoKitError.authenticationFailure {
                throw CryptoError.authenticationFailure("Incorrect password or the backup archive has been modified or corrupted.")
            } catch {
                throw CryptoError.generalError("Decryption failed: \(error.localizedDescription)")
            }

            sawFinal = isFinal
            chunkIndex &+= 1
        }

        succeeded = true
    }

    // MARK: - In-Memory AES-256-GCM Encryption (Small Payloads)
    public func encrypt(data: Data, password: String) throws -> Data {
        guard !password.isEmpty else { throw CryptoError.emptyPassword }

        var salt = Data(count: Self.saltLength)
        let saltStatus = salt.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard saltStatus == errSecSuccess else { throw CryptoError.saltGenerationFailed }

        guard let key = deriveKey(password: password, salt: salt) else {
            throw CryptoError.keyDerivationFailed
        }

        let nonce = AES.GCM.Nonce()
        let sealedBox = try AES.GCM.seal(data, using: key, nonce: nonce)

        var combined = Data()
        combined.reserveCapacity(Self.saltLength + Self.nonceLength + Self.tagLength + sealedBox.ciphertext.count)
        combined.append(salt)
        combined.append(contentsOf: nonce)
        combined.append(sealedBox.tag)
        combined.append(sealedBox.ciphertext)
        return combined
    }

    // MARK: - In-Memory AES-256-GCM Decryption
    public func decrypt(data: Data, password: String) throws -> Data {
        guard !password.isEmpty else { throw CryptoError.emptyPassword }

        let headerSize = Self.saltLength + Self.nonceLength + Self.tagLength
        guard data.count >= headerSize else { throw CryptoError.payloadTooShort }

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
            throw CryptoError.authenticationFailure("Incorrect password or corrupted payload.")
        } catch {
            throw CryptoError.generalError("Decryption failed: \(error.localizedDescription)")
        }
    }
}
