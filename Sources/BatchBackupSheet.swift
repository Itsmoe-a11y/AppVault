import SwiftUI

// MARK: - Batch Result Item
public struct BatchAppResult: Identifiable {
    public let id = UUID()
    public let appName: String
    public let bundleIdentifier: String
    public let isSuccess: Bool
    public let errorMessage: String?
}

public struct BatchBackupSheet: View {
    public let apps: [InstalledApp]
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var backupsVM: BackupsViewModel
    @ObservedObject var googleDrive = GoogleDriveService.shared

    @State private var selectedMode: BackupMode = .dataOnly
    @State private var selectedDestination: BackupDestination = .local
    @State private var includeCaches: Bool = false
    @State private var isExecuting: Bool = false
    @State private var isCompleted: Bool = false
    @State private var currentAppIndex: Int = 0
    @State private var currentAppName: String = ""
    @State private var currentProgress: Double = 0.0
    @State private var statusLog: String = ""
    @State private var results: [BatchAppResult] = []
    @State private var batchTask: Task<Void, Never>? = nil

    public init(apps: [InstalledApp]) {
        self.apps = apps
    }

    private var successCount: Int {
        results.filter { $0.isSuccess }.count
    }

    private var failureCount: Int {
        results.filter { !$0.isSuccess }.count
    }

    public var body: some View {
        NavigationView {
            Form {
                // Section 1: Batch Overview
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

                // Section 2: Destination & Mode (only editable before starting)
                if !isExecuting && !isCompleted {
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
                }

                // Section 3: Active Execution Progress
                if isExecuting {
                    Section(header: Text("Queue Progress")) {
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

                            HStack {
                                Text("\(Int(currentProgress * 100))%")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(successCount) done \u{2022} \(failureCount) failed")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            Text(statusLog)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 4)

                        Button(role: .destructive, action: cancelBatchProcess) {
                            HStack {
                                Spacer()
                                Label("Cancel Remaining Queue", systemImage: "stop.circle.fill")
                                    .foregroundColor(.red)
                                Spacer()
                            }
                        }
                    }
                }

                // Section 4: Completion Summary
                if isCompleted {
                    Section(header: Text("Batch Summary")) {
                        HStack {
                            Label("Completed", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Spacer()
                            Text("\(successCount) Succeeded")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.green)
                        }

                        if failureCount > 0 {
                            HStack {
                                Label("Failed Apps", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                Spacer()
                                Text("\(failureCount) Errors")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.red)
                            }

                            ForEach(results.filter { !$0.isSuccess }) { res in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(res.appName)
                                        .font(.system(size: 13, weight: .semibold))
                                    Text(res.errorMessage ?? "Unknown error")
                                        .font(.caption2)
                                        .foregroundColor(.red)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }

                // Section 5: Action Button
                Section {
                    if isCompleted {
                        Button(action: { presentationMode.wrappedValue.dismiss() }) {
                            HStack {
                                Spacer()
                                Text("Done")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.white)
                                Spacer()
                            }
                            .padding(.vertical, 6)
                        }
                        .listRowBackground(Color.blue)
                    } else if !isExecuting {
                        Button(action: startBatchProcess) {
                            HStack {
                                Spacer()
                                Label("Start Batch Backup (\(apps.count) Apps)", systemImage: "play.circle.fill")
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
                    Button(isCompleted ? "Done" : "Close") {
                        if isExecuting {
                            cancelBatchProcess()
                        }
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func cancelBatchProcess() {
        batchTask?.cancel()
        batchTask = nil
        isExecuting = false
        isCompleted = true
        statusLog = "Queue cancelled by user."
    }

    private func startBatchProcess() {
        isExecuting = true
        isCompleted = false
        results.removeAll()
        currentProgress = 0.0

        batchTask = Task.detached(priority: .userInitiated) {
            let total = self.apps.count

            for (idx, target) in self.apps.enumerated() {
                if Task.isCancelled { break }

                await MainActor.run {
                    self.currentAppIndex = idx
                    self.currentAppName = target.name
                    self.currentProgress = Double(idx) / Double(max(total, 1))
                    self.statusLog = "Backing up \(target.name)..."
                }

                do {
                    if self.selectedDestination == .googleDrive {
                        _ = try await BackupEngine.shared.createGoogleDriveStreamingBackup(
                            for: target,
                            mode: self.selectedMode,
                            includeCaches: self.includeCaches,
                            note: "Batch Backup"
                        ) { p in
                            Task { @MainActor in
                                self.statusLog = p.statusDetail
                            }
                        }
                    } else if self.selectedDestination == .webdav {
                        let safeName = target.name.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
                        let timestamp = Int(Date().timeIntervalSince1970)
                        let archiveName = "\(safeName)_\(target.bundleIdentifier)_\(timestamp).adbk"

                        var uploadData = Data()
                        _ = try await StreamingArchiveEngine.shared.streamBackup(
                            for: target,
                            mode: self.selectedMode,
                            includeCaches: self.includeCaches,
                            note: "Batch Backup",
                            onProgress: { p in
                                Task { @MainActor in
                                    self.statusLog = p.statusDetail
                                }
                            },
                            onCompressedChunk: { chunk in
                                uploadData.append(chunk)
                            }
                        )

                        try await WebDAVService.shared.upload(data: uploadData, remoteFileName: archiveName)
                    } else {
                        _ = try await BackupEngine.shared.createStreamingBackup(
                            for: target,
                            mode: self.selectedMode,
                            includeCaches: self.includeCaches,
                            note: "Batch Backup"
                        ) { p in
                            Task { @MainActor in
                                self.statusLog = p.statusDetail
                            }
                        }
                    }

                    await MainActor.run {
                        self.results.append(BatchAppResult(
                            appName: target.name,
                            bundleIdentifier: target.bundleIdentifier,
                            isSuccess: true,
                            errorMessage: nil
                        ))
                    }
                } catch {
                    // Gracefully record failure and continue to next app in queue
                    await MainActor.run {
                        self.results.append(BatchAppResult(
                            appName: target.name,
                            bundleIdentifier: target.bundleIdentifier,
                            isSuccess: false,
                            errorMessage: error.localizedDescription
                        ))
                        self.statusLog = "Error on \(target.name): \(error.localizedDescription)"
                    }
                }
            }

            await MainActor.run {
                self.currentProgress = 1.0
                self.isExecuting = false
                self.isCompleted = true
                self.backupsVM.refreshBackups()

                // If all succeeded with 0 errors, auto-dismiss smoothly
                if self.failureCount == 0 && !Task.isCancelled {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        self.presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }
}
