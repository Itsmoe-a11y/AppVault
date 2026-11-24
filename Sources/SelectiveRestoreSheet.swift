import SwiftUI

// MARK: - Selective Restore Sheet
public struct SelectiveRestoreSheet: View {
    public let record: BackupRecord
    public let archiveURL: URL
    public let onComplete: () -> Void

    @Environment(\.presentationMode) var presentationMode
    @State private var options = SelectiveRestoreOptions()
    @State private var decryptionPassword: String = ""
    @State private var needsPasswordPrompt: Bool = false

    // In-sheet execution state
    @State private var isExecuting: Bool = false
    @State private var currentProgress: OperationProgress? = nil
    @State private var executionError: String? = nil
    @State private var isCompleted: Bool = false

    public init(
        record: BackupRecord,
        archiveURL: URL? = nil,
        onComplete: @escaping () -> Void = {}
    ) {
        self.record = record
        self.archiveURL = archiveURL ?? BackupEngine.shared.backupsDirectory.appendingPathComponent(record.archiveFileName)
        self.onComplete = onComplete
    }

    private var requiresPassword: Bool {
        record.isEncrypted || needsPasswordPrompt
    }

    private var canStartRestore: Bool {
        guard options.hasAnySelected else { return false }
        if requiresPassword && decryptionPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        return true
    }

    public var body: some View {
        NavigationView {
            Form {
                // Section 1: Target Info
                Section(header: Text("Target Application")) {
                    HStack(spacing: 14) {
                        AppIconView(
                            bundleIdentifier: record.bundleIdentifier,
                            fallbackSystemName: record.mode == .full ? "shippingbox.fill" : "internaldrive.fill",
                            fallbackColor: record.mode == .full ? .purple : .blue,
                            size: 44
                        )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.appName)
                                .font(.headline)
                            Text(record.bundleIdentifier)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("Created \(record.formattedDate) \u{2022} \(record.formattedSize)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Section 2: In-Sheet Execution Status
                if isExecuting || isCompleted || executionError != nil {
                    Section(header: Text("Restoration Status")) {
                        if let error = executionError {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.red)
                                    Text("Restore Failed")
                                        .font(.headline)
                                        .foregroundColor(.red)
                                }
                                Text(error)
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                Button("Try Again") {
                                    executionError = nil
                                    isExecuting = false
                                }
                                .font(.caption)
                                .foregroundColor(.blue)
                                .padding(.top, 4)
                            }
                            .padding(.vertical, 4)
                        } else if isCompleted {
                            VStack(spacing: 12) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 44))
                                    .foregroundColor(.green)

                                Text("Application State Restored!")
                                    .font(.headline)

                                Text("All selected data for \(record.appName) was restored with correct permissions. You may now launch the application.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        } else if let progress = currentProgress {
                            VStack(spacing: 8) {
                                HStack {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text(progress.stage)
                                        .font(.system(size: 14, weight: .bold))
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
                            .padding(.vertical, 4)
                        }
                    }
                }

                if !isExecuting && !isCompleted {
                    // Section 2.5: AES-256-GCM Password Input (when encrypted)
                    if requiresPassword {
                        Section(header: Text("AES-256-GCM Decryption")) {
                            SecureField("Enter Backup Password", text: $decryptionPassword)
                            Text("This archive is encrypted. Enter the password used when creating the backup.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }

                    // Section 3: Safety Snapshot
                    Section(header: Text("Safety Protection")) {
                        Toggle(isOn: $options.createSafetySnapshot) {
                            Label("Pre-Restore Safety Snapshot", systemImage: "shield.lefthalf.filled")
                        }
                        Text("Automatically snapshots the app's current local data before overwriting, so you can always roll back.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    // Section 4: Component Selection Toggles
                    Section(header: HStack {
                        Text("Select Components to Restore")
                        Spacer()
                        Button(options.hasAnySelected ? "Deselect All" : "Select All") {
                            let targetState = !options.hasAnySelected
                            options.restoreDocuments = targetState
                            options.restorePreferences = targetState
                            options.restoreAppSupport = targetState
                            options.restoreAppGroups = targetState
                            options.restoreKeychain = targetState
                            options.restoreCaches = false
                        }
                        .font(.caption)
                        .textCase(.none)
                    }) {
                        Toggle(isOn: $options.restoreDocuments) {
                            Label("User Documents", systemImage: "doc.text.fill")
                        }

                        Toggle(isOn: $options.restorePreferences) {
                            Label("Preferences & Logins", systemImage: "gearshape.fill")
                        }

                        Toggle(isOn: $options.restoreAppSupport) {
                            Label("Databases & App State", systemImage: "cylinder.split.1x2.fill")
                        }

                        if !record.appGroupIDs.isEmpty || record.isEncrypted {
                            Toggle(isOn: $options.restoreAppGroups) {
                                Label(
                                    record.appGroupIDs.isEmpty ? "Shared App Groups" : "Shared App Groups (\(record.appGroupIDs.count))",
                                    systemImage: "rectangle.3.group.fill"
                                )
                            }
                        }

                        Toggle(isOn: $options.restoreKeychain) {
                            Label("Keychain Credentials", systemImage: "key.fill")
                        }

                        Toggle(isOn: $options.restoreCaches) {
                            Label("Caches & Temporary Files", systemImage: "trash.circle")
                        }
                    }

                    // Section 5: Restore Action Button
                    Section {
                        Button(action: startRestoreProcess) {
                            HStack {
                                Spacer()
                                Label(requiresPassword ? "Decrypt & Restore Data" : "Restore Selected Data", systemImage: "arrow.counterclockwise.circle.fill")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.white)
                                Spacer()
                            }
                            .padding(.vertical, 6)
                        }
                        .disabled(!canStartRestore)
                        .listRowBackground(canStartRestore ? Color.blue : Color.gray)

                        if !options.hasAnySelected {
                            Text("Please select at least one component to restore.")
                                .font(.caption2)
                                .foregroundColor(.orange)
                                .frame(maxWidth: .infinity, alignment: .center)
                        } else if requiresPassword && decryptionPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Enter the decryption password to continue.")
                                .font(.caption2)
                                .foregroundColor(.orange)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                }
            }
            .navigationTitle(isCompleted ? "Restore Finished" : "Selective Restore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isCompleted ? "Done" : "Cancel") {
                        if isCompleted {
                            onComplete()
                        }
                        presentationMode.wrappedValue.dismiss()
                    }
                    .disabled(isExecuting)
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func startRestoreProcess() {
        isExecuting = true
        executionError = nil
        isCompleted = false
        currentProgress = OperationProgress(stage: "Initializing", fractionCompleted: 0.05, statusDetail: "Preparing restoration...")

        let password = decryptionPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : decryptionPassword

        Task.detached(priority: .userInitiated) {
            do {
                _ = try await RestoreEngine.shared.restore(from: self.archiveURL, options: self.options, password: password) { p in
                    Task { @MainActor in
                        self.currentProgress = p
                    }
                }

                await MainActor.run {
                    self.isExecuting = false
                    self.isCompleted = true
                    self.onComplete()
                }
            } catch {
                await MainActor.run {
                    self.isExecuting = false
                    if case RestoreError.passwordRequired = error {
                        self.needsPasswordPrompt = true
                    }
                    self.executionError = error.localizedDescription
                }
            }
        }
    }
}
