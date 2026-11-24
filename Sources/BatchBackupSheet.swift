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
    @ObservedObject var webdav = WebDAVService.shared

    @State private var selectedMode: BackupMode
    @State private var selectedDestination: BackupDestination = .local
    @State private var includeCaches: Bool
    @State private var includeKeychain: Bool = true
    @State private var includeAppGroups: Bool = true
    @State private var compressionLevel: BackupCompressionLevel = SettingsViewModel.savedDefaultCompressionLevel
    @State private var bufferProfile: UploadBufferProfile = SettingsViewModel.savedUploadBufferProfile
    @State private var enableEncryption: Bool = false
    @State private var encryptionPassword: String = ""
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
        _selectedMode = State(initialValue: SettingsViewModel.savedDefaultBackupMode)
        _includeCaches = State(initialValue: SettingsViewModel.savedDefaultIncludeCaches)
    }

    private var successCount: Int {
        results.filter { $0.isSuccess }.count
    }

    private var failureCount: Int {
        results.filter { !$0.isSuccess }.count
    }

    private var estimatedBytes: Int64 {
        apps.reduce(0) { sum, app in
            let appPart = selectedMode == .full ? app.appSizeBytes : 0
            let groupPart = includeAppGroups ? app.groupSizeBytes : 0
            return sum + app.dataSizeBytes + groupPart + appPart
        }
    }

    private var isStartDisabled: Bool {
        if selectedDestination == .googleDrive && !googleDrive.isAuthenticated { return true }
        if selectedDestination == .webdav && !webdav.isConfigured { return true }
        if enableEncryption && encryptionPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return apps.isEmpty
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

                    HStack {
                        Label("Estimated Size", systemImage: "folder.fill")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .file))
                            .foregroundColor(.secondary)
                    }
                }

                // Section 2: Destination & Mode (only editable before starting)
                if !isExecuting && !isCompleted {
                    Section(header: Text("Destination")) {
                        ForEach(BackupDestination.allCases) { dest in
                            Button(action: {
                                selectedDestination = dest
                                UserDefaults.standard.set(dest.rawValue, forKey: "appvault_last_backup_destination")
                            }) {
                                HStack(spacing: 12) {
                                    Image(systemName: dest.iconName)
                                        .foregroundColor(selectedDestination == dest ? .blue : .secondary)
                                        .frame(width: 24)
                                    Text(dest.title)
                                        .foregroundColor(.primary)
                                        .font(.body.weight(selectedDestination == dest ? .semibold : .regular))
                                    Spacer()
                                    if selectedDestination == dest {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.blue)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PlainButtonStyle())
                        }

                        if selectedDestination == .googleDrive && !googleDrive.isAuthenticated {
                            Text("Google Drive is not signed in. Sign in under Settings first.")
                                .font(.caption)
                                .foregroundColor(.orange)
                        } else if selectedDestination == .webdav && !webdav.isConfigured {
                            Text("WebDAV is not configured. Configure your server in Settings first.")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }

                    Section(header: Text("Backup Mode & Components")) {
                        Picker("Mode", selection: $selectedMode) {
                            ForEach(BackupMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(SegmentedPickerStyle())

                        Picker("Compression", selection: $compressionLevel) {
                            ForEach(BackupCompressionLevel.allCases) { lvl in
                                Text(lvl.shortTitle).tag(lvl)
                            }
                        }
                        .pickerStyle(SegmentedPickerStyle())

                        if selectedDestination == .googleDrive {
                            Picker("RAM Buffer", selection: $bufferProfile) {
                                ForEach(UploadBufferProfile.allCases) { prof in
                                    Text(prof.shortTitle).tag(prof)
                                }
                            }
                            .pickerStyle(SegmentedPickerStyle())
                        }

                        Toggle("Include Shared App Groups", isOn: $includeAppGroups)
                        Toggle("Include Keychain & Logins", isOn: $includeKeychain)
                        Toggle("Include Caches", isOn: $includeCaches)
                        Toggle("Encrypt with AES-256-GCM", isOn: $enableEncryption)
                        if enableEncryption {
                            SecureField("Batch Encryption Password", text: $encryptionPassword)
                        }
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
                        .disabled(isStartDisabled)
                        .listRowBackground(isStartDisabled ? Color.gray : Color.blue)
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

        let targetApps = apps
        let destination = selectedDestination
        let mode = selectedMode
        let caches = includeCaches
        let keychain = includeKeychain
        let groups = includeAppGroups
        let selectedCompression = compressionLevel
        let selectedBuffer = bufferProfile
        let password = enableEncryption ? encryptionPassword : nil
        let retentionLimit = SettingsViewModel.savedMaxBackupsPerApp

        batchTask = Task(priority: .userInitiated) {
            let total = targetApps.count
            var wasCancelled = false

            for (idx, target) in targetApps.enumerated() {
                if Task.isCancelled {
                    wasCancelled = true
                    break
                }

                await MainActor.run {
                    self.currentAppIndex = idx
                    self.currentAppName = target.name
                    self.currentProgress = Double(idx) / Double(max(total, 1))
                    self.statusLog = "Backing up \(target.name)..."
                }

                do {
                    if destination == .googleDrive {
                        _ = try await BackupEngine.shared.createGoogleDriveStreamingBackup(
                            for: target,
                            mode: mode,
                            includeCaches: caches,
                            includeKeychain: keychain,
                            includeAppGroups: groups,
                            encryptionPassword: password,
                            compressionLevel: selectedCompression,
                            bufferProfile: selectedBuffer,
                            note: "Batch Backup"
                        ) { p in
                            Task { @MainActor in
                                self.statusLog = p.statusDetail
                            }
                        }
                    } else if destination == .webdav {
                        _ = try await BackupEngine.shared.createWebDAVStreamingBackup(
                            for: target,
                            mode: mode,
                            includeCaches: caches,
                            includeKeychain: keychain,
                            includeAppGroups: groups,
                            encryptionPassword: password,
                            compressionLevel: selectedCompression,
                            note: "Batch Backup"
                        ) { p in
                            Task { @MainActor in
                                self.statusLog = p.statusDetail
                            }
                        }
                    } else {
                        _ = try await BackupEngine.shared.createStreamingBackup(
                            for: target,
                            mode: mode,
                            includeCaches: caches,
                            includeKeychain: keychain,
                            includeAppGroups: groups,
                            encryptionPassword: password,
                            note: "Batch Backup"
                        ) { p in
                            Task { @MainActor in
                                self.statusLog = p.statusDetail
                            }
                        }
                        if retentionLimit > 0 {
                            BackupEngine.shared.pruneOldBackups(for: target.bundleIdentifier, keepNewest: retentionLimit)
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

            if Task.isCancelled {
                wasCancelled = true
            }

            let cancelledFinal = wasCancelled
            await MainActor.run {
                self.currentProgress = 1.0
                self.isExecuting = false
                self.isCompleted = true
                self.backupsVM.refreshBackups()

                if self.failureCount == 0 && !cancelledFinal {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        self.presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }
}
