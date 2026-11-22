import Foundation
import UIKit
import Darwin

public enum RestoreError: LocalizedError {
    case passwordRequired
    case general(Int, String)

    public var errorDescription: String? {
        switch self {
        case .passwordRequired:
            return "This backup archive is encrypted with AES-256-GCM. Please enter the decryption password."
        case .general(_, let msg):
            return msg
        }
    }
}

public final class RestoreEngine {
    public static let shared = RestoreEngine()

    private let fileManager = FileManager.default

    private init() {}

    // MARK: - Safe Directory Content Replacement (Preserves System Directory ACLs & Attributes)
    private func replaceDirectoryContents(from sourceDir: URL, to destinationDir: URL) {
        try? fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        if let existing = try? fileManager.contentsOfDirectory(at: destinationDir, includingPropertiesForKeys: nil) {
            for item in existing {
                try? fileManager.removeItem(at: item)
            }
        }
        if let incoming = try? fileManager.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: nil) {
            for item in incoming {
                let target = destinationDir.appendingPathComponent(item.lastPathComponent)
                try? fileManager.copyItem(at: item, to: target)
            }
        }
    }

    // MARK: - Fast Metadata Extractor (Safe Buffer Normalization & Payload Skipping)
    public func extractMetadata(from archiveURL: URL) -> BackupRecord? {
        guard fileManager.fileExists(atPath: archiveURL.path) else { return nil }

        // Do not attempt raw tar/ditto parsing on encrypted containers
        if CryptoService.shared.isEncryptedFile(at: archiveURL) {
            return nil
        }

        guard let handle = try? FileHandle(forReadingFrom: archiveURL) else { return nil }
        defer { try? handle.close() }

        guard let magic = try? handle.read(upToCount: 4), magic.count >= 2 else { return nil }
        let isGzip = (magic[0] == 0x1f && magic[1] == 0x8b)
        let isZip = (magic.count >= 4 && magic[0] == 0x50 && magic[1] == 0x4b && magic[2] == 0x03 && magic[3] == 0x04)

        if isGzip {
            try? handle.seek(toOffset: 0)
            guard let decompressor = try? GzipDecompressor() else { return nil }
            defer { decompressor.close() }

            var metaData: Data? = nil
            var buffer = Data()
            var state: MetadataScanState = .seekingHeader
            let bufferSize = 65536

            enum MetadataScanState: Equatable {
                case seekingHeader
                case readingData(remaining: Int64, collected: Data)
                case skippingPayload(remaining: Int64)
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
                            // Normalize slice indices to 0..<512 before subdata access
                            let block = Data(buffer.prefix(512))
                            buffer.removeFirst(512)

                            if block.allSatisfy({ $0 == 0 }) { continue }

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
                            } else if size > 0 {
                                let pad = Int64((512 - (Int(size) % 512)) % 512)
                                state = .skippingPayload(remaining: size + pad)
                            }

                        case .skippingPayload(var remaining):
                            let toDrop = min(Int64(buffer.count), remaining)
                            buffer.removeFirst(Int(toDrop))
                            remaining -= toDrop
                            if remaining == 0 {
                                state = .seekingHeader
                            } else {
                                state = .skippingPayload(remaining: remaining)
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

            if let data = metaData, var record = try? PropertyListDecoder().decode(BackupRecord.self, from: data) {
                record.archiveFileName = archiveURL.lastPathComponent
                return record
            }
            return nil
        }

        // Only fall back to ditto for actual PKZip archives
        if isZip {
            let tempMetaDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Meta_\(UUID().uuidString)")
            defer { try? fileManager.removeItem(at: tempMetaDir) }
            try? fileManager.createDirectory(at: tempMetaDir, withIntermediateDirectories: true)

            let extracted = PosixHelper.shared.dittoExtract(zipPath: archiveURL.path, destinationDir: tempMetaDir.path)
            if extracted {
                var metaURL = tempMetaDir.appendingPathComponent("BackupMetadata.plist")
                if !fileManager.fileExists(atPath: metaURL.path),
                   let contents = try? fileManager.contentsOfDirectory(at: tempMetaDir, includingPropertiesForKeys: nil),
                   let firstSub = contents.first {
                    let subMeta = firstSub.appendingPathComponent("BackupMetadata.plist")
                    if fileManager.fileExists(atPath: subMeta.path) {
                        metaURL = subMeta
                    }
                }
                if let data = try? Data(contentsOf: metaURL),
                   var record = try? PropertyListDecoder().decode(BackupRecord.self, from: data) {
                    record.archiveFileName = archiveURL.lastPathComponent
                    return record
                }
            }
        }

        return nil
    }

    // MARK: - Extract Archive to Staging Directory
    public func extractArchive(from archiveURL: URL, to stagingURL: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: archiveURL) else {
            throw RestoreError.general(501, "Failed to open archive file for reading: \(archiveURL.lastPathComponent)")
        }
        defer { try? handle.close() }

        guard let magic = try? handle.read(upToCount: 4), magic.count >= 2 else {
            throw RestoreError.general(501, "Archive file is empty or unreadable.")
        }

        let isGzip = (magic[0] == 0x1f && magic[1] == 0x8b)
        let isZip = (magic.count >= 4 && magic[0] == 0x50 && magic[1] == 0x4b && magic[2] == 0x03 && magic[3] == 0x04)

        if isGzip {
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

                if endReached { break }
            }

            try tarExtractor.finish()
            return
        }

        if isZip {
            let extracted = PosixHelper.shared.dittoExtract(zipPath: archiveURL.path, destinationDir: stagingURL.path)
            guard extracted else {
                throw RestoreError.general(501, "ditto extraction failed on PKZip archive.")
            }
            return
        }

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

    // MARK: - Restore from Archive URL (Supports AES-256-GCM Decryption & Pre-Restore Safety Snapshot)
    public func restore(
        from archiveURL: URL,
        options: SelectiveRestoreOptions = SelectiveRestoreOptions(),
        password: String? = nil,
        progress: @escaping (OperationProgress) -> Void
    ) async throws -> BackupRecord {
        let restoreID = UUID()
        let stagingURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppVault_Restore_\(restoreID.uuidString)", isDirectory: true)
        var decryptedTempURL: URL? = nil

        defer {
            try? fileManager.removeItem(at: stagingURL)
            if let dec = decryptedTempURL {
                try? fileManager.removeItem(at: dec)
            }
        }

        var workingArchiveURL = archiveURL

        // MARK: 0. Decrypt Archive if AES-256-GCM Encrypted
        if CryptoService.shared.isEncryptedFile(at: archiveURL) {
            guard let pwd = password?.trimmingCharacters(in: .whitespacesAndNewlines), !pwd.isEmpty else {
                throw RestoreError.passwordRequired
            }

            progress(OperationProgress(
                stage: "Decrypting Archive",
                fractionCompleted: 0.08,
                statusDetail: "Verifying authentication tag and decrypting with AES-256-GCM..."
            ))

            let decURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppVault_Dec_\(restoreID.uuidString).adbk")
            decryptedTempURL = decURL
            try CryptoService.shared.decryptFile(at: archiveURL, to: decURL, password: pwd)
            workingArchiveURL = decURL
        }

        progress(OperationProgress(
            stage: "Extracting Archive",
            fractionCompleted: 0.18,
            statusDetail: "Decompressing and unpacking backup package..."
        ))

        try? fileManager.removeItem(at: stagingURL)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)

        do {
            try extractArchive(from: workingArchiveURL, to: stagingURL)
        } catch {
            throw RestoreError.general(501, "Failed to extract archive: \(error.localizedDescription)")
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
              var record = try? PropertyListDecoder().decode(BackupRecord.self, from: data) else {
            throw RestoreError.general(502, "Backup metadata missing or invalid format in archive.")
        }
        record.archiveFileName = archiveURL.lastPathComponent

        // MARK: 2. Terminate Running Application & Daemons
        progress(OperationProgress(
            stage: "Terminating App",
            fractionCompleted: 0.38,
            statusDetail: "Stopping \(record.appName) processes..."
        ))

        PosixHelper.shared.terminateApp(named: record.appName)
        PosixHelper.shared.terminateApp(named: record.bundleIdentifier)
        PosixHelper.shared.terminateApp(named: "cfprefsd")

        // MARK: 3. Locate Target Application on Device
        progress(OperationProgress(
            stage: "Locating Target App",
            fractionCompleted: 0.45,
            statusDetail: "Resolving container destinations..."
        ))

        let installedApps = AppDiscoveryService.shared.fetchInstalledApps(forceRefresh: true)
        let targetApp = installedApps.first(where: {
            $0.bundleIdentifier == record.bundleIdentifier ||
            $0.bundleIdentifier.caseInsensitiveCompare(record.bundleIdentifier) == .orderedSame
        })

        // If app is not installed and backup contains Payload/*.app, build a persistent .tipa outside stagingURL before launching TrollStore
        if targetApp == nil {
            let payloadDir = contentDir.appendingPathComponent("Payload", isDirectory: true)
            if let items = try? fileManager.contentsOfDirectory(at: payloadDir, includingPropertiesForKeys: nil),
               items.contains(where: { $0.pathExtension == "app" }) {
                progress(OperationProgress(
                    stage: "Packaging for TrollStore",
                    fractionCompleted: 0.55,
                    statusDetail: "Creating persistent .tipa package for TrollStore installation..."
                ))

                let persistentTipa = BackupEngine.shared.backupsDirectory
                    .appendingPathComponent("PendingInstall_\(record.bundleIdentifier).tipa")
                try? fileManager.removeItem(at: persistentTipa)

                let packaged = PosixHelper.shared.dittoArchive(
                    sourceDir: payloadDir.path,
                    destinationZip: persistentTipa.path
                )
                guard packaged else {
                    throw RestoreError.general(500, "Failed to package \(record.appName) into .tipa for TrollStore.")
                }
                PosixHelper.shared.fixPermissions(at: persistentTipa.path)

                await PosixHelper.shared.installViaTrollStore(at: persistentTipa)
                throw RestoreError.general(201, "\(record.appName) is not installed. Packaged to \(persistentTipa.lastPathComponent) and opened in TrollStore. Re-run restore after TrollStore finishes installing.")
            } else {
                throw RestoreError.general(404, "Application '\(record.bundleIdentifier)' is not installed on this device and no .app payload was found in backup.")
            }
        }

        guard let currentTarget = targetApp, let dataContainer = currentTarget.dataContainerURL else {
            throw RestoreError.general(404, "Could not locate data container for \(record.bundleIdentifier).")
        }

        // MARK: 3.5 Pre-Restore Safety Snapshot ("Undo Restore")
        if options.createSafetySnapshot {
            progress(OperationProgress(
                stage: "Safety Snapshot",
                fractionCompleted: 0.52,
                statusDetail: "Saving automatic pre-restore snapshot of current app data..."
            ))
            let snapName = "SafetySnapshot_\(currentTarget.bundleIdentifier)_\(Int(Date().timeIntervalSince1970)).adbk"
            let snapURL = BackupEngine.shared.backupsDirectory.appendingPathComponent(snapName)
            fileManager.createFile(atPath: snapURL.path, contents: nil, attributes: nil)
            if let snapHandle = try? FileHandle(forWritingTo: snapURL) {
                defer { try? snapHandle.close() }
                _ = try? await StreamingArchiveEngine.shared.streamBackup(
                    for: currentTarget,
                    mode: .dataOnly,
                    includeCaches: false,
                    includeKeychain: options.restoreKeychain,
                    includeAppGroups: options.restoreAppGroups,
                    note: "Auto safety snapshot before restoring \(record.archiveFileName)",
                    onProgress: { _ in }
                ) { chunk in
                    try snapHandle.write(contentsOf: chunk)
                }
                PosixHelper.shared.fixPermissions(at: snapURL.path)
            }
        }

        // MARK: 4. Restore Data Container (Selective)
        let backupDataDir = contentDir.appendingPathComponent("Data", isDirectory: true)
        if fileManager.fileExists(atPath: backupDataDir.path) {
            progress(OperationProgress(
                stage: "Restoring App Data",
                fractionCompleted: 0.70,
                statusDetail: "Restoring selected container components..."
            ))

            if options.restoreDocuments {
                let src = backupDataDir.appendingPathComponent("Documents")
                if fileManager.fileExists(atPath: src.path) {
                    replaceDirectoryContents(from: src, to: dataContainer.appendingPathComponent("Documents"))
                }
            }

            let srcLib = backupDataDir.appendingPathComponent("Library")
            if fileManager.fileExists(atPath: srcLib.path) {
                let destLib = dataContainer.appendingPathComponent("Library")
                try? fileManager.createDirectory(at: destLib, withIntermediateDirectories: true)

                if options.restorePreferences {
                    let srcPref = srcLib.appendingPathComponent("Preferences")
                    if fileManager.fileExists(atPath: srcPref.path) {
                        replaceDirectoryContents(from: srcPref, to: destLib.appendingPathComponent("Preferences"))
                    }
                }

                if options.restoreAppSupport {
                    let srcAS = srcLib.appendingPathComponent("Application Support")
                    if fileManager.fileExists(atPath: srcAS.path) {
                        replaceDirectoryContents(from: srcAS, to: destLib.appendingPathComponent("Application Support"))
                    }
                }

                if options.restoreCaches {
                    let srcCaches = srcLib.appendingPathComponent("Caches")
                    if fileManager.fileExists(atPath: srcCaches.path) {
                        replaceDirectoryContents(from: srcCaches, to: destLib.appendingPathComponent("Caches"))
                    }
                }
            }

            let srcSystemData = backupDataDir.appendingPathComponent("SystemData")
            if fileManager.fileExists(atPath: srcSystemData.path) {
                replaceDirectoryContents(from: srcSystemData, to: dataContainer.appendingPathComponent("SystemData"))
            }

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

                    if let incoming = try? fileManager.contentsOfDirectory(at: backupGroup, includingPropertiesForKeys: nil) {
                        for item in incoming {
                            let dest = currentGroupURL.appendingPathComponent(item.lastPathComponent)
                            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                            if isDir {
                                replaceDirectoryContents(from: item, to: dest)
                            } else {
                                try? fileManager.removeItem(at: dest)
                                try? fileManager.copyItem(at: item, to: dest)
                            }
                        }
                    }

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
