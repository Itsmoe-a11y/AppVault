import SwiftUI

public struct BackupDetailSheet: View {
    public let app: InstalledApp
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var backupsVM: BackupsViewModel
    @ObservedObject var googleDrive = GoogleDriveService.shared
    @ObservedObject var webdav = WebDAVService.shared

    @State private var selectedMode: BackupMode
    @State private var selectedDestination: BackupDestination = .local
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

    public init(app: InstalledApp) {
        self.app = app
        _currentApp = State(initialValue: app)
        _selectedMode = State(initialValue: SettingsViewModel.savedDefaultBackupMode)
        _includeCaches = State(initialValue: SettingsViewModel.savedDefaultIncludeCaches)
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
            return enableEncryption ? "Encrypt & Upload to Google Drive" : "Stream Direct to Google Drive"
        case .webdav:
            return enableEncryption ? "Encrypt & Upload to WebDAV" : "Stream Backup to WebDAV"
        case .local:
            return enableEncryption ? "Create Encrypted Backup" : "Create Streaming Backup"
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

                    // Section 4: Destination
                    Section(header: Text("Destination")) {
                        Picker("Destination", selection: $selectedDestination) {
                            ForEach(BackupDestination.allCases) { dest in
                                Text(dest.title).tag(dest)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())

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
                                     ? "Archive will be encrypted with AES-256-GCM before uploading to \(googleDrive.targetFolderName)."
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
                    Section(header: Text("Creating Archive")) {
                        VStack(spacing: 12) {
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
                    Task.detached(priority: .userInitiated) {
                        let sizes = AppDiscoveryService.shared.calculateAppSizes(for: currentApp, forceRefresh: true)
                        await MainActor.run {
                            currentApp.appSizeBytes = sizes.appSize
                            currentApp.dataSizeBytes = sizes.dataSize
                            currentApp.groupSizeBytes = sizes.groupSize
                            currentApp.isSized = true
                        }
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func startBackup() {
        isExecuting = true
        executionError = nil
        completedRecord = nil
        currentProgress = OperationProgress(stage: "Initializing", fractionCompleted: 0.0, statusDetail: "Preparing stream...")

        let password = enableEncryption ? encryptionPassword : nil
        let retentionLimit = SettingsViewModel.savedMaxBackupsPerApp

        Task.detached(priority: .userInitiated) {
            do {
                if self.selectedDestination == .googleDrive {
                    let record = try await BackupEngine.shared.createGoogleDriveStreamingBackup(
                        for: self.currentApp,
                        mode: self.selectedMode,
                        includeCaches: self.includeCaches,
                        includeKeychain: self.includeKeychain,
                        includeAppGroups: self.includeAppGroups,
                        encryptionPassword: password,
                        note: self.note
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
                } else if self.selectedDestination == .webdav {
                    let record = try await BackupEngine.shared.createWebDAVStreamingBackup(
                        for: self.currentApp,
                        mode: self.selectedMode,
                        includeCaches: self.includeCaches,
                        includeKeychain: self.includeKeychain,
                        includeAppGroups: self.includeAppGroups,
                        encryptionPassword: password,
                        note: self.note
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
                        for: self.currentApp,
                        mode: self.selectedMode,
                        includeCaches: self.includeCaches,
                        includeKeychain: self.includeKeychain,
                        includeAppGroups: self.includeAppGroups,
                        encryptionPassword: password,
                        note: self.note
                    ) { progress in
                        Task { @MainActor in
                            self.currentProgress = progress
                        }
                    }

                    if retentionLimit > 0 {
                        BackupEngine.shared.pruneOldBackups(for: self.currentApp.bundleIdentifier, keepNewest: retentionLimit)
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
                    self.executionError = error.localizedDescription
                }
            }
        }
    }
}
