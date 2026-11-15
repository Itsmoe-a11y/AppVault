import SwiftUI

public struct SettingsView: View {
    @EnvironmentObject var settingsVM: SettingsViewModel

    public init() {}

    public var body: some View {
        NavigationView {
            Form {
                // Section 1: System Environment
                Section(header: Text("Environment Diagnostics")) {
                    HStack {
                        Label("Filesystem Privileges", systemImage: "shield.checkerboard")
                        Spacer()
                        Text(settingsVM.canAccessRootMobile ? "Unsandboxed (Root/Mobile)" : "Sandboxed")
                            .foregroundColor(settingsVM.canAccessRootMobile ? .green : .orange)
                            .bold()
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

                // Section 2: Storage Statistics
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
                            .bold()
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

                // Section 3: Storage Locations
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

                // Section 4: About
                Section(header: Text("About AppVault")) {
                    HStack {
                        Text("App Version")
                        Spacer()
                        Text("1.0.0 (TrollStore)")
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
            .navigationTitle("System & Storage")
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
