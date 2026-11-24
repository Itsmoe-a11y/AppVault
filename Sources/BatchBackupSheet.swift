import SwiftUI

public struct BatchAppResult: Identifiable {
    public let id = UUID()
    public let appName: String
    public let bundleIdentifier: String
    public let isSuccess: Bool
    public let errorMessage: String?
}

public enum BatchItemStatus: Equatable {
    case waiting
    case running(detail: String, fraction: Double)
    case succeeded
    case failed(String)
}

public struct BatchBackupSheet: View {
    public let apps: [InstalledApp]
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var backupsVM: BackupsViewModel
    @ObservedObject var googleDrive = GoogleDriveService.shared
    @ObservedObject var webdav = WebDAVService.shared

    @State private var selectedMode: BackupMode
    @State private var selectedDestination: BackupDestination
    @State private var includeCaches: Bool
    @State private var includeKeychain: Bool = true
    @State private var includeAppGroups: Bool = true
    @State private var compressionLevel: BackupCompressionLevel = SettingsViewModel.savedDefaultCompressionLevel
    @State private var bufferProfile: UploadBufferProfile = SettingsViewModel.savedUploadBufferProfile
    @State private var maxConcurrency: Int = 2
    @State private var enableEncryption: Bool = false
    @State private var encryptionPassword: String = ""

    @State private var isExecuting: Bool = false
    @State private var isCompleted: Bool = false
    @State private var itemStatuses: [String: BatchItemStatus] = [:]
    @State private var results: [BatchAppResult] = []
    @State private var batchTask: Task<Void, Never>? = nil

