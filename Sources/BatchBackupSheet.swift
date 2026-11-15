import SwiftUI

public struct BatchBackupSheet: View {
    public let apps: [InstalledApp]
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var backupsVM: BackupsViewModel
    @ObservedObject var googleDrive = GoogleDriveService.shared

    @State private var selectedMode: BackupMode = .dataOnly
    @State private var selectedDestination: BackupDestination = .local
    @State private var includeCaches: Bool = false
    @State private var isExecuting: Bool = false
    @State private var currentAppIndex: Int = 0
    @State private var currentAppName: String = ""
    @State private var currentProgress: Double = 0.0
    @State private var statusLog: String = ""

    public init(apps: [InstalledApp]) {
        self.apps = apps
    }

    public var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Batch Overview")) {
                    HStack {
                        Label("Selected Apps", systemImage: "square.stack.3d.up.fill")
                        Spacer()
                        Text("\(apps.count) Apps")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.blue)
                    }

                    let totalData = apps.reduce(0) { $0 + $1.dataSizeBytes }
                    HStack {
                        Label("Estimated Data", systemImage: "folder.fill")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: totalData, countStyle: .file))
                            .foregroundColor(.secondary)
                    }
                }

                Section(header: Text("Destination")) {
                    Picker("Destination", selection: $selectedDestination) {
                        ForEach(BackupDestination.allCases) { dest in
                            Label(dest.title, systemImage: dest.iconName).tag(dest)
                        }
                    }
                }

                Section(header: Text("Backup Mode")) {
                    Picker("Mode", selection: $selectedMode) {
                        ForEach(BackupMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())

                    Toggle("Include Caches", isOn: $includeCaches)
                }

                Section {
                    if isExecuting {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("App \(currentAppIndex + 1) of \(apps.count)")
                                    .font(.system(size: 14, weight: .bold))
                                Spacer()
                                Text(currentAppName)
                                    .font(.subheadline)
                                    .foregroundColor(.blue)
                            }

                            ProgressView(value: currentProgress)
                                .progressViewStyle(LinearProgressViewStyle(tint: .blue))

                            Text(statusLog)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 8)
                    } else {
                        Button(action: startBatchProcess) {
                            HStack {
                                Spacer()
                                Label("Queue Batch Backup (\(apps.count) Apps)", systemImage: "play.circle.fill")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.white)
                                Spacer()
                            }
                            .padding(.vertical, 6)
                        }
                        .listRowBackground(Color.blue)
                    }
                }
            }
            .navigationTitle("Batch Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { presentationMode.wrappedValue.dismiss() }
                        .disabled(isExecuting)
                }
            }
        }
    }

    private func startBatchProcess() {
        isExecuting = true
        Task.detached(priority: .userInitiated) {
            for (idx, target) in apps.enumerated() {
                await MainActor.run {
                    self.currentAppIndex = idx
                    self.currentAppName = target.name
                    self.currentProgress = Double(idx) / Double(apps.count)
                    self.statusLog = "Streaming \(target.name)..."
                }

                do {
                    if selectedDestination == .googleDrive {
                        _ = try await BackupEngine.shared.createGoogleDriveStreamingBackup(
                            for: target,
                            mode: selectedMode,
                            includeCaches: includeCaches,
                            note: "Batch Backup"
                        ) { p in
                            Task { @MainActor in
                                self.statusLog = p.statusDetail
                            }
                        }
                    } else {
                        _ = try await BackupEngine.shared.createStreamingBackup(
                            for: target,
                            mode: selectedMode,
                            includeCaches: includeCaches,
                            note: "Batch Backup"
                        ) { p in
                            Task { @MainActor in
                                self.statusLog = p.statusDetail
                            }
                        }
                    }
                } catch {
                    print("[Batch] Failed on \(target.name): \(error.localizedDescription)")
                }
            }

            await MainActor.run {
                self.isExecuting = false
                self.backupsVM.refreshBackups()
                presentationMode.wrappedValue.dismiss()
            }
        }
    }
}
