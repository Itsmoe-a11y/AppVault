import SwiftUI

// MARK: - Selective Restore Options Model
public struct SelectiveRestoreOptions {
    public var restoreDocuments: Bool = true
    public var restorePreferences: Bool = true
    public var restoreAppSupport: Bool = true
    public var restoreAppGroups: Bool = true
    public var restoreKeychain: Bool = true
    public var restoreCaches: Bool = false

    public init() {}

    public var hasAnySelected: Bool {
        restoreDocuments || restorePreferences || restoreAppSupport || restoreAppGroups || restoreKeychain || restoreCaches
    }
}

// MARK: - Selective Restore Sheet
public struct SelectiveRestoreSheet: View {
    public let record: BackupRecord
    public let archiveURL: URL
    public let onComplete: () -> Void

    @Environment(\.presentationMode) var presentationMode
    @State private var options = SelectiveRestoreOptions()

    // In-sheet execution state (100% collision-free on iOS 16)
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

    public var body: some View {
        NavigationView {
            Form {
                // Section 1: Target Info
                Section(header: Text("Target Application")) {
                    HStack(spacing: 14) {
                        Image(systemName: record.mode == .full ? "shippingbox.fill" : "internaldrive.fill")
                            .font(.system(size: 28))
                            .foregroundColor(record.mode == .full ? .purple : .blue)

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

                // Section 2: In-Sheet Execution Status (if executing or completed)
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
                    // Section 3: Component Selection Toggles
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

                        if !record.appGroupIDs.isEmpty {
                            Toggle(isOn: $options.restoreAppGroups) {
                                Label("Shared App Groups (\(record.appGroupIDs.count))", systemImage: "rectangle.3.group.fill")
                            }
                        }

                        Toggle(isOn: $options.restoreKeychain) {
                            Label("Keychain Credentials", systemImage: "key.fill")
                        }

                        Toggle(isOn: $options.restoreCaches) {
                            Label("Caches & Temporary Files", systemImage: "trash.circle")
                        }
                    }

                    // Section 4: Restore Action Button
                    Section {
                        Button(action: startRestoreProcess) {
                            HStack {
                                Spacer()
                                Label("Restore Selected Data", systemImage: "arrow.counterclockwise.circle.fill")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.white)
                                Spacer()
                            }
                            .padding(.vertical, 6)
                        }
                        .disabled(!options.hasAnySelected)
                        .listRowBackground(options.hasAnySelected ? Color.blue : Color.gray)

                        if !options.hasAnySelected {
                            Text("Please select at least one component to restore.")
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

        Task.detached(priority: .userInitiated) {
            do {
                _ = try await RestoreEngine.shared.restore(from: self.archiveURL, options: self.options) { p in
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
                    self.executionError = error.localizedDescription
                }
            }
        }
    }
}