    private static func availableLocalDiskSpaceBytes() -> Int64 {
        let probeURL = URL(fileURLWithPath: "/var/mobile")
        if let vals = try? probeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]) {
            if let important = vals.volumeAvailableCapacityForImportantUsage, important > 0 {
                return important
            }
            if let regular = vals.volumeAvailableCapacity, regular > 0 {
                return Int64(regular)
            }
        }
        return Int64.max
    }

    public init(apps: [InstalledApp]) {
        self.apps = apps
        _selectedMode = State(initialValue: SettingsViewModel.savedDefaultBackupMode)
        _includeCaches = State(initialValue: SettingsViewModel.savedDefaultIncludeCaches)

        let savedRaw = UserDefaults.standard.string(forKey: "appvault_last_backup_destination")
        var initialDest: BackupDestination = .local
        if let raw = savedRaw, let saved = BackupDestination(rawValue: raw) {
            if saved == .googleDrive && GoogleDriveService.shared.isAuthenticated {
                initialDest = .googleDrive
            } else if saved == .webdav && WebDAVService.shared.isConfigured {
                initialDest = .webdav
            } else {
                initialDest = .local
            }
        } else if GoogleDriveService.shared.isAuthenticated {
            let estimated = apps.reduce(Int64(0)) { $0 + $1.totalSizeBytes }
            let freeBytes = Self.availableLocalDiskSpaceBytes()
            if estimated > 0 && estimated > (freeBytes / 2) {
                initialDest = .googleDrive
            }
        }
        _selectedDestination = State(initialValue: initialDest)
    }

    private var successCount: Int {
        results.filter { $0.isSuccess }.count
    }

    private var failureCount: Int {
        results.filter { !$0.isSuccess }.count
    }

    private var overallProgress: Double {
        guard !apps.isEmpty else { return 0 }
        let totalUnits = apps.reduce(0.0) { acc, app in
            switch itemStatuses[app.bundleIdentifier] ?? .waiting {
            case .waiting: return acc
            case .running(_, let fraction): return acc + min(0.98, max(0.02, fraction))
            case .succeeded, .failed: return acc + 1.0
            }
        }
        return min(1.0, totalUnits / Double(apps.count))
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
                // Section 1: Selected Apps with Real App Icons
                Section(header: Text("Selected Apps (\(apps.count) • \(ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .file)))")) {
                    ForEach(apps) { app in
                        HStack(spacing: 12) {
                            AppIconView(
                                bundleIdentifier: app.bundleIdentifier,
                                bundleURL: app.bundleURL,
                                isSystemApp: app.isSystemApp,
                                size: 36
                            )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .lineLimit(1)

                                switch itemStatuses[app.bundleIdentifier] ?? .waiting {
                                case .waiting:
                                    Text(app.isSized ? ByteCountFormatter.string(fromByteCount: app.totalSizeBytes, countStyle: .file) : "Queued")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                case .running(let detail, _):
                                    Text(detail)
                                        .font(.caption2)
                                        .foregroundColor(.blue)
                                        .lineLimit(1)
                                case .succeeded:
                                    Text("Backup complete")
                                        .font(.caption2)
                                        .foregroundColor(.green)
                                case .failed(let msg):
                                    Text(msg)
                                        .font(.caption2)
                                        .foregroundColor(.red)
                                        .lineLimit(2)
                                }
                            }

                            Spacer()

                            switch itemStatuses[app.bundleIdentifier] ?? .waiting {
                            case .waiting:
                                Text("Queued")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            case .running(_, let fraction):
                                HStack(spacing: 4) {
                                    ProgressView()
                                        .scaleEffect(0.75)
                                    Text("\(Int(fraction * 100))%")
                                        .font(.caption2.bold())
                                        .foregroundColor(.blue)
                                }
                            case .succeeded:
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            case .failed:
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                // Section 2: Destination & Options (only editable before starting)
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
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Google Drive is not signed in.")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                                Button(action: { googleDrive.signIn() }) {
                                    Label("Sign In with Google", systemImage: "person.badge.key.fill")
                                        .font(.caption.bold())
                                }
                                .buttonStyle(BorderlessButtonStyle())
                            }
                        } else if selectedDestination == .webdav && !webdav.isConfigured {
                            Text("WebDAV is not configured. Configure your server in Settings first.")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }

                    Section(header: Text("Backup Mode, Parallelism & Compression")) {
                        Picker("Mode", selection: $selectedMode) {
                            ForEach(BackupMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(SegmentedPickerStyle())

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Simultaneous Backups")
                                .font(.subheadline)
                            Picker("Simultaneous Backups", selection: $maxConcurrency) {
                                Text("1 at a time").tag(1)
                                Text("2 Parallel").tag(2)
                                Text("3 Parallel").tag(3)
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            Text(maxConcurrency > 1
                                 ? "Runs up to \(maxConcurrency) app backups simultaneously for faster batch completion."
                                 : "Backs up apps one after another sequentially.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)

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

                // Section 3: Active Execution Overall Progress
                if isExecuting {
                    Section(header: Text("Overall Progress (\(selectedDestination.title))")) {
                        VStack(alignment: .leading, spacing: 10) {
                            ProgressView(value: overallProgress)
                                .progressViewStyle(LinearProgressViewStyle(tint: .blue))

                            HStack {
                                Text("\(Int(overallProgress * 100))% overall")
                                    .font(.caption.bold())
                                Spacer()
                                Text("\(successCount) done \u{2022} \(failureCount) failed")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)

                        Button(role: .destructive, action: cancelBatchProcess) {
                            HStack {
                                Spacer()
                                Label("Cancel Remaining Backups", systemImage: "stop.circle.fill")
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
                                Label("Start Backup (\(apps.count) Apps)", systemImage: "play.circle.fill")
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
            .navigationTitle("Multi-App Backup")
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
    }

    private func startBatchProcess() {
        isExecuting = true
        isCompleted = false
        results.removeAll()
        var initialStates: [String: BatchItemStatus] = [:]
        for app in apps {
            initialStates[app.bundleIdentifier] = .waiting
        }
        itemStatuses = initialStates

        let targetApps = apps
        let destination = selectedDestination
        let mode = selectedMode
        let caches = includeCaches
        let keychain = includeKeychain
        let groups = includeAppGroups
        let selectedCompression = compressionLevel
        let concurrency = max(1, min(3, maxConcurrency))
        // Scale Drive buffer down safely when running 2-3 simultaneous backups so Jetsam stays happy
        let selectedBuffer: UploadBufferProfile = (concurrency > 1 && bufferProfile == .maxRAM) ? .fast : ((concurrency > 2 && bufferProfile == .turbo) ? .fast : bufferProfile)
        let password = enableEncryption ? encryptionPassword : nil
        let retentionLimit = SettingsViewModel.savedMaxBackupsPerApp

        batchTask = Task(priority: .userInitiated) {
            BackupEngine.shared.beginKeepAwake()
            defer { BackupEngine.shared.endKeepAwake() }

            var nextIdx = 0

            func runSingleBackup(for target: InstalledApp) async -> BatchAppResult {
                if Task.isCancelled {
                    return BatchAppResult(appName: target.name, bundleIdentifier: target.bundleIdentifier, isSuccess: false, errorMessage: "Cancelled")
                }

                await MainActor.run {
                    self.itemStatuses[target.bundleIdentifier] = .running(detail: "Starting...", fraction: 0.02)
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
                                self.itemStatuses[target.bundleIdentifier] = .running(detail: p.statusDetail, fraction: p.fractionCompleted)
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
                                self.itemStatuses[target.bundleIdentifier] = .running(detail: p.statusDetail, fraction: p.fractionCompleted)
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
                            compressionLevel: selectedCompression,
                            note: "Batch Backup"
                        ) { p in
                            Task { @MainActor in
                                self.itemStatuses[target.bundleIdentifier] = .running(detail: p.statusDetail, fraction: p.fractionCompleted)
                            }
                        }
                        if retentionLimit > 0 {
                            BackupEngine.shared.pruneOldBackups(for: target.bundleIdentifier, keepNewest: retentionLimit)
                        }
                    }
                    return BatchAppResult(appName: target.name, bundleIdentifier: target.bundleIdentifier, isSuccess: true, errorMessage: nil)
                } catch {
                    return BatchAppResult(appName: target.name, bundleIdentifier: target.bundleIdentifier, isSuccess: false, errorMessage: error.localizedDescription)
                }
            }

            await withTaskGroup(of: BatchAppResult.self) { group in
                while nextIdx < targetApps.count && nextIdx < concurrency {
                    let target = targetApps[nextIdx]
                    nextIdx += 1
                    group.addTask {
                        await runSingleBackup(for: target)
                    }
                }

                for await res in group {
                    await MainActor.run {
                        self.results.append(res)
                        self.itemStatuses[res.bundleIdentifier] = res.isSuccess ? .succeeded : .failed(res.errorMessage ?? "Error")
                    }

                    if !Task.isCancelled && nextIdx < targetApps.count {
                        let nextTarget = targetApps[nextIdx]
                        nextIdx += 1
                        group.addTask {
                            await runSingleBackup(for: nextTarget)
                        }
                    }
                }
            }

            let wasCancelled = Task.isCancelled
            await MainActor.run {
                self.isExecuting = false
                self.isCompleted = true
                self.backupsVM.refreshBackups()

                if self.failureCount == 0 && !wasCancelled {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        self.presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }
}
