import SwiftUI

public struct BackupDetailSheet: View {
    public let app: InstalledApp
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var backupsVM: BackupsViewModel
    @ObservedObject var googleDrive = GoogleDriveService.shared
    @ObservedObject var webdav = WebDAVService.shared

    @State private var selectedMode: BackupMode
    @State private var selectedDestination: BackupDestination
    @State private var includeKeychain: Bool = true
    @State private var includeAppGroups: Bool = true
    @State private var includeCaches: Bool
    @State private var note: String = ""
    @State private var enableEncryption: Bool = false
    @State private var encryptionPassword: String = ""

    // In-sheet execution state
    @State private var currentApp: InstalledApp
    @State private var isExecuting: Bool = false
    @State private var currentProgress: OperationProgress? = nil
    @State private var executionError: String? = nil
    @State private var completedRecord: BackupRecord? = nil
    @State private var activeTask: Task<Void, Never>? = nil
    @State private var sizingTask: Task<Void, Never>? = nil
    @State private var showDebugLogs: Bool = false

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

    public init(app: InstalledApp) {
        self.app = app
        _currentApp = State(initialValue: app)
        _selectedMode = State(initialValue: SettingsViewModel.savedDefaultBackupMode)
        _includeCaches = State(initialValue: SettingsViewModel.savedDefaultIncludeCaches)

        // Restore last chosen destination, or auto-select Google Drive when authenticated & local iPhone space is tight
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
            let estimatedBytes = app.dataSizeBytes + app.groupSizeBytes + app.appSizeBytes
            let freeBytes = Self.availableLocalDiskSpaceBytes()
            if estimatedBytes > 0 && estimatedBytes > (freeBytes / 2) {
                initialDest = .googleDrive
            }
        }
        _selectedDestination = State(initialValue: initialDest)
    }

    private var isActionDisabled: Bool {
        if selectedDestination == .googleDrive && !googleDrive.isAuthenticated { return true }
        if selectedDestination == .webdav && !webdav.isConfigured { return true }
        if enableEncryption && encryptionPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return false
    }

    private var actionButtonTitle: String {
        switch selectedDestination {
        case .googleDrive:
            return enableEncryption ? "Encrypt & Stream to Google Drive" : "Stream Direct to Google Drive (0 MB Disk)"
        case .webdav:
            return enableEncryption ? "Encrypt & Upload to WebDAV" : "Upload Backup to WebDAV"
        case .local:
            return enableEncryption ? "Save Encrypted Backup to iPhone" : "Save Backup to iPhone Storage"
        }
    }

    private var actionButtonIcon: String {
        switch selectedDestination {
        case .googleDrive: return "icloud.and.arrow.up.fill"
        case .webdav: return "server.rack"
        case .local: return enableEncryption ? "lock.doc.fill" : "arrow.down.doc.fill"
        }
    }

    public var body: some View {
        NavigationView {
            Form {
                // Section 1: Target App Info
                Section {
                    HStack(spacing: 16) {
                        Image(systemName: app.isSystemApp ? "gearshape.fill" : "app.fill")
                            .font(.system(size: 34))
                            .foregroundColor(app.isSystemApp ? .gray : .blue)
                            .frame(width: 48, height: 48)
                            .background(Color(UIColor.tertiarySystemFill))
                            .cornerRadius(12)

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

                // Section 2: Storage Footprint
                Section(header: Text("Storage Footprint")) {
                    HStack {
                        Label("App Binary", systemImage: "shippingbox")
                        Spacer()
                        if currentApp.appSizeBytes > 0 || currentApp.isSized {
                            Text(ByteCountFormatter.string(fromByteCount: currentApp.appSizeBytes, countStyle: .file))
                                .foregroundColor(.secondary)
                        } else {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                    }

                    HStack {
                        Label("App Data Container", systemImage: "folder")
                        Spacer()
                        if currentApp.dataSizeBytes > 0 || currentApp.isSized {
                            Text(ByteCountFormatter.string(fromByteCount: currentApp.dataSizeBytes, countStyle: .file))
                                .foregroundColor(.secondary)
                        } else {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                    }

                    if !currentApp.groupContainerURLs.isEmpty {
                        HStack {
                            Label("Shared Groups (\(currentApp.groupContainerURLs.count))", systemImage: "rectangle.3.group")
                            Spacer()
                            if currentApp.groupSizeBytes > 0 || currentApp.isSized {
                                Text(ByteCountFormatter.string(fromByteCount: currentApp.groupSizeBytes, countStyle: .file))
                                    .foregroundColor(.secondary)
                            } else {
                                ProgressView()
                                    .scaleEffect(0.7)
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "bolt.horizontal.circle.fill")
                            .foregroundColor(.green)
                        Text("Zero-staging streaming enabled: source files are compressed directly on-the-fly without intermediate disk copies.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }

                if !isExecuting && completedRecord == nil {
                    // Section 3: Backup Type
                    Section(header: Text("Backup Type")) {
                        Picker("Backup Type", selection: $selectedMode) {
                            Text("Data Only").tag(BackupMode.dataOnly)
                            Text("Full (App + Data)").tag(BackupMode.full)
                        }
                        .pickerStyle(SegmentedPickerStyle())

                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: selectedMode == .dataOnly ? "internaldrive" : "shippingbox.fill")
                                .foregroundColor(.blue)
                                .font(.system(size: 16))
                                .padding(.top, 2)
                            Text(selectedMode.subtitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }

                    // Section 4: Destination (Direct tap rows — avoids iOS 16.0 MenuPickerStyle selection bugs inside Form)
                    Section(header: Text("Destination")) {
                        ForEach(BackupDestination.allCases) { dest in
                            Button(action: {
                                selectedDestination = dest
                                UserDefaults.standard.set(dest.rawValue, forKey: "appvault_last_backup_destination")
                                DebugLogger.shared.log("Backup", "Destination selected: \(dest.rawValue)")
                            }) {
                                HStack(spacing: 12) {
                                    Image(systemName: dest.iconName)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(selectedDestination == dest ? .blue : .secondary)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(dest.title)
                                            .font(.system(size: 15, weight: selectedDestination == dest ? .semibold : .regular))
                                            .foregroundColor(.primary)
                                        Text(dest == .googleDrive
                                             ? "Direct cloud stream • 0 MB iPhone storage used"
                                             : (dest == .webdav ? "Uploads archive to your WebDAV server" : "Saves .adbk file to local iPhone storage"))
                                            .font(.caption2)
                                            .foregroundColor(dest == .googleDrive ? .blue : .secondary)
                                    }
                                    Spacer()
                                    if selectedDestination == dest {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.blue)
                                            .font(.system(size: 18))
                                    } else {
                                        Image(systemName: "circle")
                                            .foregroundColor(.secondary.opacity(0.4))
                                            .font(.system(size: 18))
                                    }
                                }
                                .contentShape(Rectangle())
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }

                        if selectedDestination == .local {
                            let estimatedBytes = (selectedMode == .full ? currentApp.appSizeBytes : 0) + currentApp.dataSizeBytes + (includeAppGroups ? currentApp.groupSizeBytes : 0)
                            let freeBytes = Self.availableLocalDiskSpaceBytes()
                            if freeBytes < Int64.max && estimatedBytes > 0 && Double(estimatedBytes) * 0.7 > Double(freeBytes) {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(alignment: .top, spacing: 6) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundColor(.orange)
                                        Text("Low iPhone storage: \(ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)) free, app is ~\(ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .file)). Switch to Google Drive to stream with 0 MB local disk.")
                                            .font(.caption)
                                            .foregroundColor(.orange)
                                    }
                                    if googleDrive.isAuthenticated {
                                        Button(action: {
                                            selectedDestination = .googleDrive
                                            UserDefaults.standard.set(BackupDestination.googleDrive.rawValue, forKey: "appvault_last_backup_destination")
                                        }) {
                                            Label("Switch to Google Drive (0 MB Local Disk)", systemImage: "icloud.and.arrow.up.fill")
                                                .font(.caption.bold())
                                        }
                                        .buttonStyle(BorderlessButtonStyle())
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }

                        if selectedDestination == .webdav {
                            if webdav.isConfigured {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                    Text("Connected to \(webdav.serverURL)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            } else {
                                Text("WebDAV server is not configured. Please enter your credentials in Settings.")
                                    .font(.caption)
                                    .foregroundColor(.orange)
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
                                Text(enableEncryption
                                     ? "Archive will be compressed & AES-256-GCM encrypted on-the-fly and streamed directly to \(googleDrive.targetFolderName). Uses 0 MB of local storage."
                                     : "Archive will be compressed on-the-fly and streamed directly to \(googleDrive.targetFolderName). Uses 0 MB of local storage.")
                                    .font(.caption2)
                                    .foregroundColor(.blue)
                            } else {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Google Drive account is not connected.")
                                        .font(.caption)
                                        .foregroundColor(.orange)

                                    Button(action: { googleDrive.signIn() }) {
                                        HStack {
                                            Image(systemName: "person.badge.key.fill")
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

                    // Section 5: Granular Components & Options
                    Section(header: Text("Components & Options")) {
                        if !app.groupContainerURLs.isEmpty {
                            Toggle("Include Shared App Groups", isOn: $includeAppGroups)
                        }
                        Toggle("Include Keychain & Logins", isOn: $includeKeychain)
                        Toggle("Include Caches & Temp Files", isOn: $includeCaches)
                        TextField("Note / Label (optional)", text: $note)

                        Toggle("Encrypt with AES-256-GCM", isOn: $enableEncryption)
                        if enableEncryption {
                            SecureField("Set Backup Password (required)", text: $encryptionPassword)
                            if encryptionPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text("Enter a password to encrypt this archive with chunked AES-256-GCM.")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                }

                // Section 6: Execution Progress, Success, or Error Callout
                if let error = executionError {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: "exclamationmark.octagon.fill")
                                    .foregroundColor(.red)
                                Text("Backup Error")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.red)
                            }
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Button(action: { showDebugLogs = true }) {
                                Label("View Debug Logs", systemImage: "ladybug.fill")
                                    .font(.caption)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            .padding(.top, 2)
                        }
                        .padding(.vertical, 4)
                    }
                }

                if let record = completedRecord {
                    Section {
                        VStack(spacing: 12) {
                            HStack {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 32))
                                    .foregroundColor(.green)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Backup Created Successfully!")
                                        .font(.headline)
                                    Text("Size: \(record.formattedSize) \u{2022} Mode: \(record.mode.title)\(record.isEncrypted ? " \u{2022} Encrypted" : "")")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }

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
                        }
                        .padding(.vertical, 6)
                    }
                } else if isExecuting {
                    Section(header: Text(selectedDestination == .googleDrive ? "Streaming to Google Drive (0 MB Local Disk)" : (selectedDestination == .webdav ? "Uploading to WebDAV" : "Saving to iPhone Storage"))) {
                        VStack(spacing: 12) {
                            HStack(spacing: 6) {
                                Image(systemName: selectedDestination.iconName)
                                    .foregroundColor(selectedDestination == .googleDrive ? .green : .blue)
                                Text("Target: \(selectedDestination.title)")
                                    .font(.caption.bold())
                                    .foregroundColor(selectedDestination == .googleDrive ? .green : .primary)
                                Spacer()
                            }
                            if let progress = currentProgress {
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
                            } else {
                                ProgressView("Starting zero-staging stream...")
                            }

                            HStack(spacing: 16) {
                                Button(action: { showDebugLogs = true }) {
                                    Label("Live Logs", systemImage: "ladybug.fill")
                                        .font(.subheadline)
                                }
                                .buttonStyle(BorderlessButtonStyle())

                                Spacer()

                                Button(role: .destructive, action: cancelBackup) {
                                    Label("Cancel Backup", systemImage: "stop.circle.fill")
                                        .font(.subheadline)
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(BorderlessButtonStyle())
                            }
                            .padding(.top, 4)
                        }
                        .padding(.vertical, 8)
                    }
                } else {
                    Section {
                        Button(action: startBackup) {
                            HStack {
                                Spacer()
                                Label(actionButtonTitle, systemImage: actionButtonIcon)
                                    .font(.headline)
                                    .foregroundColor(.white)
                                Spacer()
                            }
                            .padding(.vertical, 6)
                        }
                        .disabled(isActionDisabled)
                        .listRowBackground(isActionDisabled ? Color.gray : Color.blue)
                    }
                }
            }
            .navigationTitle("Backup Application")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(completedRecord != nil ? "Done" : "Close") {
                        presentationMode.wrappedValue.dismiss()
                    }
                    .disabled(isExecuting)
                }
            }
            .onAppear {
                if !currentApp.isSized || (currentApp.appSizeBytes == 0 && currentApp.dataSizeBytes == 0) {
                    let targetApp = currentApp
                    sizingTask?.cancel()
                    sizingTask = Task {
                        let sizes: (appSize: Int64, dataSize: Int64, groupSize: Int64) = await withCheckedContinuation { continuation in
                            DispatchQueue.global(qos: .utility).async {
                                continuation.resume(returning: AppDiscoveryService.shared.calculateAppSizes(for: targetApp, forceRefresh: true))
                            }
                        }
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            currentApp.appSizeBytes = sizes.appSize
                            currentApp.dataSizeBytes = sizes.dataSize
                            currentApp.groupSizeBytes = sizes.groupSize
                            currentApp.isSized = true
                        }
                    }
                }
            }
            .onDisappear {
                sizingTask?.cancel()
            }
            .sheet(isPresented: $showDebugLogs) {
                NavigationView {
                    DebugLogsView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { showDebugLogs = false }
                            }
                        }
                }
                .navigationViewStyle(StackNavigationViewStyle())
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }


    private func cancelBackup() {
        activeTask?.cancel()
        activeTask = nil
        isExecuting = false
        DebugLogger.shared.log("Backup", "Backup cancelled by user.", level: .warning)
        executionError = "Backup cancelled by user."
    }

    private func startBackup() {
        // Snapshot all SwiftUI @State properties on MainActor before entering async execution
        let destination = selectedDestination
        let targetApp = currentApp
        let mode = selectedMode
        let caches = includeCaches
        let keychain = includeKeychain
        let groups = includeAppGroups
        let backupNote = note
        let password = enableEncryption ? encryptionPassword : nil
        let retentionLimit = SettingsViewModel.savedMaxBackupsPerApp

        isExecuting = true
        executionError = nil
        completedRecord = nil
        currentProgress = OperationProgress(
            stage: destination == .googleDrive ? "Connecting to Google Drive" : "Initializing",
            fractionCompleted: 0.02,
            statusDetail: destination == .googleDrive ? "Starting Google Drive upload pipeline..." : "Preparing stream..."
        )
        DebugLogger.shared.log("Backup", "User tapped Start Backup for \(targetApp.name) -> \(destination.rawValue) (mode=\(mode.rawValue), encrypted=\(password != nil && !(password!.isEmpty)))")

        sizingTask?.cancel()
        activeTask?.cancel()
        activeTask = Task(priority: .userInitiated) {
            do {
                if destination == .googleDrive {
                    let record = try await BackupEngine.shared.createGoogleDriveStreamingBackup(
                        for: targetApp,
                        mode: mode,
                        includeCaches: caches,
                        includeKeychain: keychain,
                        includeAppGroups: groups,
                        encryptionPassword: password,
                        note: backupNote
                    ) { progress in
                        Task { @MainActor in
                            self.currentProgress = progress
                        }
                    }

                    await MainActor.run {
                        self.isExecuting = false
                        self.completedRecord = record
                        self.backupsVM.refreshCloudBackups()
                    }
                } else if destination == .webdav {
                    let record = try await BackupEngine.shared.createWebDAVStreamingBackup(
                        for: targetApp,
                        mode: mode,
                        includeCaches: caches,
                        includeKeychain: keychain,
                        includeAppGroups: groups,
                        encryptionPassword: password,
                        note: backupNote
                    ) { progress in
                        Task { @MainActor in
                            self.currentProgress = progress
                        }
                    }

                    await MainActor.run {
                        self.isExecuting = false
                        self.completedRecord = record
                        self.backupsVM.refreshWebDAVBackups()
                    }
                } else {
                    let record = try await BackupEngine.shared.createStreamingBackup(
                        for: targetApp,
                        mode: mode,
                        includeCaches: caches,
                        includeKeychain: keychain,
                        includeAppGroups: groups,
                        encryptionPassword: password,
                        note: backupNote
                    ) { progress in
                        Task { @MainActor in
                            self.currentProgress = progress
                        }
                    }

                    if retentionLimit > 0 {
                        BackupEngine.shared.pruneOldBackups(for: targetApp.bundleIdentifier, keepNewest: retentionLimit)
                    }

                    await MainActor.run {
                        self.isExecuting = false
                        self.completedRecord = record
                        if retentionLimit > 0 {
                            self.backupsVM.refreshLocalBackups()
                        } else {
                            self.backupsVM.backups.insert(record, at: 0)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.isExecuting = false
                    DebugLogger.shared.log("Backup", "Backup failed for \(targetApp.name): \(error.localizedDescription)", level: .error)
                    self.executionError = error.localizedDescription
                }
            }
        }
    }
}
