import SwiftUI

public struct AppsListView: View {
    @EnvironmentObject var appsVM: AppsViewModel
    @EnvironmentObject var backupsVM: BackupsViewModel

    public init() {}

    public var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Search Header
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search installed apps...", text: $appsVM.searchQuery)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    if !appsVM.searchQuery.isEmpty {
                        Button(action: { appsVM.searchQuery = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(10)
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(10)
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 6)

                // Scope Selector
                Picker("App Scope", selection: $appsVM.showSystemApps) {
                    Text("User Apps").tag(false)
                    Text("All (System Included)").tag(true)
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding(.horizontal)
                .padding(.bottom, 8)

                Divider()

                // Content List
                if appsVM.isScanning && appsVM.apps.isEmpty {
                    Spacer()
                    ProgressView("Scanning installed applications...")
                        .padding()
                    Spacer()
                } else if appsVM.filteredApps.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "questionmark.app.dashed")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No Applications Found")
                            .font(.headline)
                        Text("Pull down to refresh or change search criteria.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(appsVM.filteredApps) { app in
                            AppRowView(app: app) {
                                appsVM.backupTargetApp = app
                            }
                        }
                    }
                    .listStyle(PlainListStyle())
                    .refreshable {
                        appsVM.refreshApps()
                    }
                }
            }
            .navigationTitle("Applications (\(appsVM.filteredApps.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { appsVM.refreshApps() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .sheet(item: $appsVM.backupTargetApp) { target in
                BackupDetailSheet(app: target)
                    .environmentObject(backupsVM)
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

// MARK: - App Row Component
struct AppRowView: View {
    let app: InstalledApp
    let onBackupTap: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: app.isSystemApp ? "gearshape.fill" : "app.fill")
                .font(.system(size: 28))
                .foregroundColor(app.isSystemApp ? .gray : .blue)
                .frame(width: 44, height: 44)
                .background(Color(UIColor.tertiarySystemFill))
                .cornerRadius(10)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(app.name)
                        .font(.headline)
                        .lineLimit(1)
                    if app.isSystemApp {
                        Text("SYS")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.2))
                            .cornerRadius(4)
                    }
                }

                Text(app.bundleIdentifier)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text("v\(app.version)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    if app.dataSizeBytes > 0 {
                        Text("• Data: \(ByteCountFormatter.string(fromByteCount: app.dataSizeBytes, countStyle: .file))")
                            .font(.system(size: 11))
                            .foregroundColor(.blue)
                    }
                }
            }

            Spacer()

            Button(action: onBackupTap) {
                Text("Backup")
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(16)
            }
            .buttonStyle(BorderlessButtonStyle())
        }
        .padding(.vertical, 4)
    }
}
