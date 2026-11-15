import SwiftUI

public struct BackupDetailSheet: View {
    public let app: InstalledApp
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var backupsVM: BackupsViewModel
    @ObservedObject var googleDrive = GoogleDriveService.shared

    @State private var selectedMode: BackupMode = .dataOnly
    @State private var selectedDestination: BackupDestination = .local
    @State private var includeCaches: Bool = false
    @State private var note: String = ""

    public init(app: InstalledApp) {
        self.app = app
    }

    public var body: some View {
        NavigationView {
            Form {
                // Section 1: App Info
                Section {
                    HStack(spacing: 16) {
                        Image(systemName: "app.gift.fill")
                            .font(.system(size: 34))
                            .foregroundColor(.blue)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.name)
                                .font(.headline)
                            Text(app.bundleIdentifier)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Version \(app.version) (\(app.build))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Section 2: Storage Estimates & Zero-Footprint Streaming Badge
                Section(header: Text("Storage Footprint")) {
                    HStack {
                        Label("App Binary", systemImage: "shippingbox")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: app.appSizeBytes, countStyle: .file))
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Label("App Data", systemImage: "folder")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: app.dataSizeBytes, countStyle: .file))
                            .foregroundColor(.secondary)
                    }

                    if !app.groupContainerURLs.isEmpty {
                        HStack {
                            Label("Shared Groups (\(app.groupContainerURLs.count))", systemImage: "rectangle.3.group")
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: app.groupSizeBytes, countStyle: .file))
                                .foregroundColor(.secondary)
                        }
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "bolt.horizontal.circle.fill")
                            .foregroundColor(.green)
                        Text("Zero-staging streaming enabled: source files are compressed on-the-fly without intermediate duplication.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }

                // Section 3: Backup Destination (Local vs Google Drive)
                Section(header: Text("Destination")) {
                    Picker("Destination", selection: $selectedDestination) {
                        ForEach(BackupDestination.allCases) { dest in
                            Label(dest.title, systemImage: dest.iconName).tag(dest)
                        }
                    }

                    if selectedDestination == .googleDrive {
                        if googleDrive.isAuthenticated {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Linked as \(googleDrive.userEmail)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Text("Archive will be compressed on-the-fly and streamed directly to Google Drive. Uses 0 MB of local storage.")
                                .font(.caption2)
                                .foregroundColor(.blue)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Google Drive account is not connected.")
                                    .font(.caption)
                                    .foregroundColor(.orange)

                                Button(action: { googleDrive.signIn() }) {
                                    HStack {
                                        Image(systemName: "link.badge.plus")
                                        Text("Sign In with Google")
                                    }
                                    .font(.subheadline)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .background(Color.blue)
                                    .cornerRadius(8)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                // Section 4: Backup Mode
                Section(header: Text("Backup Type")) {
                    Picker("Mode", selection: $selectedMode) {
                        ForEach(BackupMode.allCases) { mode in
                            HStack {
                                Image(systemName: mode.iconName)
                                Text(mode.title)
                            }.tag(mode)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())

                    Text(selectedMode.subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Section 5: Options
                Section(header: Text("Options")) {
                    Toggle("Include Caches & Temp Files", isOn: $includeCaches)
                    TextField("Note / Label (e.g. Work Profile, Save 1)", text: $note)
                }

                // Section 6: Action or Active Progress
                Section {
                    if backupsVM.isPerformingOperation, let progress = backupsVM.activeProgress {
                        VStack(spacing: 12) {
                            HStack {
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
                        .padding(.vertical, 8)
                    } else {
                        Button(action: startBackupAction) {
                            HStack {
                                Spacer()
                                Label(
                                    selectedDestination == .googleDrive ? "Stream Direct to Google Drive" : "Create Streaming Backup",
                                    systemImage: selectedDestination == .googleDrive ? "icloud.and.arrow.up.fill" : "arrow.down.doc.fill"
                                )
                                .font(.headline)
                                .foregroundColor(.white)
                                Spacer()
                            }
                            .padding(.vertical, 6)
                        }
                        .disabled(selectedDestination == .googleDrive && !googleDrive.isAuthenticated)
                        .listRowBackground(selectedDestination == .googleDrive && !googleDrive.isAuthenticated ? Color.gray : Color.blue)
                    }
                }
            }
            .navigationTitle("Backup Application")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        presentationMode.wrappedValue.dismiss()
                    }
                    .disabled(backupsVM.isPerformingOperation)
                }
            }
        }
    }

    private func startBackupAction() {
        backupsVM.startBackup(
            for: app,
            mode: selectedMode,
            includeCaches: includeCaches,
            destination: selectedDestination,
            note: note
        )
    }
}
