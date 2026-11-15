import Foundation
import UIKit
import Darwin

public final class RestoreEngine {
    public static let shared = RestoreEngine()

    private let fileManager = FileManager.default

    private init() {}

    // MARK: - Fast Metadata Extractor (Zero Full Extraction Overhead)
    public func extractMetadata(from archiveURL: URL) -> BackupRecord? {
        guard fileManager.fileExists(atPath: archiveURL.path) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: archiveURL) else { return nil }
        defer { try? handle.close() }

        guard let magic = try? handle.read(upToCount: 4), magic.count >= 2 else { return nil }
        let isGzip = (magic[0] == 0x1f && magic[1] == 0x8b)

        if isGzip {
            // Seek back to start for decompression
            try? handle.seek(toOffset: 0)
            guard let decompressor = try? GzipDecompressor() else { return nil }
            defer { decompressor.close() }

            var metaData: Data? = nil
            var buffer = Data()
            var state: MetadataScanState = .seekingHeader
            let bufferSize = 65536

            enum MetadataScanState {
                case seekingHeader
                case readingData(remaining: Int64, collected: Data)
                case found
            }

            while metaData == nil {
                guard let chunk = try? handle.read(upToCount: bufferSize), !chunk.isEmpty else { break }

                let endReached = (try? decompressor.decompress(data: chunk) { uncompressed in
                    buffer.append(uncompressed)

                    while metaData == nil && !buffer.isEmpty {
                        switch state {
                        case .seekingHeader:
                            guard buffer.count >= 512 else { return }
                            let block = buffer.prefix(512)
                            buffer.removeFirst(512)

                            // Check for zero block
                            if block.allSatisfy({ $0 == 0 }) { continue }

                            // Read header name & prefix
                            func readString(offset: Int, len: Int) -> String {
                                let slice = block.subdata(in: offset..<(offset + len))
                                if let nullIdx = slice.firstIndex(of: 0) {
                                    return String(decoding: slice.prefix(upTo: nullIdx), as: UTF8.self)
                                }
                                return String(decoding: slice, as: UTF8.self)
                            }
                            let name = readString(offset: 0, len: 100)
                            let prefix = readString(offset: 345, len: 155)
                            let fullName = prefix.isEmpty ? name : "\(prefix)/\(name)"

                            let sizeStr = readString(offset: 124, len: 12)
                                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
                            let size = Int64(sizeStr, radix: 8) ?? 0

                            if fullName.hasSuffix("BackupMetadata.plist") || name == "BackupMetadata.plist" {
                                if size == 0 { return }
                                state = .readingData(remaining: size, collected: Data())
                            } else {
                                // Skip payload + padding
                                let pad = (512 - (Int(size) % 512)) % 512
                                let totalSkip = Int(size) + pad
                                if buffer.count >= totalSkip {
                                    buffer.removeFirst(totalSkip)
                                } else {
                                    return
                                }
                            }

                        case .readingData(var remaining, var collected):
                            let toTake = min(Int64(buffer.count), remaining)
                            collected.append(buffer.prefix(Int(toTake)))
                            buffer.removeFirst(Int(toTake))
                            remaining -= toTake

                            if remaining == 0 {
                                metaData = collected
                                state = .found
                                return
                            } else {
                                state = .readingData(remaining: remaining, collected: collected)
                            }

                        case .found:
                            return
                        }
                    }
                }) ?? false

                if endReached || state == .found { break }
            }

            if let data = metaData, let record = try? PropertyListDecoder().decode(BackupRecord.self, from: data) {
                return record
            }
        }

