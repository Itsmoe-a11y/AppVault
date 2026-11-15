import SwiftUI

public struct BackupsListView: View {
    @EnvironmentObject var backupsVM: BackupsViewModel
    @State private var showDocumentPicker = false
    @State private var deleteTarget: BackupRecord? = nil

    public init() {}

    public var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Active Operation Banner
                if backupsVM.isPerformingOperation, let progress = backupsVM.activeProgress {
                    VStack(spacing: 8) {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text(progress.stage)
                                .font(.subheadline)
                                .bold()
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
                    .padding(.top, 8)
                }

                // Backups List
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
                        Text("No Backups Yet")
                            .font(.headline)
                        Text("Go to the Applications tab to create your first backup, or tap Import to load an existing .adbk archive.")
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
                        backupsVM.refreshBackups()
                    }
                }
            }
            .navigationTitle("Backups (\(backupsVM.backups.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { showDocumentPicker = true }) {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { backupsVM.refreshBackups() }) {
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
            .actionSheet(item: $backupsVM.restoreConfirmationRecord) { record in
                ActionSheet(
                    title: Text("Restore \(record.appName)?"),
                    message: Text("Restoring will replace the application's current documents and databases with this backup (\(record.formattedDate)). Any running instance will be terminated."),
                    buttons: [
                        .destructive(Text("Restore State")) {
                            backupsVM.startRestore(record: record)
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
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

// MARK: - Helper Identifiable Wrapper for ShareSheet
struct URLItem: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - Backup Card View
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

                // Mode Badge
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
                    .font(.caption2)
                    .bold()
                    .foregroundColor(.secondary)
            }

            Divider()

            // Card Action Buttons
            HStack(spacing: 12) {
                Button(action: onRestore) {
                    Label("Restore", systemImage: "arrow.counterclockwise.circle.fill")
                        .font(.subheadline)
                        .bold()
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
