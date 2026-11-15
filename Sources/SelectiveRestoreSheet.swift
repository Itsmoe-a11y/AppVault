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
                Section(header: Text("Target Application")) {
                    HStack(spacing: 14) {
                        Image(systemName: "shippingbox.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.blue)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.appName)
                                .font(.headline)
                            Text(record.bundleIdentifier)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("Created \(record.formattedDate) • \(record.formattedSize)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section(header: Text("Select Components to Restore")) {
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
                    .listRowBackground(Color.blue)
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
    }
}
