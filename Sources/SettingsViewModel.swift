import Foundation
import SwiftUI
import Combine

@MainActor
public final class SettingsViewModel: ObservableObject {
    @Published public var defaultBackupMode: BackupMode = .dataOnly
    @Published public var defaultIncludeCaches: Bool = false
    @Published public var freeDiskSpace: String = "Calculating..."
    @Published public var backupStorageUsed: String = "Calculating..."
    @Published public var tempStorageUsed: String = "Calculating..."
    @Published public var isTrollStoreEnvironment: Bool = true
    @Published public var canAccessRootMobile: Bool = true

    private let fileManager = FileManager.default

    public init() {
        refreshDiagnostics()
    }

    public func refreshDiagnostics() {
        // 1. Check Root Mobile Access
        canAccessRootMobile = fileManager.isReadableFile(atPath: "/var/mobile")

        // 2. Calculate Disk Space
        if let systemAttributes = try? fileManager.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let freeSpace = systemAttributes[.systemFreeSize] as? Int64 {
            freeDiskSpace = ByteCountFormatter.string(fromByteCount: freeSpace, countStyle: .file)
        }

        // 3. Calculate Backup Storage
        let backupDir = BackupEngine.shared.backupsDirectory
        let backupSize = AppDiscoveryService.shared.directorySize(at: backupDir)
        backupStorageUsed = ByteCountFormatter.string(fromByteCount: backupSize, countStyle: .file)

        // 4. Calculate Temp Storage
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
        let tempSize = AppDiscoveryService.shared.directorySize(at: tempURL)
        tempStorageUsed = ByteCountFormatter.string(fromByteCount: tempSize, countStyle: .file)

        // 5. TrollStore detection
        isTrollStoreEnvironment = fileManager.fileExists(atPath: "/Applications/TrollStore.app") ||
                                  fileManager.fileExists(atPath: "/var/mobile/Applications/TrollStore.app") ||
                                  canAccessRootMobile
    }

    public func clearTemporaryFiles() {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
        if let items = try? fileManager.contentsOfDirectory(at: tempURL, includingPropertiesForKeys: nil) {
            for item in items where item.lastPathComponent.contains("AppVault") {
                try? fileManager.removeItem(at: item)
            }
        }
        refreshDiagnostics()
    }
}
