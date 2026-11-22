import Foundation
import Combine

@MainActor
public final class SettingsViewModel: ObservableObject {
    public static let defaultModeKey = "appvault_default_backup_mode"
    public static let defaultCachesKey = "appvault_default_include_caches"
    public static let maxBackupsPerAppKey = "appvault_max_backups_per_app"

    public static var savedDefaultBackupMode: BackupMode {
        if let raw = UserDefaults.standard.string(forKey: defaultModeKey),
           let mode = BackupMode(rawValue: raw) {
            return mode
        }
        return .dataOnly
    }

    public static var savedDefaultIncludeCaches: Bool {
        UserDefaults.standard.bool(forKey: defaultCachesKey)
    }

    public static var savedMaxBackupsPerApp: Int {
        UserDefaults.standard.integer(forKey: maxBackupsPerAppKey)
    }

    @Published public var defaultBackupMode: BackupMode {
        didSet {
            UserDefaults.standard.set(defaultBackupMode.rawValue, forKey: Self.defaultModeKey)
        }
    }

    @Published public var defaultIncludeCaches: Bool {
        didSet {
            UserDefaults.standard.set(defaultIncludeCaches, forKey: Self.defaultCachesKey)
        }
    }

    /// 0 = Unlimited, otherwise keep only the newest N local backups per bundle ID.
    @Published public var maxBackupsPerApp: Int {
        didSet {
            UserDefaults.standard.set(max(0, maxBackupsPerApp), forKey: Self.maxBackupsPerAppKey)
        }
    }

    @Published public var freeDiskSpace: String = "Calculating..."
    @Published public var backupStorageUsed: String = "Calculating..."
    @Published public var tempStorageUsed: String = "Calculating..."
    @Published public var isTrollStoreEnvironment: Bool = true
    @Published public var canAccessRootMobile: Bool = true
    @Published public var isCalculatingStorage: Bool = false

    private let fileManager = FileManager.default
    private var calculationTask: Task<Void, Never>? = nil

    public init() {
        self.defaultBackupMode = Self.savedDefaultBackupMode
        self.defaultIncludeCaches = Self.savedDefaultIncludeCaches
        self.maxBackupsPerApp = Self.savedMaxBackupsPerApp
        refreshDiagnostics()
    }

    deinit {
        calculationTask?.cancel()
    }

    public func refreshDiagnostics() {
        // 1. Check Root Mobile Access (instantaneous check)
        canAccessRootMobile = fileManager.isReadableFile(atPath: "/var/mobile")

        // 2. Free Disk Space (instantaneous statfs check)
        if let systemAttributes = try? fileManager.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let freeSpace = systemAttributes[.systemFreeSize] as? Int64 {
            freeDiskSpace = ByteCountFormatter.string(fromByteCount: freeSpace, countStyle: .file)
        }

        // 3. TrollStore detection (instantaneous path check)
        isTrollStoreEnvironment = fileManager.fileExists(atPath: "/Applications/TrollStore.app") ||
                                  fileManager.fileExists(atPath: "/var/mobile/Applications/TrollStore.app") ||
                                  canAccessRootMobile

        // 4. Calculate directory sizes asynchronously in background to prevent UI stutter
        calculationTask?.cancel()
        isCalculatingStorage = true

        calculationTask = Task.detached(priority: .utility) {
            let backupDir = BackupEngine.shared.backupsDirectory
            let backupSize = AppDiscoveryService.shared.directorySize(at: backupDir)
            guard !Task.isCancelled else { return }
            let formattedBackup = ByteCountFormatter.string(fromByteCount: backupSize, countStyle: .file)

            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            let tempSize = AppDiscoveryService.shared.directorySize(at: tempURL)
            guard !Task.isCancelled else { return }
            let formattedTemp = ByteCountFormatter.string(fromByteCount: tempSize, countStyle: .file)

            await MainActor.run {
                self.backupStorageUsed = formattedBackup
                self.tempStorageUsed = formattedTemp
                self.isCalculatingStorage = false
            }
        }
    }

    public func clearTemporaryFiles() {
        Task.detached(priority: .userInitiated) {
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            let fm = FileManager.default
            if let items = try? fm.contentsOfDirectory(at: tempURL, includingPropertiesForKeys: nil) {
                for item in items {
                    let name = item.lastPathComponent
                    if name.contains("AppVault") || name.contains("CloudRestore") || name.contains("WebDAVRestore") || name.contains("Meta_") {
                        try? fm.removeItem(at: item)
                    }
                }
            }

            await MainActor.run {
                self.refreshDiagnostics()
            }
        }
    }
}