        // Fallback for PKZip archives
        let tempMetaDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Meta_\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: tempMetaDir) }
        try? fileManager.createDirectory(at: tempMetaDir, withIntermediateDirectories: true)

        let extracted = PosixHelper.shared.dittoExtract(zipPath: archiveURL.path, destinationDir: tempMetaDir.path)
        if extracted {
            let metaURL = tempMetaDir.appendingPathComponent("BackupMetadata.plist")
            if let data = try? Data(contentsOf: metaURL),
               let record = try? PropertyListDecoder().decode(BackupRecord.self, from: data) {
                return record
            }
        }

        return nil
    }

    // MARK: - Extract Archive to Staging Directory
    public func extractArchive(from archiveURL: URL, to stagingURL: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: archiveURL) else {
            throw NSError(
                domain: "AppVault.RestoreEngine",
                code: 501,
                userInfo: [NSLocalizedDescriptionKey: "Failed to open archive file for reading: \(archiveURL.lastPathComponent)"]
            )
        }
        defer { try? handle.close() }

        guard let magic = try? handle.read(upToCount: 4), magic.count >= 2 else {
            throw NSError(
                domain: "AppVault.RestoreEngine",
                code: 501,
                userInfo: [NSLocalizedDescriptionKey: "Archive file is empty or unreadable."]
            )
        }

        let isGzip = (magic[0] == 0x1f && magic[1] == 0x8b)
        let isZip = (magic.count >= 4 && magic[0] == 0x50 && magic[1] == 0x4b && magic[2] == 0x03 && magic[3] == 0x04)

        if isGzip {
            // Streaming Gzip Tar Decompression & Extraction
            try handle.seek(toOffset: 0)
            let decompressor = try GzipDecompressor()
            defer { decompressor.close() }

            let tarExtractor = TarExtractor(destinationDir: stagingURL)
            let bufferSize = 65536

            while true {
                guard let chunk = try? handle.read(upToCount: bufferSize), !chunk.isEmpty else {
                    break
                }

                let endReached = try decompressor.decompress(data: chunk) { uncompressed in
                    try tarExtractor.feed(data: uncompressed)
                }

                if endReached {
                    break
                }
            }

            try tarExtractor.finish()
            return
        }

        if isZip {
            // Legacy / PKZip archive extraction via Apple ditto
            let extracted = PosixHelper.shared.dittoExtract(zipPath: archiveURL.path, destinationDir: stagingURL.path)
            guard extracted else {
                throw NSError(
                    domain: "AppVault.RestoreEngine",
                    code: 501,
                    userInfo: [NSLocalizedDescriptionKey: "ditto extraction failed on PKZip archive."]
                )
            }
            return
        }

        // Uncompressed POSIX Tar format
        try handle.seek(toOffset: 0)
        let tarExtractor = TarExtractor(destinationDir: stagingURL)
        let bufferSize = 65536
        while true {
            guard let chunk = try? handle.read(upToCount: bufferSize), !chunk.isEmpty else {
                break
            }
            try tarExtractor.feed(data: chunk)
        }
        try tarExtractor.finish()
    }

    // MARK: - Restore from Archive URL
    public func restore(
        from archiveURL: URL,
        options: SelectiveRestoreOptions = SelectiveRestoreOptions(),
        progress: @escaping (OperationProgress) -> Void
    ) async throws -> BackupRecord {
        let restoreID = UUID()
        let stagingURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppVault_Restore_\(restoreID.uuidString)", isDirectory: true)

        defer {
            try? fileManager.removeItem(at: stagingURL)
        }

        progress(OperationProgress(
            stage: "Extracting Archive",
            fractionCompleted: 0.15,
            statusDetail: "Decompressing and unpacking backup package..."
        ))

        try? fileManager.removeItem(at: stagingURL)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)

        do {
            try extractArchive(from: archiveURL, to: stagingURL)
        } catch {
            throw NSError(
                domain: "AppVault.RestoreEngine",
                code: 501,
                userInfo: [NSLocalizedDescriptionKey: "Failed to extract archive: \(error.localizedDescription)"]
            )
        }

        // Locate inner staging directory if archive preserved outer directory container
        var contentDir = stagingURL
        if let subdirs = try? fileManager.contentsOfDirectory(at: stagingURL, includingPropertiesForKeys: nil),
           subdirs.count == 1,
           let first = subdirs.first,
           (try? first.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let innerMeta = first.appendingPathComponent("BackupMetadata.plist")
            if fileManager.fileExists(atPath: innerMeta.path) {
                contentDir = first
            }
        }

        // MARK: 1. Parse Metadata
        progress(OperationProgress(
            stage: "Analyzing Metadata",
            fractionCompleted: 0.30,
            statusDetail: "Reading backup manifest..."
        ))

        let metadataURL = contentDir.appendingPathComponent("BackupMetadata.plist")
        guard let data = try? Data(contentsOf: metadataURL),
              let record = try? PropertyListDecoder().decode(BackupRecord.self, from: data) else {
            throw NSError(
                domain: "AppVault.RestoreEngine",
                code: 502,
                userInfo: [NSLocalizedDescriptionKey: "Backup metadata missing or invalid format in archive."]
            )
        }

        // MARK: 2. Terminate Running Application
        progress(OperationProgress(
            stage: "Terminating App",
            fractionCompleted: 0.40,
            statusDetail: "Stopping \(record.appName) processes..."
        ))

        PosixHelper.shared.terminateApp(named: record.appName)
        PosixHelper.shared.terminateApp(named: record.bundleIdentifier)

        // MARK: 3. Locate Target Application on Device
        progress(OperationProgress(
            stage: "Locating Target App",
            fractionCompleted: 0.50,
            statusDetail: "Resolving container destinations..."
        ))

        let installedApps = AppDiscoveryService.shared.fetchInstalledApps()
        let targetApp = installedApps.first(where: { $0.bundleIdentifier == record.bundleIdentifier })

        // Check if app bundle needs to be installed first via TrollStore
        if targetApp == nil {
            let payloadDir = contentDir.appendingPathComponent("Payload", isDirectory: true)
            if let items = try? fileManager.contentsOfDirectory(at: payloadDir, includingPropertiesForKeys: nil),
               let appBundle = items.first(where: { $0.pathExtension == "app" }) {
                progress(OperationProgress(
                    stage: "App Not Installed",
                    fractionCompleted: 0.55,
                    statusDetail: "Launching TrollStore to install application..."
                ))
                await PosixHelper.shared.installViaTrollStore(at: appBundle)
                throw NSError(
                    domain: "AppVault.RestoreEngine",
                    code: 201,
                    userInfo: [NSLocalizedDescriptionKey: "\(record.appName) is not installed. Dispatched installation to TrollStore. Please re-run restore once installation finishes."]
                )
            } else {
                throw NSError(
                    domain: "AppVault.RestoreEngine",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Application '\(record.bundleIdentifier)' is not installed on this device and no .app payload was found in backup."]
                )
            }
        }

        guard let currentTarget = targetApp, let dataContainer = currentTarget.dataContainerURL else {
            throw NSError(
                domain: "AppVault.RestoreEngine",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Could not locate data container for \(record.bundleIdentifier)."]
            )
        }

        // MARK: 4. Restore Data Container (Selective)
        let backupDataDir = contentDir.appendingPathComponent("Data", isDirectory: true)
        if fileManager.fileExists(atPath: backupDataDir.path) {
            progress(OperationProgress(
                stage: "Restoring App Data",
                fractionCompleted: 0.70,
                statusDetail: "Restoring selected container components..."
            ))

            // Documents
            if options.restoreDocuments {
                let src = backupDataDir.appendingPathComponent("Documents")
                if fileManager.fileExists(atPath: src.path) {
                    let dest = dataContainer.appendingPathComponent("Documents")
                    try? fileManager.removeItem(at: dest)
                    try? fileManager.copyItem(at: src, to: dest)
                }
            }

            // Library
            let srcLib = backupDataDir.appendingPathComponent("Library")
            if fileManager.fileExists(atPath: srcLib.path) {
                let destLib = dataContainer.appendingPathComponent("Library")
                try? fileManager.createDirectory(at: destLib, withIntermediateDirectories: true)

                if options.restorePreferences {
                    let srcPref = srcLib.appendingPathComponent("Preferences")
                    if fileManager.fileExists(atPath: srcPref.path) {
                        let destPref = destLib.appendingPathComponent("Preferences")
                        try? fileManager.removeItem(at: destPref)
                        try? fileManager.copyItem(at: srcPref, to: destPref)
                    }
                }

                if options.restoreAppSupport {
                    let srcAS = srcLib.appendingPathComponent("Application Support")
                    if fileManager.fileExists(atPath: srcAS.path) {
                        let destAS = destLib.appendingPathComponent("Application Support")
                        try? fileManager.removeItem(at: destAS)
                        try? fileManager.copyItem(at: srcAS, to: destAS)
                    }
                }

                if options.restoreCaches {
                    let srcCaches = srcLib.appendingPathComponent("Caches")
                    if fileManager.fileExists(atPath: srcCaches.path) {
                        let destCaches = destLib.appendingPathComponent("Caches")
                        try? fileManager.removeItem(at: destCaches)
                        try? fileManager.copyItem(at: srcCaches, to: destCaches)
                    }
                }
            }

            // SystemData (if present)
            let srcSystemData = backupDataDir.appendingPathComponent("SystemData")
            if fileManager.fileExists(atPath: srcSystemData.path) {
                let destSystemData = dataContainer.appendingPathComponent("SystemData")
                try? fileManager.removeItem(at: destSystemData)
                try? fileManager.copyItem(at: srcSystemData, to: destSystemData)
            }

            // Recursively repair permissions (mobile:mobile 501:501, dirs 0755, files 0644/0755)
            PosixHelper.shared.fixPermissions(at: dataContainer.path, uid: 501, gid: 501)
        }

        // MARK: 5. Restore App Groups
        if options.restoreAppGroups {
            let backupGroupsDir = contentDir.appendingPathComponent("AppGroups", isDirectory: true)
            if fileManager.fileExists(atPath: backupGroupsDir.path) {
                progress(OperationProgress(
                    stage: "Restoring App Groups",
                    fractionCompleted: 0.85,
                    statusDetail: "Restoring shared group containers..."
                ))

                for (groupID, currentGroupURL) in currentTarget.groupContainerURLs {
                    let backupGroup = backupGroupsDir.appendingPathComponent(groupID)
                    guard fileManager.fileExists(atPath: backupGroup.path) else { continue }

                    for sub in ["Documents", "Library"] {
                        let src = backupGroup.appendingPathComponent(sub)
                        guard fileManager.fileExists(atPath: src.path) else { continue }
                        let dest = currentGroupURL.appendingPathComponent(sub)
                        try? fileManager.removeItem(at: dest)
                        try? fileManager.copyItem(at: src, to: dest)
                    }

                    // Recursively repair permissions on shared group container
                    PosixHelper.shared.fixPermissions(at: currentGroupURL.path, uid: 501, gid: 501)
                }
            }
        }

        // MARK: 6. Restore Keychain Items
        if options.restoreKeychain {
            let kcURL = contentDir.appendingPathComponent("KeychainItems.plist")
            if let data = try? Data(contentsOf: kcURL),
               let items = try? PropertyListDecoder().decode([KeychainItem].self, from: data) {
                let restored = KeychainService.shared.restoreKeychainItems(items)
                print("[RestoreEngine] Successfully restored \(restored) keychain credentials.")
            }
        }

        // Invalidate app container discovery cache so newly restored apps/groups reflect immediately
        AppDiscoveryService.shared.invalidateCache()

        progress(OperationProgress(
            stage: "Completed",
            fractionCompleted: 1.0,
            statusDetail: "Application state restored successfully!",
            isCompleted: true
        ))

        return record
    }
}
