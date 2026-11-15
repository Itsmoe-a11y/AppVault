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
    public let onConfirm: (SelectiveRestoreOptions) -> Void

    @Environment(\.presentationMode) var presentationMode
    @State private var options = SelectiveRestoreOptions()

    public init(record: BackupRecord, onConfirm: @escaping (SelectiveRestoreOptions) -> Void) {
        self.record = record
        self.onConfirm = onConfirm
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

                // Section 2: Component Selection Toggles
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

                // Section 3: Restore Button
                Section {
                    Button(action: {
                        presentationMode.wrappedValue.dismiss()
                        onConfirm(options)
                    }) {
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
            .navigationTitle("Selective Restore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}
