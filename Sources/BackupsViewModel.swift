import Foundation
import SwiftUI
import Combine

@MainActor
public final class BackupsViewModel: ObservableObject {
    @Published public var backups: [BackupRecord] = []
    @Published public var cloudBackups: [GoogleDriveFile] = []
    @Published public var webdavBackups: [WebDAVFile] = []
    @Published public var selectedScope: BackupScope = .onDevice
    @Published public var isLoading: Bool = false
    @Published public var isCloudLoading: Bool = false
    @Published public var isWebDAVLoading: Bool = false
    @Published public var activeProgress: OperationProgress? = nil
    @Published public var isPerformingOperation: Bool = false
    @Published public var exportURL: URL? = nil
    @Published public var alertTitle: String = ""
    @Published public var alertMessage: String = ""
    @Published public var showAlert: Bool = false
    @Published public var restoreConfirmationRecord: BackupRecord? = nil
    @Published public var restoreConfirmationCloudFile: GoogleDriveFile? = nil
    @Published public var restoreConfirmationWebDAVFile: WebDAVFile? = nil
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
        if WebDAVService.shared.isConfigured {
            refreshWebDAVBackups()
        }
    }

    // MARK: - 1. Local Backups
    public func refreshLocalBackups() {
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let backupDir = BackupEngine.shared.backupsDirectory
            let fm = FileManager.default

            if !fm.fileExists(atPath: backupDir.path) {
                try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
            }

            guard let files = try? fm.contentsOfDirectory(
                at: backupDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else {
                await MainActor.run {
                    self.backups = []
                    self.isLoading = false
                }
                return
            }

            var loaded: [BackupRecord] = []
            let archives = files.filter {
                let ext = $0.pathExtension.lowercased()
                return ext == "adbk" || ext == "zip"
            }

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

    // MARK: - 3. WebDAV / NAS Backups
    public func refreshWebDAVBackups() {
        guard WebDAVService.shared.isConfigured else { return }
        isWebDAVLoading = true
        Task {
            do {
                let files = try await WebDAVService.shared.fetchRemoteFiles()
                self.webdavBackups = files.filter {
                    let lower = $0.name.lowercased()
                    return lower.hasSuffix(".adbk") || lower.hasSuffix(".zip")
                }
                self.isWebDAVLoading = false
            } catch {
                self.isWebDAVLoading = false
                self.alertTitle = "WebDAV / NAS"
                self.alertMessage = error.localizedDescription
                self.showAlert = true
            }
        }
    }

    // MARK: - Read Metadata from Local Archive
    nonisolated private func readMetadata(from archiveURL: URL) -> BackupRecord? {
        let filename = archiveURL.lastPathComponent
        let attrs = try? FileManager.default.attributesOfItem(atPath: archiveURL.path)
        let fileSize = (attrs?[.size] as? Int64) ?? 0
        let modDate = (attrs?[.modificationDate] as? Date) ?? Date()

        // 0. Encrypted AES-256-GCM archives cannot have BackupMetadata.plist read without password
        if CryptoService.shared.isEncryptedFile(at: archiveURL) {
            let base = filename
                .replacingOccurrences(of: ".enc.adbk", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: ".adbk", with: "", options: .caseInsensitive)
            let parts = base.split(separator: "_").map(String.init)
            let guessedName = parts.first ?? base
            let guessedBundle = parts.count >= 2 ? parts[1] : "encrypted.archive"
            return BackupRecord(
                bundleIdentifier: guessedBundle,
                appName: guessedName,
                appVersion: "Encrypted",
                appBuild: "-",
                createdAt: modDate,
                mode: .dataOnly,
                includesCaches: false,
                note: "AES-256-GCM Encrypted Backup",
                archiveFileName: filename,
                fileSizeBytes: fileSize,
                hasAppBundle: false,
                hasDataContainer: true,
                isEncrypted: true
            )
        }

        // 1. Fast extraction from tar.gz via RestoreEngine
        if var record = RestoreEngine.shared.extractMetadata(from: archiveURL) {
            record.archiveFileName = filename
            if fileSize > 0 { record.fileSizeBytes = fileSize }
            return record
        }

        // 2. Legacy PKZip fallback (run only one available ditto binary)
        let dittoPath = FileManager.default.fileExists(atPath: "/usr/bin/ditto") ? "/usr/bin/ditto" : "/bin/ditto"
        if FileManager.default.fileExists(atPath: dittoPath) {
            let tempMetaDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Meta_\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tempMetaDir) }
            try? FileManager.default.createDirectory(at: tempMetaDir, withIntermediateDirectories: true)

            _ = PosixHelper.shared.execute(dittoPath, arguments: ["-x", "-k", archiveURL.path, tempMetaDir.path])

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

            if let data = try? Data(contentsOf: metaPath),
               var record = try? PropertyListDecoder().decode(BackupRecord.self, from: data) {
                record.archiveFileName = filename
                if fileSize > 0 { record.fileSizeBytes = fileSize }
                return record
            }
        }

        return BackupRecord(
            bundleIdentifier: "unknown.archive",
            appName: filename.replacingOccurrences(of: ".\(archiveURL.pathExtension)", with: ""),
            appVersion: "1.0",
            appBuild: "1",
            createdAt: modDate,
            mode: .dataOnly,
            includesCaches: false,
            archiveFileName: filename,
            fileSizeBytes: fileSize,
            hasAppBundle: false,
            hasDataContainer: true
        )
    }

    // MARK: - Execute Streaming Backup (Local, Google Drive, or WebDAV)
    public func startBackup(
        for app: InstalledApp,
        mode: BackupMode,
        destination: BackupDestination,
        includeCaches: Bool,
        includeKeychain: Bool = true,
        includeAppGroups: Bool = true,
        encryptionPassword: String? = nil,
        note: String
    ) {
        isPerformingOperation = true
        activeProgress = OperationProgress(stage: "Initializing", fractionCompleted: 0.0, statusDetail: "Preparing streaming backup...")

        let retentionLimit = SettingsViewModel.savedMaxBackupsPerApp

        Task.detached(priority: .userInitiated) {
            do {
                if destination == .googleDrive {
                    let newRecord = try await BackupEngine.shared.createGoogleDriveStreamingBackup(
                        for: app,
                        mode: mode,
                        includeCaches: includeCaches,
                        includeKeychain: includeKeychain,
                        includeAppGroups: includeAppGroups,
                        encryptionPassword: encryptionPassword,
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
                        self.alertTitle = "Cloud Backup Complete"
                        self.alertMessage = "Successfully streamed \(newRecord.appName) (\(newRecord.formattedSize)) directly to Google Drive!"
                        self.showAlert = true
                    }
                } else if destination == .webdav {
                    let newRecord = try await BackupEngine.shared.createWebDAVStreamingBackup(
                        for: app,
                        mode: mode,
                        includeCaches: includeCaches,
                        includeKeychain: includeKeychain,
                        includeAppGroups: includeAppGroups,
                        encryptionPassword: encryptionPassword,
                        note: note
                    ) { progress in
                        Task { @MainActor in
                            self.activeProgress = progress
                        }
                    }

                    await MainActor.run {
                        self.isPerformingOperation = false
                        self.activeProgress = nil
                        self.refreshWebDAVBackups()
                        self.alertTitle = "WebDAV Upload Complete"
                        self.alertMessage = "Successfully uploaded \(newRecord.appName) (\(newRecord.formattedSize)) to your WebDAV server!"
                        self.showAlert = true
                    }
                } else {
                    let newRecord = try await BackupEngine.shared.createStreamingBackup(
                        for: app,
                        mode: mode,
                        includeCaches: includeCaches,
                        includeKeychain: includeKeychain,
                        includeAppGroups: includeAppGroups,
                        encryptionPassword: encryptionPassword,
                        note: note
                    ) { progress in
                        Task { @MainActor in
                            self.activeProgress = progress
                        }
                    }

                    if retentionLimit > 0 {
                        BackupEngine.shared.pruneOldBackups(for: app.bundleIdentifier, keepNewest: retentionLimit)
                    }

                    await MainActor.run {
                        self.isPerformingOperation = false
                        self.activeProgress = nil
                        if retentionLimit > 0 {
                            self.refreshLocalBackups()
                        } else {
                            self.backups.insert(newRecord, at: 0)
                        }
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

    // MARK: - Verify Local Archive Integrity (SHA-256 + Metadata)
    public func verifyBackup(_ record: BackupRecord) {
        let archiveURL = fileURL(for: record)
        isPerformingOperation = true
        activeProgress = OperationProgress(stage: "Verifying Archive", fractionCompleted: 0.35, statusDetail: "Computing SHA-256 checksum for \(record.archiveFileName)...")

        Task.detached(priority: .userInitiated) {
            let result = BackupEngine.shared.verifyArchive(at: archiveURL)
            await MainActor.run {
                self.isPerformingOperation = false
                self.activeProgress = nil
                self.alertTitle = result.isValid ? "Archive Verified" : "Integrity Check Failed"
                self.alertMessage = result.detail
                self.showAlert = true
            }
        }
    }

    // MARK: - Restore from Local Backup
    public func startRestore(
        record: BackupRecord,
        options: SelectiveRestoreOptions = SelectiveRestoreOptions(),
        password: String? = nil
    ) {
        isPerformingOperation = true
        activeProgress = OperationProgress(stage: "Initializing", fractionCompleted: 0.0, statusDetail: "Preparing restoration...")

        let archiveURL = BackupEngine.shared.backupsDirectory.appendingPathComponent(record.archiveFileName)

        Task.detached(priority: .userInitiated) {
            do {
                _ = try await RestoreEngine.shared.restore(from: archiveURL, options: options, password: password) { progress in
                    Task { @MainActor in
                        self.activeProgress = progress
                    }
                }

                await MainActor.run {
                    self.isPerformingOperation = false
                    self.activeProgress = nil
                    self.refreshLocalBackups()
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
    public func startCloudRestore(
        file: GoogleDriveFile,
        options: SelectiveRestoreOptions = SelectiveRestoreOptions(),
        password: String? = nil
    ) {
        isPerformingOperation = true
        activeProgress = OperationProgress(stage: "Downloading", fractionCompleted: 0.1, statusDetail: "Downloading \(file.name) from Google Drive...")

        let tempArchive = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("CloudRestore_\(UUID().uuidString)_\(file.name)")

        Task.detached(priority: .userInitiated) {
            defer { try? FileManager.default.removeItem(at: tempArchive) }
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

                _ = try await RestoreEngine.shared.restore(from: tempArchive, options: options, password: password) { progress in
                    Task { @MainActor in
                        var scaled = progress
                        scaled.fractionCompleted = 0.5 + progress.fractionCompleted * 0.5
                        self.activeProgress = scaled
                    }
                }

                await MainActor.run {
                    self.isPerformingOperation = false
                    self.activeProgress = nil
                    self.refreshLocalBackups()
                    self.alertTitle = "Cloud Restore Complete"
                    self.alertMessage = "Successfully restored app from Google Drive backup!"
                    self.showAlert = true
                }
            } catch {
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

    // MARK: - Restore Direct from WebDAV / NAS
    public func startWebDAVRestore(
        file: WebDAVFile,
        options: SelectiveRestoreOptions = SelectiveRestoreOptions(),
        password: String? = nil
    ) {
        isPerformingOperation = true
        activeProgress = OperationProgress(stage: "Downloading", fractionCompleted: 0.1, statusDetail: "Downloading \(file.name) from WebDAV...")

        let tempArchive = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("WebDAVRestore_\(UUID().uuidString)_\(file.name)")

        Task.detached(priority: .userInitiated) {
            defer { try? FileManager.default.removeItem(at: tempArchive) }
            do {
                try await WebDAVService.shared.download(remoteFileName: file.name, destinationURL: tempArchive)

                await MainActor.run {
                    self.activeProgress = OperationProgress(stage: "Restoring", fractionCompleted: 0.5, statusDetail: "Downloaded \(file.name). Restoring container...")
                }

                _ = try await RestoreEngine.shared.restore(from: tempArchive, options: options, password: password) { progress in
                    Task { @MainActor in
                        var scaled = progress
                        scaled.fractionCompleted = 0.5 + progress.fractionCompleted * 0.5
                        self.activeProgress = scaled
                    }
                }

                await MainActor.run {
                    self.isPerformingOperation = false
                    self.activeProgress = nil
                    self.refreshLocalBackups()
                    self.alertTitle = "WebDAV Restore Complete"
                    self.alertMessage = "Successfully restored app from \(file.name)!"
                    self.showAlert = true
                }
            } catch {
                await MainActor.run {
                    self.isPerformingOperation = false
                    self.activeProgress = nil
                    self.alertTitle = "WebDAV Restore Failed"
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

    // MARK: - Download WebDAV Backup to Local Storage
    public func downloadWebDAVBackupToLocal(file: WebDAVFile) {
        let dest = BackupEngine.shared.backupsDirectory.appendingPathComponent(file.name)
        isPerformingOperation = true
        activeProgress = OperationProgress(stage: "Downloading WebDAV", fractionCompleted: 0.25, statusDetail: "Downloading \(file.name) from WebDAV...")

        Task.detached(priority: .userInitiated) {
            do {
                try await WebDAVService.shared.download(remoteFileName: file.name, destinationURL: dest)

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
                    self.alertTitle = "WebDAV Download Error"
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

    // MARK: - Delete WebDAV Backup
    public func deleteWebDAVBackup(file: WebDAVFile) {
        Task {
            do {
                try await WebDAVService.shared.deleteFile(remoteFileName: file.name)
                self.webdavBackups.removeAll { $0.id == file.id }
            } catch {
                self.alertTitle = "WebDAV Delete Error"
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
            return
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

            if let idx = backups.firstIndex(where: { $0.id == record.id }) {
                var updated = backups[idx]
                updated.archiveFileName = newFileName
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
