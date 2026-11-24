import SwiftUI

private enum BackupsActiveSheet: Identifiable {
    case documentPicker
    case selectiveRestore(BackupRecord)
    case rename(BackupRecord)

    var id: String {
        switch self {
        case .documentPicker: return "documentPicker"
        case .selectiveRestore(let r): return "restore_\(r.id.uuidString)"
        case .rename(let r): return "rename_\(r.id.uuidString)"
        }
    }
}

private enum BackupsActiveActionSheet: Identifiable {
    case restoreCloud(GoogleDriveFile)
    case restoreWebDAV(WebDAVFile)
    case deleteLocal(BackupRecord)
    case deleteCloud(GoogleDriveFile)
    case deleteWebDAV(WebDAVFile)
    case exportLocal(BackupRecord)

    var id: String {
        switch self {
        case .restoreCloud(let f): return "restoreCloud_\(f.id)"
        case .restoreWebDAV(let f): return "restoreWebDAV_\(f.id)"
        case .deleteLocal(let r): return "deleteLocal_\(r.id.uuidString)"
        case .deleteCloud(let f): return "deleteCloud_\(f.id)"
        case .deleteWebDAV(let f): return "deleteWebDAV_\(f.id)"
        case .exportLocal(let r): return "exportLocal_\(r.id.uuidString)"
        }
    }
}

public struct BackupsListView: View {
    @EnvironmentObject var backupsVM: BackupsViewModel
    @ObservedObject var googleDrive = GoogleDriveService.shared
    @ObservedObject var webdav = WebDAVService.shared

    @State private var activeSheet: BackupsActiveSheet? = nil
    @State private var activeActionSheet: BackupsActiveActionSheet? = nil

    public init() {}

    private var navigationTitleText: String {
        switch backupsVM.selectedScope {
        case .onDevice: return "Device Backups (\(backupsVM.backups.count))"
        case .googleDrive: return "Cloud Backups (\(backupsVM.cloudBackups.count))"
        case .webdav: return "WebDAV Backups (\(backupsVM.webdavBackups.count))"
        }
    }

