import SwiftUI

public struct SettingsView: View {
    @EnvironmentObject var settingsVM: SettingsViewModel
    @ObservedObject var googleDrive = GoogleDriveService.shared
    @State private var showAdvancedOAuth = false

    public init() {}

    public var body: some View {
        NavigationView {
            Form {
                // Section 1: Google Drive Cloud Integration
                Section(header: Text("Google Drive Cloud Storage")) {
                    if googleDrive.isAuthenticated {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 24))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(googleDrive.userName.isEmpty ? "Connected" : googleDrive.userName)
                                    .font(.headline)
                                Text(googleDrive.userEmail)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)

                        HStack {
                            Label("Target Cloud Folder", systemImage: "folder.badge.gearshape")
                            Spacer()
                            Text("AppVault Backups")
                                .foregroundColor(.secondary)
                        }

                        Button(action: { googleDrive.signOut() }) {
                            Text("Disconnect Google Drive")
                                .foregroundColor(.red)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Connect your Google Drive account to stream backups directly into the cloud. This avoids using any device storage during backup.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Button(action: { googleDrive.signIn() }) {
                                HStack {
                                    Image(systemName: "link.badge.plus")
                                    Text("Sign In with Google")
                                }
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.blue)
                                .cornerRadius(8)
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    DisclosureGroup("Advanced OAuth 2.0 Credentials", isExpanded: $showAdvancedOAuth) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Optionally provide your own Google Cloud Console Client ID & Secret for personal API quotas.")
                                .font(.caption2)
                                .foregroundColor(.secondary)

                            TextField("Client ID", text: $googleDrive.customClientId)
                                .font(.system(size: 12, design: .monospaced))
                                .autocapitalization(.none)
                                .disableAutocorrection(true)

                            SecureField("Client Secret (optional)", text: $googleDrive.customClientSecret)
                                .font(.system(size: 12, design: .monospaced))
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                        }
                        .padding(.vertical, 4)
                    }
                }

                // Section 2: System Environment
                Section(header: Text("Environment Diagnostics")) {
                    HStack {
                        Label("Filesystem Privileges", systemImage: "shield.checkerboard")
                        Spacer()
                        Text(settingsVM.canAccessRootMobile ? "Unsandboxed (Root/Mobile)" : "Sandboxed")
                            .foregroundColor(settingsVM.canAccessRootMobile ? .green : .orange)
                            .font(.system(size: 14, weight: .bold))
                    }

                    HStack {
                        Label("TrollStore Compatibility", systemImage: "checkmark.seal.fill")
                        Spacer()
                        Text(settingsVM.isTrollStoreEnvironment ? "Detected" : "Standard")
                            .foregroundColor(settingsVM.isTrollStoreEnvironment ? .green : .secondary)
                    }

                    HStack {
                        Label("Device & OS", systemImage: "iphone")
                        Spacer()
                        Text("\(UIDevice.current.model) • iOS \(UIDevice.current.systemVersion)")
                            .foregroundColor(.secondary)
                    }
                }

                // Section 3: Storage Statistics
                Section(header: Text("Storage Management")) {
                    HStack {
                        Label("Free Device Storage", systemImage: "internaldrive")
                        Spacer()
                        Text(settingsVM.freeDiskSpace)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Label("AppVault Backups Storage", systemImage: "archivebox.fill")
                        Spacer()
                        Text(settingsVM.backupStorageUsed)
                            .foregroundColor(.blue)
                            .font(.system(size: 14, weight: .bold))
                    }

                    HStack {
                        Label("Temporary Staging Cache", systemImage: "trash.circle")
                        Spacer()
                        Text(settingsVM.tempStorageUsed)
                            .foregroundColor(.secondary)
                    }

                    Button(action: {
                        settingsVM.clearTemporaryFiles()
                    }) {
                        Label("Purge Staging Files", systemImage: "xmark.bin")
                            .foregroundColor(.red)
                    }
                }

                // Section 4: Storage Locations
                Section(header: Text("Storage Destination")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Active Backups Directory:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(BackupEngine.shared.backupsDirectory.path)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.primary)
                    }
                    .padding(.vertical, 4)
                }

                // Section 5: About
                Section(header: Text("About AppVault")) {
                    HStack {
                        Text("App Version")
                        Spacer()
                        Text("1.1.0 (Zero-Staging & Google Drive)")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Author")
                        Spacer()
                        Text("Moe (@Itsmoe-a11y)")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Source Code")
                        Spacer()
                        Link("GitHub Repository", destination: URL(string: "https://github.com/Itsmoe-a11y/AppVault")!)
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle("Settings & Cloud")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { settingsVM.refreshDiagnostics() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}
