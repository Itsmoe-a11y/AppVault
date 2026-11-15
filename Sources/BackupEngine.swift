import Foundation
import UIKit

public final class BackupEngine {
    public static let shared = BackupEngine()

    private let fileManager = FileManager.default

    public var backupsDirectory: URL {
        // Preferred: /var/mobile/Documents/AppVault/Backups (accessible across apps)
        let rootMobile = URL(fileURLWithPath: "/var/mobile/Documents/AppVault/Backups", isDirectory: true)
        if fileManager.isWritableFile(atPath: "/var/mobile/Documents") || fileManager.fileExists(atPath: rootMobile.path) {
            try? fileManager.createDirectory(at: rootMobile, withIntermediateDirectories: true)
            return rootMobile
        }

        // Fallback: Sandbox Documents/Backups
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let localBackups = docs.appendingPathComponent("Backups", isDirectory: true)
        try? fileManager.createDirectory(at: localBackups, withIntermediateDirectories: true)
        return localBackups
    }

    private init() {
        try? fileManager.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
    }

    // MARK: - 1. Zero-Staging Streaming Backup (Direct to Local File)
    public func createStreamingBackup(
        for app: InstalledApp,
        mode: BackupMode,
        includeCaches: Bool,
        note: String,
        progress: @escaping (OperationProgress) -> Void
    ) async throws -> BackupRecord {
        let safeName = app.name.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        let timestamp = Int(Date().timeIntervalSince1970)
        let archiveName = "\(safeName)_\(app.bundleIdentifier)_\(timestamp).adbk"
        let destinationURL = backupsDirectory.appendingPathComponent(archiveName)

        try? fileManager.removeItem(at: destinationURL)
        fileManager.createFile(atPath: destinationURL.path, contents: nil, attributes: nil)

        guard let writeHandle = try? FileHandle(forWritingTo: destinationURL) else {
            throw NSError(domain: "AppVault.BackupEngine", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to open destination file handle for streaming."])
        }
        defer { try? writeHandle.close() }

        var totalWritten: Int64 = 0

        var record = try await StreamingArchiveEngine.shared.streamBackup(
            for: app,
            mode: mode,
            includeCaches: includeCaches,
            note: note,
            onProgress: progress
        ) { chunk in
            writeHandle.write(chunk)
            totalWritten += Int64(chunk.count)
        }

        PosixHelper.shared.fixPermissions(at: destinationURL.path)
        record.fileSizeBytes = totalWritten

        return record
    }

    // MARK: - 2. Zero-Disk Streaming Backup to Google Drive
    public func createGoogleDriveStreamingBackup(
        for app: InstalledApp,
        mode: BackupMode,
        includeCaches: Bool,
        note: String,
        progress: @escaping (OperationProgress) -> Void
    ) async throws -> BackupRecord {
        let safeName = app.name.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        let timestamp = Int(Date().timeIntervalSince1970)
        let archiveName = "\(safeName)_\(app.bundleIdentifier)_\(timestamp).adbk"

        progress(OperationProgress(
            stage: "Google Drive",
            fractionCompleted: 0.05,
            statusDetail: "Initiating cloud resumable upload session..."
        ))

        let sessionURL = try await GoogleDriveService.shared.initiateResumableUpload(
            fileName: archiveName,
            mimeType: "application/x-gzip"
        )

        // 5 MB chunk buffer (Google Drive optimal chunk size)
        let chunkThreshold: Int = 5 * 1024 * 1024
        var chunkBuffer = Data()
        var currentOffset: Int64 = 0
        var totalUploadedBytes: Int64 = 0

        var record = try await StreamingArchiveEngine.shared.streamBackup(
            for: app,
            mode: mode,
            includeCaches: includeCaches,
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

            // When buffer reaches 5 MB threshold, upload chunk
            if chunkBuffer.count >= chunkThreshold {
                let toUpload = chunkBuffer
                chunkBuffer = Data()

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

        // Upload any remaining bytes in final chunk
        progress(OperationProgress(
            stage: "Finishing Upload",
            fractionCompleted: 0.95,
            statusDetail: "Finalizing cloud archive..."
        ))

        _ = try await GoogleDriveService.shared.uploadChunk(
            sessionURL: sessionURL,
            chunkData: chunkBuffer,
            startOffset: currentOffset,
            isFinal: true,
            totalFileSize: currentOffset + Int64(chunkBuffer.count)
        )
        totalUploadedBytes += Int64(chunkBuffer.count)
        record.fileSizeBytes = totalUploadedBytes

        progress(OperationProgress(
            stage: "Upload Complete",
            fractionCompleted: 1.0,
            statusDetail: "Cloud backup finished! Stored in Google Drive / AppVault Backups (\(record.formattedSize)).",
            isCompleted: true
        ))

        return record
    }

    // MARK: - 3. Staged Backup (Fallback)
    public func createBackup(
        for app: InstalledApp,
        mode: BackupMode,
        includeCaches: Bool,
        note: String,
        progress: @escaping (OperationProgress) -> Void
    ) async throws -> BackupRecord {
        // Automatically default to zero-staging streaming engine for speed & zero disk duplication!
        return try await createStreamingBackup(
            for: app,
            mode: mode,
            includeCaches: includeCaches,
            note: note,
            progress: progress
        )
    }
}
