import Foundation
import SwiftUI
import Combine

public enum BackupDestination: String, CaseIterable, Identifiable {
    case local = "local"
    case googleDrive = "google_drive"
    case webdav = "webdav"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .local: return "Device Storage"
        case .googleDrive: return "Google Drive (Zero Local Space)"
        case .webdav: return "WebDAV / Nextcloud / NAS"
        }
    }

    public var iconName: String {
        switch self {
        case .local: return "iphone"
        case .googleDrive: return "icloud.and.arrow.up.fill"
        case .webdav: return "server.rack"
        }
    }
}

public enum BackupScope: String, CaseIterable, Identifiable {
    case onDevice = "On Device"
    case googleDrive = "Google Drive"

    public var id: String { rawValue }
}

@MainActor
public final class BackupsViewModel: ObservableObject {
    @Published public var backups: [BackupRecord] = []
    @Published public var cloudBackups: [GoogleDriveFile] = []
    @Published public var selectedScope: BackupScope = .onDevice
    @Published public var isLoading: Bool = false
    @Published public var isCloudLoading: Bool = false
    @Published public var activeProgress: OperationProgress? = nil
    @Published public var isPerformingOperation: Bool = false
    @Published public var exportURL: URL? = nil
    @Published public var alertTitle: String = ""
    @Published public var alertMessage: String = ""
    @Published public var showAlert: Bool = false
    @Published public var restoreConfirmationRecord: BackupRecord? = nil
    @Published public var restoreConfirmationCloudFile: GoogleDriveFile? = nil
    @Published public var renameTargetRecord: BackupRecord? = nil

    private let fileManager = FileManager.default

    public init() {
        refreshBackups()
    }

    public func refreshBackups() {
        refreshLocalBackups()
        if GoogleDriveService.shared.isAuthenticated {
            refreshCloudBackups()
        }
    }