    public var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Scope Switcher (On Device vs Google Drive vs WebDAV)
                Picker("Storage Scope", selection: $backupsVM.selectedScope) {
                    ForEach(BackupScope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 6)

                // Active Operation Banner
                if backupsVM.isPerformingOperation, let progress = backupsVM.activeProgress {
                    VStack(spacing: 8) {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text(progress.stage)
                                .font(.system(size: 15, weight: .bold))
                            Spacer()
                            Text("\(Int(progress.fractionCompleted * 100))%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        ProgressView(value: progress.fractionCompleted)
                            .progressViewStyle(LinearProgressViewStyle(tint: .blue))

                        Text(progress.statusDetail)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(12)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
                }

                // Scope Content
                switch backupsVM.selectedScope {
                case .onDevice:
                    onDeviceList
                case .googleDrive:
                    googleDriveList
                case .webdav:
                    webdavList
                }
            }
            .navigationTitle(navigationTitleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if backupsVM.selectedScope == .onDevice {
                        Button(action: { activeSheet = .documentPicker }) {
                            Label("Import", systemImage: "square.and.arrow.down")
                        }
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        switch backupsVM.selectedScope {
                        case .onDevice: backupsVM.refreshLocalBackups()
                        case .googleDrive: backupsVM.refreshCloudBackups()
                        case .webdav: backupsVM.refreshWebDAVBackups()
                        }
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            // Single consolidated .sheet modifier (prevents iOS 15 SwiftUI presentation drops)
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .documentPicker:
                    DocumentPicker { url in
                        backupsVM.importArchive(from: url)
                    }
                case .selectiveRestore(let record):
                    SelectiveRestoreSheet(record: record) {
                        backupsVM.refreshLocalBackups()
                    }
                case .rename(let target):
                    RenameBackupSheet(record: target) { newName in
                        backupsVM.renameBackup(target, to: newName)
                    }
                }
            }
            .alert(isPresented: $backupsVM.showAlert) {
                Alert(
                    title: Text(backupsVM.alertTitle),
                    message: Text(backupsVM.alertMessage),
                    dismissButton: .default(Text("OK"))
                )
            }
            // Single consolidated .actionSheet modifier (prevents iOS 15 SwiftUI actionSheet collisions)
            .actionSheet(item: $activeActionSheet) { sheet in
                switch sheet {
                case .restoreCloud(let file):
                    return ActionSheet(
                        title: Text("Restore \(file.name)?"),
                        message: Text("Download and restore this cloud archive directly into the local application container?"),
                        buttons: [
                            .destructive(Text("Download & Restore")) {
                                backupsVM.startCloudRestore(file: file)
                            },
                            .cancel()
                        ]
                    )
                case .restoreWebDAV(let file):
                    return ActionSheet(
                        title: Text("Restore \(file.name)?"),
                        message: Text("Download and restore this WebDAV archive directly into the local application container?"),
                        buttons: [
                            .destructive(Text("Download & Restore")) {
                                backupsVM.startWebDAVRestore(file: file)
                            },
                            .cancel()
                        ]
                    )
                case .deleteLocal(let target):
                    return ActionSheet(
                        title: Text("Delete Backup?"),
                        message: Text("Are you sure you want to permanently delete the backup archive '\(target.archiveFileName)'?"),
                        buttons: [
                            .destructive(Text("Delete Archive")) {
                                backupsVM.deleteBackup(target)
                            },
                            .cancel()
                        ]
                    )
                case .deleteCloud(let target):
                    return ActionSheet(
                        title: Text("Delete from Google Drive?"),
                        message: Text("Are you sure you want to permanently delete \(target.name) from your Google Drive?"),
                        buttons: [
                            .destructive(Text("Delete Cloud File")) {
                                backupsVM.deleteCloudBackup(file: target)
                            },
                            .cancel()
                        ]
                    )
                case .deleteWebDAV(let target):
                    return ActionSheet(
                        title: Text("Delete from WebDAV?"),
                        message: Text("Are you sure you want to permanently delete \(target.name) from your WebDAV server?"),
                        buttons: [
                            .destructive(Text("Delete Remote File")) {
                                backupsVM.deleteWebDAVBackup(file: target)
                            },
                            .cancel()
                        ]
                    )
                case .exportLocal(let record):
                    return ActionSheet(
                        title: Text("Export \(record.appName) Backup"),
                        message: Text(record.archiveFileName),
                        buttons: [
                            .default(Text("Share / AirDrop / Save to Files")) {
                                let url = backupsVM.fileURL(for: record)
                                presentShareSheet(url: url)
                            },
                            .default(Text("Open In... (iOS 16 TrollStore Safe)")) {
                                let url = backupsVM.fileURL(for: record)
                                presentOpenInMenu(url: url)
                            },
                            .default(Text("Save via Files Picker")) {
                                let url = backupsVM.fileURL(for: record)
                                presentExportPicker(url: url)
                            },
                            .default(Text("Reveal in Filza / Copy Path")) {
                                let url = backupsVM.fileURL(for: record)
                                UIPasteboard.general.string = url.path
                                if !openInFilza(url: url) {
                                    backupsVM.alertTitle = "Archive Path Copied"
                                    backupsVM.alertMessage = "Path copied to clipboard:\n\(url.path)"
                                    backupsVM.showAlert = true
                                }
                            },
                            .cancel()
                        ]
                    )
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    // MARK: - On Device List
    private var onDeviceList: some View {
        Group {
            if backupsVM.isLoading && backupsVM.backups.isEmpty {
                Spacer()
                ProgressView("Loading backups...")
                Spacer()
            } else if backupsVM.backups.isEmpty {
                Spacer()
                VStack(spacing: 14) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 52))
                        .foregroundColor(.secondary)
                    Text("No On-Device Backups")
                        .font(.headline)
                    Text("Go to Applications to create your first zero-staging backup, or import an existing archive.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                Spacer()
            } else {
                List {
                    ForEach(backupsVM.backups) { record in
                        BackupCardView(
                            record: record,
                            onRestore: {
                                activeSheet = .selectiveRestore(record)
                            },
                            onVerify: {
                                backupsVM.verifyBackup(record)
                            },
                            onShare: {
                                activeActionSheet = .exportLocal(record)
                            },
                            onRename: {
                                activeSheet = .rename(record)
                            },
                            onDelete: {
                                activeActionSheet = .deleteLocal(record)
                            }
                        )
                    }
                }
                .listStyle(InsetGroupedListStyle())
                .refreshable {
                    backupsVM.refreshLocalBackups()
                }
            }
        }
    }

    // MARK: - Google Drive List
    private var googleDriveList: some View {
        Group {
            if !googleDrive.isAuthenticated {
                Spacer()
                VStack(spacing: 16) {
                    Image(systemName: "icloud.slash")
                        .font(.system(size: 54))
                        .foregroundColor(.orange)

                    Text("Google Drive Not Connected")
                        .font(.headline)

                    Text("Connect your Google Drive account to stream backups directly to cloud storage without taking any local device space.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    Button(action: { googleDrive.signIn() }) {
                        Label("Sign In with Google", systemImage: "person.badge.key.fill")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(Color.blue)
                            .cornerRadius(10)
                    }
                }
                Spacer()
            } else if backupsVM.isCloudLoading && backupsVM.cloudBackups.isEmpty {
                Spacer()
                ProgressView("Fetching Google Drive backups...")
                Spacer()
            } else if backupsVM.cloudBackups.isEmpty {
                Spacer()
                VStack(spacing: 14) {
                    Image(systemName: "icloud")
                        .font(.system(size: 52))
                        .foregroundColor(.secondary)
                    Text("No Cloud Backups")
                        .font(.headline)
                    Text("In Applications tab, select an app and choose 'Google Drive' as destination to create a zero-footprint cloud backup.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                Spacer()
            } else {
                List {
                    ForEach(backupsVM.cloudBackups) { file in
                        CloudBackupCardView(
                            file: file,
                            folderName: googleDrive.targetFolderName,
                            onRestore: {
                                activeActionSheet = .restoreCloud(file)
                            },
                            onDownload: {
                                backupsVM.downloadCloudBackupToLocal(file: file)
                            },
                            onDelete: {
                                activeActionSheet = .deleteCloud(file)
                            }
                        )
                    }
                }
                .listStyle(InsetGroupedListStyle())
                .refreshable {
                    backupsVM.refreshCloudBackups()
                }
            }
        }
    }

    // MARK: - WebDAV / NAS List
    private var webdavList: some View {
        Group {
            if !webdav.isConfigured {
                Spacer()
                VStack(spacing: 16) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 54))
                        .foregroundColor(.orange)

                    Text("WebDAV / NAS Not Configured")
                        .font(.headline)

                    Text("Configure your Nextcloud, Synology NAS, or local Rclone WebDAV bridge in the Settings tab to browse and restore remote backups.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                Spacer()
            } else if backupsVM.isWebDAVLoading && backupsVM.webdavBackups.isEmpty {
                Spacer()
                ProgressView("Fetching WebDAV backups...")
                Spacer()
            } else if backupsVM.webdavBackups.isEmpty {
                Spacer()
                VStack(spacing: 14) {
                    Image(systemName: "externaldrive.connected.to.line.below")
                        .font(.system(size: 52))
                        .foregroundColor(.secondary)
                    Text("No WebDAV Backups Found")
                        .font(.headline)
                    Text("Select 'WebDAV / NAS' when creating a backup, or tap refresh to scan \(webdav.serverURL).")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                Spacer()
            } else {
                List {
                    ForEach(backupsVM.webdavBackups) { file in
                        WebDAVBackupCardView(
                            file: file,
                            serverURL: webdav.serverURL,
                            onRestore: {
                                activeActionSheet = .restoreWebDAV(file)
                            },
                            onDownload: {
                                backupsVM.downloadWebDAVBackupToLocal(file: file)
                            },
                            onDelete: {
                                activeActionSheet = .deleteWebDAV(file)
                            }
                        )
                    }
                }
                .listStyle(InsetGroupedListStyle())
                .refreshable {
                    backupsVM.refreshWebDAVBackups()
                }
            }
        }
        .onAppear {
            if webdav.isConfigured && backupsVM.webdavBackups.isEmpty {
                backupsVM.refreshWebDAVBackups()
            }
        }
    }
}

// MARK: - Helper Identifiable Wrapper for ShareSheet
struct URLItem: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - Rename Backup Sheet
struct RenameBackupSheet: View {
    let record: BackupRecord
    let onRename: (String) -> Void
    @Environment(\.presentationMode) var presentationMode

    @State private var inputName: String = ""

    init(record: BackupRecord, onRename: @escaping (String) -> Void) {
        self.record = record
        self.onRename = onRename
        let baseName = (record.archiveFileName as NSString).deletingPathExtension
        _inputName = State(initialValue: baseName)
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Current Archive")) {
                    Text(record.archiveFileName)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.secondary)
                    HStack {
                        Text("Application:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(record.appName)
                            .font(.system(size: 13, weight: .semibold))
                    }
                }

                Section(header: Text("New Name"), footer: Text("Characters like / : \\ ? * < > will be replaced with underscores.")) {
                    TextField("Enter new file name", text: $inputName)
                        .font(.system(size: 14, design: .monospaced))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)

                    let ext = (record.archiveFileName as NSString).pathExtension
                    let preview = inputName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\(inputName).\(ext.isEmpty ? "adbk" : ext)"
                    if !preview.isEmpty {
                        HStack {
                            Text("Will be saved as:")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(preview)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.blue)
                        }
                    }
                }
            }
            .navigationTitle("Rename Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = inputName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            presentationMode.wrappedValue.dismiss()
                            onRename(trimmed)
                        }
                    }
                    .disabled(inputName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

// MARK: - Cloud Backup Card View
struct CloudBackupCardView: View {
    let file: GoogleDriveFile
    let folderName: String
    let onRestore: () -> Void
    let onDownload: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                AppIconView(
                    bundleIdentifier: AppIconCache.extractBundleIdentifier(fromArchiveName: file.name),
                    fallbackSystemName: "icloud.fill",
                    fallbackColor: .blue,
                    size: 42
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(file.name)
                            .font(.headline)
                            .lineLimit(1)
                        if let ver = BackupEngine.extractBackupVersion(from: file.name) {
                            Text("v\(ver)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.blue.opacity(0.16))
                                .foregroundColor(.blue)
                                .cornerRadius(4)
                        }
                    }

                    Text("Google Drive \u{2022} \(folderName)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text("Cloud")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.blue.opacity(0.15))
                    .foregroundColor(.blue)
                    .cornerRadius(6)
            }

            HStack {
                Text(file.formattedDate)
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Spacer()

                Text(file.formattedSize)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
            }

            Divider()

            HStack(spacing: 14) {
                Button(action: onRestore) {
                    Label("Restore", systemImage: "arrow.counterclockwise.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.green)
                }
                .buttonStyle(BorderlessButtonStyle())

                Spacer()

                Button(action: onDownload) {
                    Label("Download", systemImage: "arrow.down.circle")
                        .font(.subheadline)
                        .foregroundColor(.blue)
                }
                .buttonStyle(BorderlessButtonStyle())

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.subheadline)
                        .foregroundColor(.red)
                }
                .buttonStyle(BorderlessButtonStyle())
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - WebDAV Backup Card View
struct WebDAVBackupCardView: View {
    let file: WebDAVFile
    let serverURL: String
    let onRestore: () -> Void
    let onDownload: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                AppIconView(
                    bundleIdentifier: AppIconCache.extractBundleIdentifier(fromArchiveName: file.name),
                    fallbackSystemName: "server.rack",
                    fallbackColor: .purple,
                    size: 42
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(file.name)
                            .font(.headline)
                            .lineLimit(1)
                        if let ver = BackupEngine.extractBackupVersion(from: file.name) {
                            Text("v\(ver)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.purple.opacity(0.16))
                                .foregroundColor(.purple)
                                .cornerRadius(4)
                        }
                    }

                    Text(serverURL)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text("WebDAV")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.purple.opacity(0.15))
                    .foregroundColor(.purple)
                    .cornerRadius(6)
            }

            HStack {
                Text(file.formattedDate)
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Spacer()

                Text(file.formattedSize)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
            }

            Divider()

            HStack(spacing: 14) {
                Button(action: onRestore) {
                    Label("Restore", systemImage: "arrow.counterclockwise.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.green)
                }
                .buttonStyle(BorderlessButtonStyle())

                Spacer()

                Button(action: onDownload) {
                    Label("Download", systemImage: "arrow.down.circle")
                        .font(.subheadline)
                        .foregroundColor(.blue)
                }
                .buttonStyle(BorderlessButtonStyle())

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.subheadline)
                        .foregroundColor(.red)
                }
                .buttonStyle(BorderlessButtonStyle())
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Local Backup Card View
struct BackupCardView: View {
    let record: BackupRecord
    let onRestore: () -> Void
    let onVerify: () -> Void
    let onShare: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    AppIconView(
                        bundleIdentifier: record.bundleIdentifier,
                        fallbackSystemName: record.mode == .full ? "shippingbox.fill" : "internaldrive.fill",
                        fallbackColor: record.mode == .full ? .purple : .blue,
                        size: 42
                    )
                    if record.isEncrypted {
                        Image(systemName: "lock.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.orange)
                            .background(Circle().fill(Color(UIColor.systemBackground)))
                            .offset(x: 3, y: 3)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(record.appName)
                            .font(.headline)
                            .lineLimit(1)
                        if let ver = BackupEngine.extractBackupVersion(from: record.archiveFileName) {
                            Text("v\(ver)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.blue.opacity(0.16))
                                .foregroundColor(.blue)
                                .cornerRadius(4)
                        }
                        if record.isEncrypted {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    }

                    Text(record.archiveFileName)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(record.isEncrypted ? "AES-256" : record.mode.title)
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(record.isEncrypted ? Color.orange.opacity(0.15) : (record.mode == .full ? Color.purple.opacity(0.15) : Color.blue.opacity(0.15)))
                    .foregroundColor(record.isEncrypted ? .orange : (record.mode == .full ? .purple : .blue))
                    .cornerRadius(6)
            }

            if !record.note.isEmpty {
                Text("Note: \(record.note)")
                    .font(.caption)
                    .foregroundColor(.primary)
                    .padding(6)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(6)
            }

            HStack {
                Text(record.formattedDate)
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Spacer()

                Text(record.formattedSize)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
            }

            Divider()

            HStack(spacing: 12) {
                Button(action: onRestore) {
                    Label("Restore", systemImage: "arrow.counterclockwise.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.green)
                }
                .buttonStyle(BorderlessButtonStyle())

                Spacer()

                Button(action: onVerify) {
                    Image(systemName: "checkmark.shield")
                        .font(.subheadline)
                        .foregroundColor(.teal)
                }
                .buttonStyle(BorderlessButtonStyle())

                Button(action: onRename) {
                    Image(systemName: "pencil")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(BorderlessButtonStyle())

                Button(action: onShare) {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .font(.subheadline)
                        .foregroundColor(.blue)
                }
                .buttonStyle(BorderlessButtonStyle())

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.subheadline)
                        .foregroundColor(.red)
                }
                .buttonStyle(BorderlessButtonStyle())
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(action: onRestore) {
                Label("Restore Backup", systemImage: "arrow.counterclockwise")
            }
            Button(action: onVerify) {
                Label("Verify Integrity (SHA-256)", systemImage: "checkmark.shield")
            }
            Button(action: onRename) {
                Label("Rename Archive", systemImage: "pencil")
            }
            Button(action: onShare) {
                Label("Export / Share", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("Delete Archive", systemImage: "trash")
            }
        }
    }
}
