import Foundation
import UIKit
import CryptoKit

public final class BackupEngine {
    public static let shared = BackupEngine()

    private let fileManager = FileManager.default

    // Primary persistent storage: /var/mobile/Documents/AppVaultBackups (accessible via Filza / Files)
    // Fallback: Sandbox Documents/Backups
    public var backupsDirectory: URL {
        let rootMobile = URL(fileURLWithPath: "/var/mobile/Documents/AppVaultBackups", isDirectory: true)
        if fileManager.isWritableFile(atPath: "/var/mobile/Documents") {
            try? fileManager.createDirectory(at: rootMobile, withIntermediateDirectories: true)
            PosixHelper.shared.fixPermissions(at: rootMobile.path)
            return rootMobile
        }

        if let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let localBackups = docs.appendingPathComponent("Backups", isDirectory: true)
            try? fileManager.createDirectory(at: localBackups, withIntermediateDirectories: true)
            PosixHelper.shared.fixPermissions(at: localBackups.path)
            return localBackups
        }

        let tmpFallback = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Backups", isDirectory: true)
        try? fileManager.createDirectory(at: tmpFallback, withIntermediateDirectories: true)
        return tmpFallback
    }

    private init() {
        try? fileManager.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
        PosixHelper.shared.fixPermissions(at: backupsDirectory.path)
    }

    private func makeArchiveName(for app: InstalledApp, isEncrypted: Bool) -> String {
        let safeName = app.name.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        let prefix = safeName.isEmpty ? "App" : safeName
        let timestamp = Int(Date().timeIntervalSince1970)
        return isEncrypted
            ? "\(prefix)_\(app.bundleIdentifier)_\(timestamp).enc.adbk"
            : "\(prefix)_\(app.bundleIdentifier)_\(timestamp).adbk"
    }

    // MARK: - 1. Zero-Staging Streaming Backup (Direct to Local File, Optional AES-256-GCM Encryption)
    public func createStreamingBackup(
        for app: InstalledApp,
        mode: BackupMode,
        includeCaches: Bool,
        includeKeychain: Bool = true,
        includeAppGroups: Bool = true,
        encryptionPassword: String? = nil,
        note: String,
        progress: @escaping (OperationProgress) -> Void
    ) async throws -> BackupRecord {
        let password = encryptionPassword?.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldEncrypt = (password != nil && !(password!.isEmpty))
        let archiveName = makeArchiveName(for: app, isEncrypted: shouldEncrypt)
        let destinationURL = backupsDirectory.appendingPathComponent(archiveName)

        // When encrypting, stream tar.gz to a temp file then stream-encrypt to final destination (zero OOM)
        let streamTargetURL: URL
        if shouldEncrypt {
            streamTargetURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("AppVault_Plain_\(UUID().uuidString).adbk")
        } else {
            streamTargetURL = destinationURL
        }

        try? fileManager.removeItem(at: streamTargetURL)
        fileManager.createFile(atPath: streamTargetURL.path, contents: nil, attributes: nil)

        guard let writeHandle = try? FileHandle(forWritingTo: streamTargetURL) else {
            throw NSError(domain: "AppVault.BackupEngine", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to open destination file handle for streaming."])
        }

        var isSuccess = false
        defer {
            try? writeHandle.close()
            if shouldEncrypt {
                try? fileManager.removeItem(at: streamTargetURL)
            }
            if !isSuccess {
                try? fileManager.removeItem(at: destinationURL)
            }
        }

        var totalWritten: Int64 = 0
        var hasher = SHA256()

        var record = try await StreamingArchiveEngine.shared.streamBackup(
            for: app,
            mode: mode,
            includeCaches: includeCaches,
            includeKeychain: includeKeychain,
            includeAppGroups: includeAppGroups,
            note: note,
            onProgress: { p in
                let scaled = shouldEncrypt ? min(0.85, p.fractionCompleted * 0.85) : p.fractionCompleted
                progress(OperationProgress(
                    stage: p.stage,
                    fractionCompleted: scaled,
                    statusDetail: p.statusDetail,
                    isCompleted: shouldEncrypt ? false : p.isCompleted
                ))
            }
        ) { chunk in
            try writeHandle.write(contentsOf: chunk)
            totalWritten += Int64(chunk.count)
            if !shouldEncrypt {
                hasher.update(data: chunk)
            }
        }

        try? writeHandle.close()

        if shouldEncrypt, let pwd = password {
            progress(OperationProgress(
                stage: "Encrypting Archive",
                fractionCompleted: 0.90,
                statusDetail: "Encrypting with AES-256-GCM (PBKDF2 100k rounds)..."
            ))
            try CryptoService.shared.encryptFile(at: streamTargetURL, to: destinationURL, password: pwd)
            let attrs = try? fileManager.attributesOfItem(atPath: destinationURL.path)
            totalWritten = (attrs?[.size] as? Int64) ?? totalWritten
            record.sha256Checksum = try? CryptoService.shared.sha256Hex(forFileAt: destinationURL)
        } else {
            let digest = hasher.finalize()
            record.sha256Checksum = digest.map { String(format: "%02x", $0) }.joined()
        }

        isSuccess = true
        PosixHelper.shared.fixPermissions(at: destinationURL.path)
        record.archiveFileName = archiveName
        record.fileSizeBytes = totalWritten
        record.isEncrypted = shouldEncrypt

        progress(OperationProgress(
            stage: "Completed",
            fractionCompleted: 1.0,
            statusDetail: shouldEncrypt ? "Encrypted backup created (\(record.formattedSize))." : "Backup created (\(record.formattedSize)).",
            isCompleted: true
        ))

        // Enforce optional retention policy (keep newest N local backups per bundleID)
        let retentionLimit = UserDefaults.standard.integer(forKey: "appvault_max_backups_per_app")
        if retentionLimit > 0 {
            pruneOldBackups(for: app.bundleIdentifier, keepNewest: retentionLimit)
        }

        return record
    }

    // MARK: - 2. Zero-Disk Streaming Backup to Google Drive (Strict 256 KB Chunk Alignment)
    public func createGoogleDriveStreamingBackup(
        for app: InstalledApp,
        mode: BackupMode,
        includeCaches: Bool,
        includeKeychain: Bool = true,
        includeAppGroups: Bool = true,
        encryptionPassword: String? = nil,
        note: String,
        progress: @escaping (OperationProgress) -> Void
    ) async throws -> BackupRecord {
        let password = encryptionPassword?.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldEncrypt = (password != nil && !(password!.isEmpty))
        let archiveName = makeArchiveName(for: app, isEncrypted: shouldEncrypt)

        progress(OperationProgress(
            stage: "Google Drive",
            fractionCompleted: 0.05,
            statusDetail: "Initiating cloud resumable upload session..."
        ))

        let sessionURL = try await GoogleDriveService.shared.initiateResumableUpload(
            fileName: archiveName,
            mimeType: shouldEncrypt ? "application/octet-stream" : "application/x-gzip"
        )

        // Google Drive REQUIRES non-final chunks to be an exact multiple of 256 KB (262,144 bytes).
        // 5 MB = 20 * 262,144 bytes = 5,242,880 bytes.
        let alignedChunkSize: Int = 20 * 262_144
        var chunkBuffer = Data()
        var currentOffset: Int64 = 0
        var totalUploadedBytes: Int64 = 0

        func flushAlignedChunks() async throws {
            while chunkBuffer.count >= alignedChunkSize {
                let toUpload = Data(chunkBuffer.prefix(alignedChunkSize))
                chunkBuffer.removeFirst(alignedChunkSize)

                _ = try await GoogleDriveService.shared.uploadChunk(
                    sessionURL: sessionURL,
                    chunkData: toUpload,
                    startOffset: currentOffset,
                    isFinal: false,
                    totalFileSize: nil
                )
                currentOffset += Int64(toUpload.count)
                totalUploadedBytes += Int64(toUpload.count)
            }
        }

        var record: BackupRecord

        if shouldEncrypt, let pwd = password {
            // Stream-compress to temp, stream-encrypt to temp, then stream-upload in exact 5 MB chunks
            let tempPlain = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppVault_GDPlain_\(UUID().uuidString).adbk")
            let tempEnc = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppVault_GDEnc_\(UUID().uuidString).enc.adbk")
            defer {
                try? fileManager.removeItem(at: tempPlain)
                try? fileManager.removeItem(at: tempEnc)
            }

            fileManager.createFile(atPath: tempPlain.path, contents: nil, attributes: nil)
            guard let plainHandle = try? FileHandle(forWritingTo: tempPlain) else {
                throw NSError(domain: "AppVault.BackupEngine", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare temporary staging file for encrypted upload."])
            }
            defer { try? plainHandle.close() }

            record = try await StreamingArchiveEngine.shared.streamBackup(
                for: app,
                mode: mode,
                includeCaches: includeCaches,
                includeKeychain: includeKeychain,
                includeAppGroups: includeAppGroups,
                note: note,
                onProgress: { p in
                    progress(OperationProgress(
                        stage: "Compressing",
                        fractionCompleted: min(0.45, p.fractionCompleted * 0.45),
                        statusDetail: p.statusDetail
                    ))
                }
            ) { chunk in
                try plainHandle.write(contentsOf: chunk)
            }
            try? plainHandle.close()

            progress(OperationProgress(
                stage: "Encrypting Archive",
                fractionCompleted: 0.50,
                statusDetail: "Encrypting backup with AES-256-GCM..."
            ))
            try CryptoService.shared.encryptFile(at: tempPlain, to: tempEnc, password: pwd)
            try? fileManager.removeItem(at: tempPlain)

            let encAttrs = try? fileManager.attributesOfItem(atPath: tempEnc.path)
            let encTotalSize = (encAttrs?[.size] as? Int64) ?? 0

            guard let encReader = try? FileHandle(forReadingFrom: tempEnc) else {
                throw NSError(domain: "AppVault.BackupEngine", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to read encrypted archive for cloud upload."])
            }
            defer { try? encReader.close() }

            while let piece = try encReader.read(upToCount: alignedChunkSize), !piece.isEmpty {
                let isLast = (currentOffset + Int64(piece.count) >= encTotalSize)
                _ = try await GoogleDriveService.shared.uploadChunk(
                    sessionURL: sessionURL,
                    chunkData: piece,
                    startOffset: currentOffset,
                    isFinal: isLast,
                    totalFileSize: isLast ? encTotalSize : nil
                )
                currentOffset += Int64(piece.count)
                totalUploadedBytes += Int64(piece.count)

                let uploadFrac = encTotalSize > 0 ? Double(currentOffset) / Double(encTotalSize) : 1.0
                progress(OperationProgress(
                    stage: "Uploading Encrypted Backup",
                    fractionCompleted: min(0.98, 0.55 + uploadFrac * 0.43),
                    statusDetail: "Uploaded \(ByteCountFormatter.string(fromByteCount: currentOffset, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: encTotalSize, countStyle: .file))"
                ))
            }
        } else {
            record = try await StreamingArchiveEngine.shared.streamBackup(
                for: app,
                mode: mode,
                includeCaches: includeCaches,
                includeKeychain: includeKeychain,
                includeAppGroups: includeAppGroups,
                note: note,
                onProgress: { p in
                    progress(OperationProgress(
                        stage: "Cloud Streaming",
                        fractionCompleted: min(0.85, p.fractionCompleted),
                        statusDetail: "Compressing & uploading to Google Drive (\(ByteCountFormatter.string(fromByteCount: currentOffset, countStyle: .file)) uploaded)..."
                    ))
                }
            ) { compressedChunk in
                chunkBuffer.append(compressedChunk)
                try await flushAlignedChunks()
            }

            // Finalize upload with remaining tail bytes (or empty finalize range if exact multiple of 5 MB)
            progress(OperationProgress(
                stage: "Finishing Upload",
                fractionCompleted: 0.95,
                statusDetail: "Finalizing cloud archive..."
            ))

            let finalTotalSize = currentOffset + Int64(chunkBuffer.count)
            _ = try await GoogleDriveService.shared.uploadChunk(
                sessionURL: sessionURL,
                chunkData: chunkBuffer,
                startOffset: currentOffset,
                isFinal: true,
                totalFileSize: finalTotalSize
            )
            totalUploadedBytes = finalTotalSize
        }

        record.archiveFileName = archiveName
        record.fileSizeBytes = totalUploadedBytes
        record.isEncrypted = shouldEncrypt

        let folderLabel = await MainActor.run { GoogleDriveService.shared.targetFolderName }
        progress(OperationProgress(
            stage: "Upload Complete",
            fractionCompleted: 1.0,
            statusDetail: "Cloud backup finished! Stored in Google Drive / \(folderLabel) (\(record.formattedSize)).",
            isCompleted: true
        ))

        return record
    }

    // MARK: - 3. Zero-OOM Disk-Backed Streaming Backup to WebDAV / NAS
    public func createWebDAVStreamingBackup(
        for app: InstalledApp,
        mode: BackupMode,
        includeCaches: Bool,
        includeKeychain: Bool = true,
        includeAppGroups: Bool = true,
        encryptionPassword: String? = nil,
        note: String,
        progress: @escaping (OperationProgress) -> Void
    ) async throws -> BackupRecord {
        let password = encryptionPassword?.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldEncrypt = (password != nil && !(password!.isEmpty))
        let archiveName = makeArchiveName(for: app, isEncrypted: shouldEncrypt)

        let tempPlain = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppVault_WDPlain_\(UUID().uuidString).adbk")
        let tempUpload = shouldEncrypt
            ? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppVault_WDEnc_\(UUID().uuidString).enc.adbk")
            : tempPlain

        defer {
            try? fileManager.removeItem(at: tempPlain)
            if shouldEncrypt { try? fileManager.removeItem(at: tempUpload) }
        }

        fileManager.createFile(atPath: tempPlain.path, contents: nil, attributes: nil)
        guard let writeHandle = try? FileHandle(forWritingTo: tempPlain) else {
            throw NSError(domain: "AppVault.BackupEngine", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to open temporary file for WebDAV streaming."])
        }
        defer { try? writeHandle.close() }

        var totalWritten: Int64 = 0
        var record = try await StreamingArchiveEngine.shared.streamBackup(
            for: app,
            mode: mode,
            includeCaches: includeCaches,
            includeKeychain: includeKeychain,
            includeAppGroups: includeAppGroups,
            note: note,
            onProgress: { p in
                progress(OperationProgress(
                    stage: p.stage,
                    fractionCompleted: min(0.65, p.fractionCompleted * 0.65),
                    statusDetail: p.statusDetail
                ))
            }
        ) { chunk in
            try writeHandle.write(contentsOf: chunk)
            totalWritten += Int64(chunk.count)
        }
        try? writeHandle.close()

        if shouldEncrypt, let pwd = password {
            progress(OperationProgress(
                stage: "Encrypting Archive",
                fractionCompleted: 0.72,
                statusDetail: "Encrypting with AES-256-GCM before WebDAV upload..."
            ))
            try CryptoService.shared.encryptFile(at: tempPlain, to: tempUpload, password: pwd)
            try? fileManager.removeItem(at: tempPlain)
            totalWritten = ((try? fileManager.attributesOfItem(atPath: tempUpload.path)[.size] as? Int64) ?? totalWritten)
        }

        progress(OperationProgress(
            stage: "Uploading to WebDAV",
            fractionCompleted: 0.80,
            statusDetail: "Streaming \(ByteCountFormatter.string(fromByteCount: totalWritten, countStyle: .file)) to WebDAV server..."
        ))

        try await WebDAVService.shared.uploadFile(fileURL: tempUpload, remoteFileName: archiveName)

        record.archiveFileName = archiveName
        record.fileSizeBytes = totalWritten
        record.isEncrypted = shouldEncrypt

        progress(OperationProgress(
            stage: "WebDAV Upload Complete",
            fractionCompleted: 1.0,
            statusDetail: "Uploaded \(archiveName) (\(record.formattedSize)) to WebDAV.",
            isCompleted: true
        ))

        return record
    }

    // MARK: - 4. Verify Local Archive Integrity & SHA-256
    public func verifyArchive(at url: URL) -> (isValid: Bool, sha256: String, detail: String) {
        guard fileManager.fileExists(atPath: url.path) else {
            return (false, "", "Archive file does not exist on disk.")
        }

        let hash = (try? CryptoService.shared.sha256Hex(forFileAt: url)) ?? "Unavailable"

        if CryptoService.shared.isEncryptedFile(at: url) {
            return (true, hash, "Valid AppVault AES-256-GCM encrypted container.\nSHA-256: \(hash)")
        }

        if let record = RestoreEngine.shared.extractMetadata(from: url) {
            return (true, hash, "Archive verified: \(record.appName) v\(record.appVersion) (\(record.mode.title)).\nSHA-256: \(hash)")
        }

        return (false, hash, "Archive header or BackupMetadata.plist is corrupted or unreadable.\nSHA-256: \(hash)")
    }

    // MARK: - 5. Automatic Backup Retention (Keep Newest N Backups per App)
    public func pruneOldBackups(for bundleID: String, keepNewest: Int) {
        guard keepNewest > 0 else { return }
        guard let files = try? fileManager.contentsOfDirectory(
            at: backupsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let matching = files
            .filter { url in
                let name = url.lastPathComponent
                return !name.hasPrefix("SafetySnapshot_") &&
                       (url.pathExtension.lowercased() == "adbk" || url.pathExtension.lowercased() == "zip") &&
                       name.contains("_\(bundleID)_")
            }
            .sorted { a, b in
                let d1 = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let d2 = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return d1 > d2
            }

        if matching.count > keepNewest {
            for obsolete in matching.dropFirst(keepNewest) {
                try? fileManager.removeItem(at: obsolete)
            }
        }
    }

    // MARK: - 6. Backwards-Compatible Entry Point
    public func createBackup(
        for app: InstalledApp,
        mode: BackupMode,
        includeCaches: Bool,
        note: String,
        progress: @escaping (OperationProgress) -> Void
    ) async throws -> BackupRecord {
        return try await createStreamingBackup(
            for: app,
            mode: mode,
            includeCaches: includeCaches,
            note: note,
            progress: progress
        )
    }
}
