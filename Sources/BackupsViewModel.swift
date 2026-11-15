import Foundation
import SwiftUI
import Combine

@MainActor
public final class BackupsViewModel: ObservableObject {
    @Published public var backups: [BackupRecord] = []
    @Published public var isLoading: Bool = false
    @Published public var activeProgress: OperationProgress? = nil
    @Published public var isPerformingOperation: Bool = false
    @Published public var exportURL: URL? = nil
    @Published public var alertTitle: String = ""
    @Published public var alertMessage: String = ""
    @Published public var showAlert: Bool = false
    @Published public var restoreConfirmationRecord: BackupRecord? = nil

    private let fileManager = FileManager.default

    public init() {
        refreshBackups()
    }

    public func refreshBackups() {
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let backupDir = BackupEngine.shared.backupsDirectory
            guard let files = try? self.fileManager.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) else {
                await MainActor.run {
                    self.backups = []
                    self.isLoading = false
                }
                return
            }

            var loaded: [BackupRecord] = []
            let archives = files.filter { $0.pathExtension.lowercased() == "adbk" || $0.pathExtension.lowercased() == "zip" }

            for archive in archives {
                if let record = self.readMetadata(from: archive) {
                    loaded.append(record)
                }
            }

            // Sort newest first
            let sorted = loaded.sorted { $0.createdAt > $1.createdAt }

            await MainActor.run {
                self.backups = sorted
                self.isLoading = false
            }
        }
    }

    // MARK: - Read Metadata from Archive
    nonisolated private func readMetadata(from archiveURL: URL) -> BackupRecord? {
        let tempMetaDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Meta_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempMetaDir) }

        try? FileManager.default.createDirectory(at: tempMetaDir, withIntermediateDirectories: true)

        // Fast extraction using ditto
        _ = PosixHelper.shared.execute("/usr/bin/ditto", arguments: ["-x", "-k", archiveURL.path, tempMetaDir.path])
        _ = PosixHelper.shared.execute("/bin/ditto", arguments: ["-x", "-k", archiveURL.path, tempMetaDir.path])

        var metaPath = tempMetaDir.appendingPathComponent("BackupMetadata.plist")
        if !FileManager.default.fileExists(atPath: metaPath.path) {
            // Check subfolder
            if let contents = try? FileManager.default.contentsOfDirectory(at: tempMetaDir, includingPropertiesForKeys: nil),
               let firstSub = contents.first {
                let subMeta = firstSub.appendingPathComponent("BackupMetadata.plist")
                if FileManager.default.fileExists(atPath: subMeta.path) {
                    metaPath = subMeta
                }
            }
        }

        guard let data = try? Data(contentsOf: metaPath),
              var record = try? PropertyListDecoder().decode(BackupRecord.self, from: data) else {
            // Synthesize record if missing metadata
            let filename = archiveURL.lastPathComponent
            let size = (try? FileManager.default.attributesOfItem(atPath: archiveURL.path)[.size] as? Int64) ?? 0
            return BackupRecord(
                bundleIdentifier: "unknown.archive",
                appName: filename.replacingOccurrences(of: ".\(archiveURL.pathExtension)", with: ""),
                appVersion: "1.0",
                appBuild: "1",
                createdAt: (try? FileManager.default.attributesOfItem(atPath: archiveURL.path)[.modificationDate] as? Date) ?? Date(),
                mode: .dataOnly,
                includesCaches: false,
                archiveFileName: filename,
                fileSizeBytes: size,
                hasAppBundle: false,
                hasDataContainer: true
            )
        }

        // Ensure actual disk size is accurate
        if let attrs = try? FileManager.default.attributesOfItem(atPath: archiveURL.path),
           let size = attrs[.size] as? Int64 {
            record.fileSizeBytes = size
        }

        return record
    }

    // MARK: - Execute Backup
    public func startBackup(
        for app: InstalledApp,
        mode: BackupMode,
        includeCaches: Bool,
        note: String
    ) {
        isPerformingOperation = true
        activeProgress = OperationProgress(stage: "Initializing", fractionCompleted: 0.0, statusDetail: "Starting backup process...")

        Task.detached(priority: .userInitiated) {
            do {
                let newRecord = try await BackupEngine.shared.createBackup(
                    for: app,
                    mode: mode,
                    includeCaches: includeCaches,
                    note: note
                ) { progress in
                    Task { @MainActor in
                        self.activeProgress = progress
                    }
                }

                await MainActor.run {
                    self.backups.insert(newRecord, at: 0)
                    self.isPerformingOperation = false
                    self.activeProgress = nil
                }
            } catch {
                await MainActor.run {
                    self.isPerformingOperation = false
                    self.activeProgress = nil
                    self.alertTitle = "Backup Failed"
                    self.alertMessage = error.localizedDescription
                    self.showAlert = true
                }
            }
        }
    }

    // MARK: - Execute Restore
    public func startRestore(record: BackupRecord) {
        isPerformingOperation = true
        activeProgress = OperationProgress(stage: "Initializing", fractionCompleted: 0.0, statusDetail: "Preparing restoration...")

        let archiveURL = BackupEngine.shared.backupsDirectory.appendingPathComponent(record.archiveFileName)

        Task.detached(priority: .userInitiated) {
            do {
                _ = try await RestoreEngine.shared.restore(from: archiveURL) { progress in
                    Task { @MainActor in
                        self.activeProgress = progress
                    }
                }

                await MainActor.run {
                    self.isPerformingOperation = false
                    self.activeProgress = nil
                    self.alertTitle = "Restore Complete"
                    self.alertMessage = "Successfully restored \(record.appName) data! You may now open the app."
                    self.showAlert = true
                }
            } catch {
                await MainActor.run {
                    self.isPerformingOperation = false
                    self.activeProgress = nil
                    self.alertTitle = "Restore Notice"
                    self.alertMessage = error.localizedDescription
                    self.showAlert = true
                }
            }
        }
    }

    // MARK: - Delete Backup
    public func deleteBackup(_ record: BackupRecord) {
        let archiveURL = BackupEngine.shared.backupsDirectory.appendingPathComponent(record.archiveFileName)
        try? fileManager.removeItem(at: archiveURL)
        backups.removeAll { $0.id == record.id }
    }

    // MARK: - Import Backup
    public func importArchive(from sourceURL: URL) {
        let dest = BackupEngine.shared.backupsDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        try? fileManager.removeItem(at: dest)
        do {
            try fileManager.copyItem(at: sourceURL, to: dest)
            PosixHelper.shared.fixPermissions(at: dest.path)
            refreshBackups()
            alertTitle = "Imported"
            alertMessage = "Successfully imported \(sourceURL.lastPathComponent)."
            showAlert = true
        } catch {
            alertTitle = "Import Failed"
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }

    public func fileURL(for record: BackupRecord) -> URL {
        BackupEngine.shared.backupsDirectory.appendingPathComponent(record.archiveFileName)
    }
}
