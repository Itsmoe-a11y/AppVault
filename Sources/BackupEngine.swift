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

    // MARK: - Execute Backup
    public func createBackup(
        for app: InstalledApp,
        mode: BackupMode,
        includeCaches: Bool,
        note: String,
        progress: @escaping (OperationProgress) -> Void
    ) async throws -> BackupRecord {
        let backupID = UUID()
        let timestamp = Int(Date().timeIntervalSince1970)
        let safeName = app.name.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        let archiveName = "\(safeName)_\(app.bundleIdentifier)_\(timestamp).adbk"
        let stagingURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppVault_\(backupID.uuidString)", isDirectory: true)

        defer {
            try? fileManager.removeItem(at: stagingURL)
        }

        progress(OperationProgress(
            stage: "Preparing",
            fractionCompleted: 0.05,
            statusDetail: "Setting up staging directory..."
        ))

        try? fileManager.removeItem(at: stagingURL)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)

        var hasBundle = false
        var hasData = false
        var savedGroups: [String] = []

        // MARK: 1. Backup App Bundle (Full Backup Mode)
        if mode == .full, let bundleURL = app.bundleURL, fileManager.fileExists(atPath: bundleURL.path) {
            progress(OperationProgress(
                stage: "Packaging Application",
                fractionCompleted: 0.20,
                statusDetail: "Copying application bundle..."
            ))

            let payloadDir = stagingURL.appendingPathComponent("Payload", isDirectory: true)
            try fileManager.createDirectory(at: payloadDir, withIntermediateDirectories: true)
            let destBundle = payloadDir.appendingPathComponent(bundleURL.lastPathComponent)
            try fileManager.copyItem(at: bundleURL, to: destBundle)
            hasBundle = true
        }

        // MARK: 2. Backup App Data Container
        if let dataURL = app.dataContainerURL, fileManager.fileExists(atPath: dataURL.path) {
            progress(OperationProgress(
                stage: "Backing Up App Data",
                fractionCompleted: 0.45,
                statusDetail: "Copying Documents, Library, and Application Support..."
            ))

            let dataDir = stagingURL.appendingPathComponent("Data", isDirectory: true)
            try fileManager.createDirectory(at: dataDir, withIntermediateDirectories: true)

            // Copy container items
            let itemsToCopy = ["Documents", "Library", "SystemData", ".com.apple.mobile_container_manager.metadata.plist"]
            for item in itemsToCopy {
                let srcItem = dataURL.appendingPathComponent(item)
                guard fileManager.fileExists(atPath: srcItem.path) else { continue }
                let destItem = dataDir.appendingPathComponent(item)
                try? fileManager.copyItem(at: srcItem, to: destItem)
            }

            // Exclude Caches and tmp if specified
            if !includeCaches {
                let cachesPath = dataDir.appendingPathComponent("Library/Caches")
                let tmpPath = dataDir.appendingPathComponent("tmp")
                try? fileManager.removeItem(at: cachesPath)
                try? fileManager.removeItem(at: tmpPath)
            }

            hasData = true
        }

        // MARK: 3. Backup App Groups
        if !app.groupContainerURLs.isEmpty {
            progress(OperationProgress(
                stage: "Backing Up App Groups",
                fractionCompleted: 0.65,
                statusDetail: "Copying shared group containers..."
            ))

            let groupsDir = stagingURL.appendingPathComponent("AppGroups", isDirectory: true)
            try fileManager.createDirectory(at: groupsDir, withIntermediateDirectories: true)

            for (groupID, groupURL) in app.groupContainerURLs {
                guard fileManager.fileExists(atPath: groupURL.path) else { continue }
                let destGroup = groupsDir.appendingPathComponent(groupID, isDirectory: true)
                try? fileManager.createDirectory(at: destGroup, withIntermediateDirectories: true)

                let subdirs = ["Documents", "Library"]
                for subdir in subdirs {
                    let src = groupURL.appendingPathComponent(subdir)
                    if fileManager.fileExists(atPath: src.path) {
                        let dest = destGroup.appendingPathComponent(subdir)
                        try? fileManager.copyItem(at: src, to: dest)
                    }
                }

                if !includeCaches {
                    let groupCaches = destGroup.appendingPathComponent("Library/Caches")
                    try? fileManager.removeItem(at: groupCaches)
                }

                savedGroups.append(groupID)
            }
        }

        // MARK: 4. Write Backup Metadata
        progress(OperationProgress(
            stage: "Generating Metadata",
            fractionCompleted: 0.80,
            statusDetail: "Writing archive manifest..."
        ))

        var record = BackupRecord(
            id: backupID,
            bundleIdentifier: app.bundleIdentifier,
            appName: app.name,
            appVersion: app.version,
            appBuild: app.build,
            createdAt: Date(),
            mode: mode,
            includesCaches: includeCaches,
            note: note,
            archiveFileName: archiveName,
            fileSizeBytes: 0,
            hasAppBundle: hasBundle,
            hasDataContainer: hasData,
            appGroupIDs: savedGroups
        )

        let metadataURL = stagingURL.appendingPathComponent("BackupMetadata.plist")
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let metaData = try encoder.encode(record)
        try metaData.write(to: metadataURL)

        // MARK: 5. Compress into Archive
        progress(OperationProgress(
            stage: "Compressing Archive",
            fractionCompleted: 0.90,
            statusDetail: "Packing into \(archiveName)..."
        ))

        let destinationArchive = backupsDirectory.appendingPathComponent(archiveName)
        try? fileManager.removeItem(at: destinationArchive)

        let success = PosixHelper.shared.dittoArchive(
            sourceDir: stagingURL.path,
            destinationZip: destinationArchive.path
        )

        guard success && fileManager.fileExists(atPath: destinationArchive.path) else {
            throw NSError(
                domain: "AppVault.BackupEngine",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Failed to compress archive with ditto."]
            )
        }

        // Fix permissions of created archive so user can read/share it
        PosixHelper.shared.fixPermissions(at: destinationArchive.path)

        // Update record with actual file size
        if let attrs = try? fileManager.attributesOfItem(atPath: destinationArchive.path),
           let size = attrs[.size] as? Int64 {
            record.fileSizeBytes = size
        }

        progress(OperationProgress(
            stage: "Completed",
            fractionCompleted: 1.0,
            statusDetail: "Backup created successfully! (\(record.formattedSize))",
            isCompleted: true
        ))

        return record
    }
}
