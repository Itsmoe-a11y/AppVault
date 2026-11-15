import SwiftUI

public struct BackupsListView: View {
    @EnvironmentObject var backupsVM: BackupsViewModel
    @ObservedObject var googleDrive = GoogleDriveService.shared

    @State private var showDocumentPicker = false
    @State private var deleteTarget: BackupRecord? = nil
    @State private var deleteCloudTarget: GoogleDriveFile? = nil

    public init() {}

    public var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Scope Switcher (On Device vs Google Drive)
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
                if backupsVM.selectedScope == .onDevice {
                    onDeviceList
                } else {
                    googleDriveList
                }
            }
            .navigationTitle(backupsVM.selectedScope == .onDevice ? "Device Backups (\(backupsVM.backups.count))" : "Cloud Backups (\(backupsVM.cloudBackups.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if backupsVM.selectedScope == .onDevice {
                        Button(action: { showDocumentPicker = true }) {
                            Label("Import", systemImage: "square.and.arrow.down")
                        }
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        if backupsVM.selectedScope == .onDevice {
                            backupsVM.refreshLocalBackups()
                        } else {
                            backupsVM.refreshCloudBackups()
                        }
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .sheet(isPresented: $showDocumentPicker) {
                DocumentPicker { url in
                    backupsVM.importArchive(from: url)
                }
            }
            .sheet(item: Binding<URLItem?>(
                get: { backupsVM.exportURL.map { URLItem(url: $0) } },
                set: { backupsVM.exportURL = $0?.url }
            )) { item in
                ShareSheet(activityItems: [item.url])
            }
            .alert(isPresented: $backupsVM.showAlert) {
                Alert(
                    title: Text(backupsVM.alertTitle),
                    message: Text(backupsVM.alertMessage),
                    dismissButton: .default(Text("OK"))
                )
            }
            .sheet(item: $backupsVM.restoreConfirmationRecord) { record in
                SelectiveRestoreSheet(record: record) { options in
                    backupsVM.startRestore(record: record, options: options)
                }
            }
            .actionSheet(item: $backupsVM.restoreConfirmationCloudFile) { file in
                ActionSheet(
                    title: Text("Restore \(file.name)?"),
                    message: Text("Download and restore this cloud archive directly into the local application container?"),
                    buttons: [
                        .destructive(Text("Download & Restore")) {
                            backupsVM.startCloudRestore(file: file)
                        },
                        .cancel()
                    ]
                )
            }
            .actionSheet(item: $deleteTarget) { target in
                ActionSheet(
                    title: Text("Delete Backup?"),
                    message: Text("Are you sure you want to permanently delete the backup archive for \(target.appName)?"),
                    buttons: [
                        .destructive(Text("Delete Archive")) {
                            backupsVM.deleteBackup(target)
                        },
                        .cancel()
                    ]
                )
            }
            .actionSheet(item: $deleteCloudTarget) { target in
                ActionSheet(
                    title: Text("Delete from Google Drive?"),
                    message: Text("Are you sure you want to permanently delete \(target.name) from your Google Drive?"),
                    buttons: [
                        .destructive(Text("Delete Cloud File")) {
                            backupsVM.deleteCloudBackup(file: target)
                        },
                        .cancel()
                    ]
                )
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
                                backupsVM.restoreConfirmationRecord = record
                            },
                            onShare: {
                                backupsVM.exportURL = backupsVM.fileURL(for: record)
                            },
                            onDelete: {
                                deleteTarget = record
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
                        Label("Sign In with Google", systemImage: "link.badge.plus")
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
                            onRestore: {
                                backupsVM.restoreConfirmationCloudFile = file
                            },
                            onDownload: {
                                backupsVM.downloadCloudBackupToLocal(file: file)
                            },
                            onDelete: {
                                deleteCloudTarget = file
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
}

// MARK: - Helper Identifiable Wrapper for ShareSheet
struct URLItem: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - Cloud Backup Card View
struct CloudBackupCardView: View {
    let file: GoogleDriveFile
    let onRestore: () -> Void
    let onDownload: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "icloud.fill")
                    .font(.system(size: 26))
                    .foregroundColor(.blue)
                    .frame(width: 40, height: 40)
                    .background(Color.blue.opacity(0.12))
                    .cornerRadius(8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.headline)
                        .lineLimit(1)

                    Text("Google Drive • AppVault Backups")
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

// MARK: - Local Backup Card View
struct BackupCardView: View {
    let record: BackupRecord
    let onRestore: () -> Void
    let onShare: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: record.mode == .full ? "shippingbox.fill" : "internaldrive.fill")
                    .font(.system(size: 26))
                    .foregroundColor(record.mode == .full ? .purple : .blue)
                    .frame(width: 40, height: 40)
                    .background(Color(UIColor.tertiarySystemFill))
                    .cornerRadius(8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(record.appName)
                        .font(.headline)
                        .lineLimit(1)

                    Text(record.bundleIdentifier)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(record.mode.title)
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(record.mode == .full ? Color.purple.opacity(0.15) : Color.blue.opacity(0.15))
                    .foregroundColor(record.mode == .full ? .purple : .blue)
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
    }
}
