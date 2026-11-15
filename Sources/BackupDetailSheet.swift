import SwiftUI

public struct BackupDetailSheet: View {
    public let app: InstalledApp
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var backupsVM: BackupsViewModel

    @State private var selectedMode: BackupMode = .dataOnly
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

                // Section 2: Storage Estimates
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
                }

                // Section 3: Backup Mode
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

                // Section 4: Options
                Section(header: Text("Options")) {
                    Toggle("Include Caches & Temp Files", isOn: $includeCaches)
                    TextField("Note / Label (e.g. Work Profile, Save 1)", text: $note)
                }

                // Section 5: Progress or Action
                Section {
                    if backupsVM.isPerformingOperation, let progress = backupsVM.activeProgress {
                        VStack(spacing: 12) {
                            HStack {
                                Text(progress.stage)
                                    .font(.subheadline)
                                    .fontWeight(.bold)
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
                                Label("Create Backup Now", systemImage: "arrow.down.doc.fill")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                Spacer()
                            }
                            .padding(.vertical, 6)
                        }
                        .listRowBackground(Color.blue)
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
            note: note
        )
    }
}
