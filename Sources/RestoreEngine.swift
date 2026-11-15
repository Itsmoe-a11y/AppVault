import Foundation
import UIKit

public final class RestoreEngine {
    public static let shared = RestoreEngine()

    private let fileManager = FileManager.default

    private init() {}

    // MARK: - Restore from Archive URL
    public func restore(
        from archiveURL: URL,
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
            statusDetail: "Unpacking backup package..."
        ))

        try? fileManager.removeItem(at: stagingURL)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)

        let extracted = PosixHelper.shared.dittoExtract(
            zipPath: archiveURL.path,
            destinationDir: stagingURL.path
        )

        guard extracted else {
            throw NSError(
                domain: "AppVault.RestoreEngine",
                code: 501,
                userInfo: [NSLocalizedDescriptionKey: "Failed to extract archive. File may be corrupted."]
            )
        }

        // Locate inner staging if ditto preserved outer folder
        var contentDir = stagingURL
        if let subdirs = try? fileManager.contentsOfDirectory(at: stagingURL, includingPropertiesForKeys: nil),
           subdirs.count == 1,
           let first = subdirs.first,
           (try? first.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            contentDir = first
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
                userInfo: [NSLocalizedDescriptionKey: "Backup metadata missing or invalid format."]
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
        var targetApp = installedApps.first(where: { $0.bundleIdentifier == record.bundleIdentifier })

        // Check if app bundle needs to be installed first
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
                    userInfo: [NSLocalizedDescriptionKey: "\(record.appName) was not installed. Dispatched installation to TrollStore. Please re-run restore once installation finishes."]
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

        // MARK: 4. Restore Data Container
        let backupDataDir = contentDir.appendingPathComponent("Data", isDirectory: true)
        if fileManager.fileExists(atPath: backupDataDir.path) {
            progress(OperationProgress(
                stage: "Restoring App Data",
                fractionCompleted: 0.70,
                statusDetail: "Restoring Documents & Library databases..."
            ))

            let itemsToRestore = ["Documents", "Library", "SystemData"]
            for item in itemsToRestore {
                let backupItem = backupDataDir.appendingPathComponent(item)
                guard fileManager.fileExists(atPath: backupItem.path) else { continue }

                let targetItem = dataContainer.appendingPathComponent(item)
                // Remove existing destination item
                try? fileManager.removeItem(at: targetItem)
                // Copy restored folder
                try fileManager.copyItem(at: backupItem, to: targetItem)
            }

            // CRITICAL: Reset permissions to mobile:mobile (501:501)
            PosixHelper.shared.fixPermissions(at: dataContainer.path, uid: 501, gid: 501)
        }

        // MARK: 5. Restore App Groups
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

                // Fix permissions for shared group container
                PosixHelper.shared.fixPermissions(at: currentGroupURL.path, uid: 501, gid: 501)
            }
        }

        progress(OperationProgress(
            stage: "Completed",
            fractionCompleted: 1.0,
            statusDetail: "Application state restored successfully!",
            isCompleted: true
        ))

        return record
    }
}