    // MARK: - 1. Local Backups
    public func refreshLocalBackups() {
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let backupDir = BackupEngine.shared.backupsDirectory
            let fm = FileManager.default

            // Ensure backup directory exists
            if !fm.fileExists(atPath: backupDir.path) {
                try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
            }

            guard let files = try? fm.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) else {
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

            let sorted = loaded.sorted { $0.createdAt > $1.createdAt }

            await MainActor.run {
                self.backups = sorted
                self.isLoading = false
            }
        }
    }

    // MARK: - 2. Cloud Backups (Google Drive)
    public func refreshCloudBackups() {
        guard GoogleDriveService.shared.isAuthenticated else { return }
        isCloudLoading = true
        Task {
            do {
                let files = try await GoogleDriveService.shared.fetchCloudBackups()
                self.cloudBackups = files
                self.isCloudLoading = false
            } catch {
                self.isCloudLoading = false
                self.alertTitle = "Google Drive"
                self.alertMessage = error.localizedDescription
                self.showAlert = true
            }
        }
    }

    // MARK: - Read Metadata from Local Archive
    nonisolated private func readMetadata(from archiveURL: URL) -> BackupRecord? {
        // 1. Fast extraction from tar.gz / PKZip via RestoreEngine
        if var record = RestoreEngine.shared.extractMetadata(from: archiveURL) {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: archiveURL.path),
               let size = attrs[.size] as? Int64 {
                record.fileSizeBytes = size
            }
            return record
        }

        let tempMetaDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Meta_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempMetaDir) }

        try? FileManager.default.createDirectory(at: tempMetaDir, withIntermediateDirectories: true)

        _ = PosixHelper.shared.execute("/usr/bin/ditto", arguments: ["-x", "-k", archiveURL.path, tempMetaDir.path])
        _ = PosixHelper.shared.execute("/bin/ditto", arguments: ["-x", "-k", archiveURL.path, tempMetaDir.path])

        var metaPath = tempMetaDir.appendingPathComponent("BackupMetadata.plist")
        if !FileManager.default.fileExists(atPath: metaPath.path) {
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

        if let attrs = try? FileManager.default.attributesOfItem(atPath: archiveURL.path),
           let size = attrs[.size] as? Int64 {
            record.fileSizeBytes = size
        }

        return record
    }

    // MARK: - Execute Streaming Backup (Local, Google Drive, or WebDAV)
    public func startBackup(
        for app: InstalledApp,
        mode: BackupMode,
        includeCaches: Bool,
        destination: BackupDestination,
        note: String
    ) {
        isPerformingOperation = true
        activeProgress = OperationProgress(stage: "Initializing", fractionCompleted: 0.0, statusDetail: "Starting zero-staging stream...")

        Task.detached(priority: .userInitiated) {
            do {
                if destination == .googleDrive {
                    let newRecord = try await BackupEngine.shared.createGoogleDriveStreamingBackup(
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
                        self.isPerformingOperation = false
                        self.activeProgress = nil
                        self.refreshCloudBackups()
                        self.alertTitle = "Cloud Backup Finished"
                        self.alertMessage = "Successfully backed up \(newRecord.appName) directly to Google Drive without consuming local device storage!"
                        self.showAlert = true
                    }
                } else if destination == .webdav {
                    let safeName = app.name.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
                    let timestamp = Int(Date().timeIntervalSince1970)
                    let archiveName = "\(safeName)_\(app.bundleIdentifier)_\(timestamp).adbk"

                    var uploadData = Data()
                    let newRecord = try await StreamingArchiveEngine.shared.streamBackup(
                        for: app,
                        mode: mode,
                        includeCaches: includeCaches,
                        note: note,
                        onProgress: { p in
                            Task { @MainActor in
                                self.activeProgress = p
                            }
                        },
                        onCompressedChunk: { chunk in
                            uploadData.append(chunk)
                        }
                    )

                    try await WebDAVService.shared.upload(data: uploadData, remoteFileName: archiveName)

                    await MainActor.run {
                        self.isPerformingOperation = false
                        self.activeProgress = nil
                        self.alertTitle = "WebDAV Upload Complete"
                        self.alertMessage = "Successfully streamed \(newRecord.appName) to your WebDAV server!"
                        self.showAlert = true
                    }
                } else {
                    let newRecord = try await BackupEngine.shared.createStreamingBackup(
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

    // MARK: - Restore from Local Backup
    public func startRestore(record: BackupRecord, options: SelectiveRestoreOptions = SelectiveRestoreOptions()) {
        isPerformingOperation = true
        activeProgress = OperationProgress(stage: "Initializing", fractionCompleted: 0.0, statusDetail: "Preparing restoration...")

        let archiveURL = BackupEngine.shared.backupsDirectory.appendingPathComponent(record.archiveFileName)

        Task.detached(priority: .userInitiated) {
            do {
                _ = try await RestoreEngine.shared.restore(from: archiveURL, options: options) { progress in
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

    // MARK: - Restore Direct from Google Drive
    public func startCloudRestore(file: GoogleDriveFile, options: SelectiveRestoreOptions = SelectiveRestoreOptions()) {
        isPerformingOperation = true
        activeProgress = OperationProgress(stage: "Downloading", fractionCompleted: 0.1, statusDetail: "Downloading \(file.name) from Google Drive...")

        let tempArchive = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("CloudRestore_\(UUID().uuidString)_\(file.name)")

        Task.detached(priority: .userInitiated) {
            do {
                try await GoogleDriveService.shared.downloadFile(file: file, destinationURL: tempArchive) { pct in
                    Task { @MainActor in
                        self.activeProgress = OperationProgress(
                            stage: "Downloading Cloud Backup",
                            fractionCompleted: pct * 0.5,
                            statusDetail: "Downloaded \(Int(pct * 100))% from Google Drive..."
                        )
                    }
                }

                _ = try await RestoreEngine.shared.restore(from: tempArchive, options: options) { progress in
                    Task { @MainActor in
                        var scaled = progress
                        scaled.fractionCompleted = 0.5 + progress.fractionCompleted * 0.5
                        self.activeProgress = scaled
                    }
                }

                try? FileManager.default.removeItem(at: tempArchive)

                await MainActor.run {
                    self.isPerformingOperation = false
                    self.activeProgress = nil
                    self.alertTitle = "Cloud Restore Complete"
                    self.alertMessage = "Successfully restored app from Google Drive backup!"
                    self.showAlert = true
                }
            } catch {
                try? FileManager.default.removeItem(at: tempArchive)
                await MainActor.run {
                    self.isPerformingOperation = false
                    self.activeProgress = nil
                    self.alertTitle = "Cloud Restore Failed"
                    self.alertMessage = error.localizedDescription
                    self.showAlert = true
                }
            }
        }
    }

    // MARK: - Download Cloud Backup to Local Storage
    public func downloadCloudBackupToLocal(file: GoogleDriveFile) {
        let dest = BackupEngine.shared.backupsDirectory.appendingPathComponent(file.name)
        isPerformingOperation = true
        activeProgress = OperationProgress(stage: "Downloading", fractionCompleted: 0.05, statusDetail: "Downloading \(file.name)...")

        Task.detached(priority: .userInitiated) {
            do {
                try await GoogleDriveService.shared.downloadFile(file: file, destinationURL: dest) { pct in
                    Task { @MainActor in
                        self.activeProgress = OperationProgress(
                            stage: "Downloading Cloud File",
                            fractionCompleted: pct,
                            statusDetail: "Downloading \(file.name): \(Int(pct * 100))%"
                        )
                    }
                }

                await MainActor.run {
                    self.isPerformingOperation = false
                    self.activeProgress = nil
                    self.refreshLocalBackups()
                    self.alertTitle = "Download Finished"
                    self.alertMessage = "Saved \(file.name) to on-device backups."
                    self.showAlert = true
                }
            } catch {
                await MainActor.run {
                    self.isPerformingOperation = false
                    self.activeProgress = nil
                    self.alertTitle = "Download Error"
                    self.alertMessage = error.localizedDescription
                    self.showAlert = true
                }
            }
        }
    }

    // MARK: - Delete Cloud Backup
    public func deleteCloudBackup(file: GoogleDriveFile) {
        Task {
            do {
                try await GoogleDriveService.shared.deleteCloudBackup(fileID: file.id)
                self.cloudBackups.removeAll { $0.id == file.id }
            } catch {
                self.alertTitle = "Delete Error"
                self.alertMessage = error.localizedDescription
                self.showAlert = true
            }
        }
    }

    // MARK: - Delete Local Backup with POSIX Checks
    public func deleteBackup(_ record: BackupRecord) {
        let archiveURL = BackupEngine.shared.backupsDirectory.appendingPathComponent(record.archiveFileName)

        if fileManager.fileExists(atPath: archiveURL.path) {
            do {
                try fileManager.removeItem(at: archiveURL)
                backups.removeAll { $0.id == record.id }
            } catch {
                alertTitle = "Delete Failed"
                alertMessage = "Unable to delete archive '\(record.archiveFileName)': \(error.localizedDescription)"
                showAlert = true
            }
        } else {
            // File does not exist on disk, remove stale record
            backups.removeAll { $0.id == record.id }
        }
    }

    // MARK: - Rename Local Backup with POSIX Validation
    public func renameBackup(_ record: BackupRecord, to newDisplayName: String) {
        let trimmed = newDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            alertTitle = "Invalid Name"
            alertMessage = "Backup name cannot be empty."
            showAlert = true
            return
        }

        // Sanitize characters to comply with POSIX filesystem standards
        let invalidChars = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let sanitized = trimmed.components(separatedBy: invalidChars).joined(separator: "_")

        let currentURL = BackupEngine.shared.backupsDirectory.appendingPathComponent(record.archiveFileName)
        guard fileManager.fileExists(atPath: currentURL.path) else {
            alertTitle = "File Not Found"
            alertMessage = "The backup file '\(record.archiveFileName)' does not exist on disk."
            showAlert = true
            return
        }

        let fileExt = currentURL.pathExtension.isEmpty ? "adbk" : currentURL.pathExtension
        let newFileName = sanitized.lowercased().hasSuffix(".\(fileExt.lowercased())") ? sanitized : "\(sanitized).\(fileExt)"
        let targetURL = BackupEngine.shared.backupsDirectory.appendingPathComponent(newFileName)

        if currentURL.path == targetURL.path {
            return // Same file, no action needed
        }

        guard !fileManager.fileExists(atPath: targetURL.path) else {
            alertTitle = "Name Conflict"
            alertMessage = "A backup file named '\(newFileName)' already exists. Please choose a different name."
            showAlert = true
            return
        }

        do {
            try fileManager.moveItem(at: currentURL, to: targetURL)
            PosixHelper.shared.fixPermissions(at: targetURL.path)

            // Update record in published backups array
            if let idx = backups.firstIndex(where: { $0.id == record.id }) {
                let current = backups[idx]
                let updated = BackupRecord(
                    id: current.id,
                    bundleIdentifier: current.bundleIdentifier,
                    appName: current.appName,
                    appVersion: current.appVersion,
                    appBuild: current.appBuild,
                    createdAt: current.createdAt,
                    mode: current.mode,
                    includesCaches: current.includesCaches,
                    note: current.note,
                    archiveFileName: newFileName,
                    fileSizeBytes: current.fileSizeBytes,
                    hasAppBundle: current.hasAppBundle,
                    hasDataContainer: current.hasDataContainer,
                    appGroupIDs: current.appGroupIDs,
                    deviceModel: current.deviceModel,
                    systemVersion: current.systemVersion
                )
                backups[idx] = updated
            }

            alertTitle = "Backup Renamed"
            alertMessage = "Successfully renamed to '\(newFileName)'."
            showAlert = true
        } catch {
            alertTitle = "Rename Failed"
            alertMessage = "POSIX filesystem error: \(error.localizedDescription)"
            showAlert = true
        }
    }

    // MARK: - Import Backup with Security-Scoped Resource Handling
    public func importArchive(from sourceURL: URL) {
        let isSecurityScoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let dest = BackupEngine.shared.backupsDirectory.appendingPathComponent(sourceURL.lastPathComponent)

        if fileManager.fileExists(atPath: dest.path) {
            try? fileManager.removeItem(at: dest)
        }

        do {
            try fileManager.copyItem(at: sourceURL, to: dest)
            PosixHelper.shared.fixPermissions(at: dest.path)
            refreshLocalBackups()
            alertTitle = "Import Successful"
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
