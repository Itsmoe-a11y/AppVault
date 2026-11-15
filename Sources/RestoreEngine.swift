import Foundation
import UIKit

public final class RestoreEngine {
    public static let shared = RestoreEngine()

    private let fileManager = FileManager.default

    private init() {}

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
        let targetApp = installedApps.first(where: { $0.bundleIdentifier == record.bundleIdentifier })

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

        progress(OperationProgress(
            stage: "Completed",
            fractionCompleted: 1.0,
            statusDetail: "Application state restored successfully!",
            isCompleted: true
        ))

        return record
    }
}
