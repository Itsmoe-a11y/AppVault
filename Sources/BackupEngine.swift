import Foundation
import Darwin
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
            if !fileManager.fileExists(atPath: rootMobile.path) {
                try? fileManager.createDirectory(at: rootMobile, withIntermediateDirectories: true)
                lchown(rootMobile.path, 501, 501)
                chmod(rootMobile.path, 0o755)
            }
            return rootMobile
        }

        if let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let localBackups = docs.appendingPathComponent("Backups", isDirectory: true)
            if !fileManager.fileExists(atPath: localBackups.path) {
                try? fileManager.createDirectory(at: localBackups, withIntermediateDirectories: true)
                lchown(localBackups.path, 501, 501)
                chmod(localBackups.path, 0o755)
            }
            return localBackups
        }

        let tmpFallback = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Backups", isDirectory: true)
        try? fileManager.createDirectory(at: tmpFallback, withIntermediateDirectories: true)
        return tmpFallback
    }

    private init() {
        let dir = backupsDirectory
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        lchown(dir.path, 501, 501)
        chmod(dir.path, 0o755)
    }

    private static let versionCountersKey = "appvault_backup_version_counters_v1"
    private static let versionLock = NSLock()

    /// Extracts sequential backup version (e.g. `_v2_` or `_v2.adbk`) from an archive filename.
    public static func extractBackupVersion(from filename: String) -> Int? {
        let pattern = "_v([0-9]+)(?:_|\\.)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = filename as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: filename, options: [], range: range),
              match.numberOfRanges >= 2 else {
            return nil
        }
        return Int(ns.substring(with: match.range(at: 1)))
    }

    private func savedVersionCounter(for bundleIdentifier: String, destination: BackupDestination) -> Int {
        Self.versionLock.lock()
        defer { Self.versionLock.unlock() }
        let map = UserDefaults.standard.dictionary(forKey: Self.versionCountersKey) as? [String: Int] ?? [:]
        return map["\(destination.rawValue)::\(bundleIdentifier)"] ?? 0
    }

    private func recordBackupVersion(_ version: Int, for bundleIdentifier: String, destination: BackupDestination) {
        Self.versionLock.lock()
        defer { Self.versionLock.unlock() }
        var map = UserDefaults.standard.dictionary(forKey: Self.versionCountersKey) as? [String: Int] ?? [:]
        let key = "\(destination.rawValue)::\(bundleIdentifier)"
        map[key] = max(map[key] ?? 0, version)
        UserDefaults.standard.set(map, forKey: Self.versionCountersKey)
    }

    /// Computes the next sequential backup version (v1, v2, v3...) by inspecting existing archives
    /// at the destination plus the persistent counter (handles legacy timestamped archives seamlessly).
    public func nextBackupVersion(
        for bundleIdentifier: String,
        destination: BackupDestination,
        existingFileNames: [String]
    ) -> Int {
        let saved = savedVersionCounter(for: bundleIdentifier, destination: destination)
        let needle = bundleIdentifier.lowercased()
        var maxFound = 0
        var matchCount = 0

        for name in existingFileNames {
            let lower = name.lowercased()
            guard lower.hasSuffix(".adbk") || lower.hasSuffix(".zip") else { continue }
            if lower.contains(needle) {
                matchCount += 1
                if let v = Self.extractBackupVersion(from: name) {
                    maxFound = max(maxFound, v)
                }
            }
        }
        return max(saved, max(maxFound, matchCount)) + 1
    }

    private func localArchiveFileNames() -> [String] {
        (try? fileManager.contentsOfDirectory(atPath: backupsDirectory.path)) ?? []
    }

    private static let archiveDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    public func makeArchiveName(for app: InstalledApp, version: Int, isEncrypted: Bool) -> String {
        let safeName = app.name.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        let prefix = safeName.isEmpty ? "App" : safeName
        let dateStamp = Self.archiveDateFormatter.string(from: Date())
        let ver = max(1, version)
        return isEncrypted
            ? "\(prefix)_\(app.bundleIdentifier)_v\(ver)_\(dateStamp).enc.adbk"
            : "\(prefix)_\(app.bundleIdentifier)_v\(ver)_\(dateStamp).adbk"
    }

    public func previewNextArchiveName(
        for app: InstalledApp,
        destination: BackupDestination,
        isEncrypted: Bool,
        cachedRemoteNames: [String] = []
    ) -> String {
        let names = (destination == .local) ? localArchiveFileNames() : cachedRemoteNames
        let nextVer = nextBackupVersion(for: app.bundleIdentifier, destination: destination, existingFileNames: names)
        return makeArchiveName(for: app, version: nextVer, isEncrypted: isEncrypted)
    }

    // MARK: - 1. Zero-Staging Streaming Backup (Direct to Local File, Optional AES-256-GCM Encryption)
    public func createStreamingBackup(
        for app: InstalledApp,
        mode: BackupMode,
        includeCaches: Bool,
        includeKeychain: Bool = true,
        includeAppGroups: Bool = true,
        encryptionPassword: String? = nil,
        compressionLevel: BackupCompressionLevel = .fast,
        note: String,
        progress: @escaping (OperationProgress) -> Void
    ) async throws -> BackupRecord {
        let password = encryptionPassword?.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldEncrypt = (password != nil && !(password!.isEmpty))
        let existingLocal = localArchiveFileNames()
        var version = nextBackupVersion(for: app.bundleIdentifier, destination: .local, existingFileNames: existingLocal)
        var archiveName = makeArchiveName(for: app, version: version, isEncrypted: shouldEncrypt)
        while fileManager.fileExists(atPath: backupsDirectory.appendingPathComponent(archiveName).path) {
            version += 1
            archiveName = makeArchiveName(for: app, version: version, isEncrypted: shouldEncrypt)
        }
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
            compressionLevel: compressionLevel,
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
            try autoreleasepool {
                try writeHandle.write(contentsOf: chunk)
            }
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
        recordBackupVersion(version, for: app.bundleIdentifier, destination: .local)
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

    // MARK: - 2. True Zero-Disk Streaming Backup to Google Drive (Unencrypted & Encrypted, Strict 256 KB Alignment)
    public func createGoogleDriveStreamingBackup(
        for app: InstalledApp,
        mode: BackupMode,
        includeCaches: Bool,
        includeKeychain: Bool = true,
        includeAppGroups: Bool = true,
        encryptionPassword: String? = nil,
        compressionLevel: BackupCompressionLevel = .fast,
        bufferProfile: UploadBufferProfile = .auto,
        note: String,
        progress: @escaping (OperationProgress) -> Void
    ) async throws -> BackupRecord {
        await MainActor.run { UIApplication.shared.isIdleTimerDisabled = true }
        defer { Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = false } }

        let password = encryptionPassword?.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldEncrypt = (password != nil && !(password!.isEmpty))
        let existingDriveNames = (try? await GoogleDriveService.shared.fetchCloudBackups())?.map(\.name) ?? []
        let backupVersion = nextBackupVersion(for: app.bundleIdentifier, destination: .googleDrive, existingFileNames: existingDriveNames)
        let archiveName = makeArchiveName(for: app, version: backupVersion, isEncrypted: shouldEncrypt)
        let initialHeadroomMB = UploadBufferProfile.availableRAMHeadroomBytes() / 1_048_576
        var activeChunkSize = bufferProfile.resolvedChunkSizeBytes()

        DebugLogger.shared.log("Backup", "Starting Google Drive stream for \(app.name) (mode=\(mode.rawValue), encrypted=\(shouldEncrypt), compression=\(compressionLevel.shortTitle), buffer=\(bufferProfile.rawValue) [\(activeChunkSize / 1_048_576) MB chunks], RAM headroom=\(initialHeadroomMB) MB)")
        progress(OperationProgress(
            stage: "Connecting to Google Drive",
            fractionCompleted: 0.03,
            statusDetail: "Validating Google Drive credentials..."
        ))

        let sessionURL = try await GoogleDriveService.shared.initiateResumableUpload(
            fileName: archiveName,
            mimeType: shouldEncrypt ? "application/octet-stream" : "application/x-gzip",
            onStatus: { detail in
                progress(OperationProgress(
                    stage: "Connecting to Google Drive",
                    fractionCompleted: 0.06,
                    statusDetail: detail
                ))
            }
        )

        try Task.checkCancellation()

        // Double-buffered dynamic-RAM pipeline:
        // - Re-evaluates os_proc_available_memory() between chunks so Google Drive chunk size scales up to 64-128 MB when RAM is plentiful and steps down automatically under pressure.
        // - Overlaps Wi-Fi upload of chunk N with disk read + compression of chunk N+1 in parallel.
        final class LockedInt64: @unchecked Sendable {
            private let lock = NSLock()
            private var value: Int64 = 0
            func get() -> Int64 { lock.lock(); defer { lock.unlock() }; return value }
            func set(_ newValue: Int64) { lock.lock(); value = newValue; lock.unlock() }
        }

        var chunkBuffer = Data(capacity: activeChunkSize + 524_288)
        var dispatchedOffset: Int64 = 0
        let confirmedUploaded = LockedInt64()
        var lastStreamFraction: Double = 0.12
        var uploadStart: Date? = nil
        var pendingUploadTask: Task<Void, Error>? = nil

        defer {
            pendingUploadTask?.cancel()
        }

        func formatSpeed() -> String {
            let done = confirmedUploaded.get()
            guard let start = uploadStart, done > 0 else { return "starting..." }
            let elapsed = max(0.25, Date().timeIntervalSince(start))
            let mbps = (Double(done) / 1_048_576.0) / elapsed
            return String(format: "%.1f MB/s", mbps)
        }

        func flushAlignedChunks() async throws {
            while chunkBuffer.count >= activeChunkSize {
                try Task.checkCancellation()
                let sendSize = activeChunkSize
                let toUpload = Data(chunkBuffer.prefix(sendSize))
                // Compact tail immediately so Swift Data slices never grow across 40GB+ streams
                if chunkBuffer.count == sendSize {
                    chunkBuffer = Data(capacity: sendSize + 524_288)
                } else {
                    chunkBuffer = Data(chunkBuffer.dropFirst(sendSize))
                }

                // Wait ONLY if the previous background upload is still finishing on Wi-Fi
                if let inFlight = pendingUploadTask {
                    try await inFlight.value
                    pendingUploadTask = nil
                }

                if uploadStart == nil {
                    uploadStart = Date()
                }

                let chunkOffset = dispatchedOffset
                dispatchedOffset += Int64(toUpload.count)
                let chunkMB = toUpload.count / 1_048_576
                let currentFraction = lastStreamFraction

                // Dispatch upload on background Task so disk read + compression immediately fills the next chunk in parallel!
                pendingUploadTask = Task(priority: .userInitiated) {
                    _ = try await GoogleDriveService.shared.uploadChunk(
                        sessionURL: sessionURL,
                        chunkData: toUpload,
                        startOffset: chunkOffset,
                        isFinal: false,
                        totalFileSize: nil
                    )
                    let totalDone = chunkOffset + Int64(toUpload.count)
                    confirmedUploaded.set(totalDone)
                    let uploadedLabel: String = autoreleasepool {
                        ByteCountFormatter.string(fromByteCount: totalDone, countStyle: .file)
                    }
                    progress(OperationProgress(
                        stage: shouldEncrypt ? "Encrypting & Uploading" : "Cloud Streaming",
                        fractionCompleted: min(0.94, max(0.12, currentFraction)),
                        statusDetail: "Uploaded \(uploadedLabel) (\(formatSpeed())) • \(chunkMB) MB chunks • \(compressionLevel.shortTitle) • 0 MB disk"
                    ))
                }

                // Dynamically re-tune next chunk size based on live os_proc_available_memory() headroom
                let nextSize = bufferProfile.resolvedChunkSizeBytes()
                if nextSize != activeChunkSize {
                    DebugLogger.shared.log("Backup", "Dynamic RAM tuner adjusted chunk size: \(activeChunkSize / 1_048_576) MB -> \(nextSize / 1_048_576) MB (headroom=\(UploadBufferProfile.availableRAMHeadroomBytes() / 1_048_576) MB)")
                    activeChunkSize = nextSize
                }
            }
        }

        // Optional 0-disk in-RAM chunked AES-256-GCM encryptor piped straight into the dynamic Drive buffer
        var streamEncryptor: StreamingAEADEncryptor? = nil
        if shouldEncrypt, let pwd = password {
            streamEncryptor = try StreamingAEADEncryptor(password: pwd) { encryptedFrame in
                chunkBuffer.append(encryptedFrame)
                try await flushAlignedChunks()
            }
        }

        progress(OperationProgress(
            stage: "Scanning App Files",
            fractionCompleted: 0.10,
            statusDetail: "Cataloging \(app.name) container before streaming..."
        ))

        var record = try await StreamingArchiveEngine.shared.streamBackup(
            for: app,
            mode: mode,
            includeCaches: includeCaches,
            includeKeychain: includeKeychain,
            includeAppGroups: includeAppGroups,
            compressionLevel: compressionLevel,
            note: note,
            onProgress: { p in
                lastStreamFraction = min(0.94, max(0.12, 0.12 + p.fractionCompleted * 0.82))
                let currentConfirmed = confirmedUploaded.get()
                let uploadedStr: String = autoreleasepool {
                    ByteCountFormatter.string(fromByteCount: currentConfirmed, countStyle: .file)
                }
                let detail = currentConfirmed > 0
                    ? "\(p.statusDetail) • \(uploadedStr) uploaded (\(formatSpeed())) • \(activeChunkSize / 1_048_576) MB buf"
                    : "\(p.statusDetail) • Filling first \(activeChunkSize / 1_048_576) MB buffer..."
                progress(OperationProgress(
                    stage: shouldEncrypt ? "Encrypting & Streaming" : "Cloud Streaming",
                    fractionCompleted: lastStreamFraction,
                    statusDetail: detail
                ))
            }
        ) { compressedChunk in
            try Task.checkCancellation()
            if let encryptor = streamEncryptor {
                try await encryptor.write(compressedChunk)
            } else {
                chunkBuffer.append(compressedChunk)
                try await flushAlignedChunks()
            }
        }

        if let encryptor = streamEncryptor {
            try await encryptor.finish()
        }

        // Wait for the final in-flight background chunk before closing the resumable upload session
        if let inFlight = pendingUploadTask {
            try await inFlight.value
            pendingUploadTask = nil
        }

        progress(OperationProgress(
            stage: "Finishing Upload",
            fractionCompleted: 0.95,
            statusDetail: "Finalizing Google Drive archive..."
        ))

        let finalTotalSize = dispatchedOffset + Int64(chunkBuffer.count)
        _ = try await GoogleDriveService.shared.uploadChunk(
            sessionURL: sessionURL,
            chunkData: chunkBuffer,
            startOffset: dispatchedOffset,
            isFinal: true,
            totalFileSize: finalTotalSize
        )

        record.archiveFileName = archiveName
        record.fileSizeBytes = finalTotalSize
        record.isEncrypted = shouldEncrypt
        recordBackupVersion(backupVersion, for: app.bundleIdentifier, destination: .googleDrive)

        let folderLabel = await MainActor.run { GoogleDriveService.shared.targetFolderName }
        DebugLogger.shared.log("Backup", "Google Drive upload completed: \(archiveName) (\(record.formattedSize))", level: .success)
        progress(OperationProgress(
            stage: "Upload Complete",
            fractionCompleted: 1.0,
            statusDetail: "Uploaded \(record.formattedSize) to Google Drive / \(folderLabel) with 0 MB local disk used.",
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
        compressionLevel: BackupCompressionLevel = .fast,
        note: String,
        progress: @escaping (OperationProgress) -> Void
    ) async throws -> BackupRecord {
        let password = encryptionPassword?.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldEncrypt = (password != nil && !(password!.isEmpty))
        let existingWebDAVNames = (try? await WebDAVService.shared.fetchRemoteFiles())?.map(\.name) ?? []
        let backupVersion = nextBackupVersion(for: app.bundleIdentifier, destination: .webdav, existingFileNames: existingWebDAVNames)
        let archiveName = makeArchiveName(for: app, version: backupVersion, isEncrypted: shouldEncrypt)

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
            compressionLevel: compressionLevel,
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
        recordBackupVersion(backupVersion, for: app.bundleIdentifier, destination: .webdav)

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
