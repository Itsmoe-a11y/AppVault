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

                // Scope Selector + Sort by Size & Multi-Backup Bar
                VStack(spacing: 8) {
                    Picker("App Scope", selection: $appsVM.showSystemApps) {
                        Text("User Apps").tag(false)
                        Text("All (System Included)").tag(true)
                    }
                    .pickerStyle(SegmentedPickerStyle())

                    HStack(spacing: 8) {
                        Menu {
                            ForEach(AppSortOrder.allCases) { order in
                                Button(action: { appsVM.sortOrder = order }) {
                                    HStack {
                                        Text(order.title)
                                        if appsVM.sortOrder == order {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.up.arrow.down")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("Sort: \(appsVM.sortOrder.shortLabel)")
                                    .font(.system(size: 12, weight: .semibold))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(UIColor.secondarySystemBackground))
                            .foregroundColor(appsVM.sortOrder == .nameAZ ? .primary : .blue)
                            .cornerRadius(8)
                        }

                        if appsVM.isScanning {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .scaleEffect(0.75)
                                Text("Sizing...")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Spacer()

                        Button(action: {
                            appsVM.isSelectionMode.toggle()
                            if !appsVM.isSelectionMode {
                                appsVM.clearSelection()
                            }
                        }) {
                            HStack(spacing: 5) {
                                Image(systemName: appsVM.isSelectionMode ? "checkmark.circle.fill" : "checklist")
                                    .font(.system(size: 12, weight: .semibold))
                                Text(appsVM.isSelectionMode ? "Done Selecting" : "Multi-Backup")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(appsVM.isSelectionMode ? Color.blue.opacity(0.15) : Color(UIColor.secondarySystemBackground))
                            .foregroundColor(.blue)
                            .cornerRadius(8)
                        }
                    }
                }
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
                            AppRowView(
                                app: app,
                                isScanning: appsVM.isScanning,
                                isSelectionMode: appsVM.isSelectionMode,
                                isSelected: appsVM.selectedAppIDs.contains(app.bundleIdentifier),
                                onToggleSelect: { appsVM.toggleSelection(for: app) },
                                onBackupTap: { appsVM.activeSheet = .backup(app) },
                                onExploreTap: { appsVM.activeSheet = .explore(app) }
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if appsVM.isSelectionMode {
                                    appsVM.toggleSelection(for: app)
                                }
                            }
                            .contextMenu {
                                Button(action: { appsVM.activeSheet = .backup(app) }) {
                                    Label("Back Up This App", systemImage: "arrow.down.doc.fill")
                                }
                                Button(action: {
                                    if !appsVM.isSelectionMode {
                                        appsVM.isSelectionMode = true
                                    }
                                    if !appsVM.selectedAppIDs.contains(app.bundleIdentifier) {
                                        appsVM.selectedAppIDs.insert(app.bundleIdentifier)
                                    }
                                }) {
                                    Label("Add to Multi-App Backup", systemImage: "checklist")
                                }
                                Button(action: { appsVM.activeSheet = .explore(app) }) {
                                    Label("Browse Container Files", systemImage: "folder.badge.gearshape")
                                }
                            }
                        }
                    }
                    .listStyle(PlainListStyle())
                    .refreshable {
                        appsVM.refreshApps()
                    }
                }

                // Bottom Floating Batch Action Bar
                if appsVM.isSelectionMode && !appsVM.selectedAppIDs.isEmpty {
                    VStack(spacing: 0) {
                        Divider()
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(appsVM.selectedAppIDs.count) App\(appsVM.selectedAppIDs.count == 1 ? "" : "s") Selected")
                                    .font(.system(size: 14, weight: .bold))
                                if appsVM.selectedTotalSizeBytes > 0 {
                                    Text("Est. \(ByteCountFormatter.string(fromByteCount: appsVM.selectedTotalSizeBytes, countStyle: .file))")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Spacer()

                            Button("Clear") {
                                appsVM.clearSelection()
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)

                            Button(action: {
                                appsVM.activeSheet = .batchBackup(appsVM.selectedApps)
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "square.and.arrow.down.on.square.fill")
                                    Text("Backup \(appsVM.selectedAppIDs.count)")
                                }
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.blue)
                                .cornerRadius(8)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 10)
                        .background(Color(UIColor.secondarySystemBackground))
                    }
                }
            }
            .navigationTitle("Applications (\(appsVM.filteredApps.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(appsVM.isSelectionMode ? "Done" : "Select") {
                        appsVM.isSelectionMode.toggle()
                        if !appsVM.isSelectionMode {
                            appsVM.clearSelection()
                        }
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    if appsVM.isSelectionMode {
                        Button("Select All") {
                            appsVM.selectAll()
                        }
                    } else {
                        Button(action: { appsVM.refreshApps() }) {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .sheet(item: $appsVM.activeSheet) { sheet in
            switch sheet {
            case .backup(let target):
                BackupDetailSheet(app: target)
                    .environmentObject(backupsVM)
            case .explore(let target):
                NavigationView {
                    DataExplorerView(app: target)
                }
                .navigationViewStyle(StackNavigationViewStyle())
            case .batchBackup(let targetApps):
                BatchBackupSheet(apps: targetApps)
                    .environmentObject(backupsVM)
            }
        }
    }
}

// MARK: - App Row Component
struct AppRowView: View {
    let app: InstalledApp
    let isScanning: Bool
    let isSelectionMode: Bool
    let isSelected: Bool
    let onToggleSelect: () -> Void
    let onBackupTap: () -> Void
    let onExploreTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if isSelectionMode {
                Button(action: onToggleSelect) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(isSelected ? .blue : .secondary)
                        .font(.system(size: 22))
                }
                .buttonStyle(BorderlessButtonStyle())
            }

            AppIconView(
                bundleIdentifier: app.bundleIdentifier,
                bundleURL: app.bundleURL,
                isSystemApp: app.isSystemApp,
                size: 42
            )

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

                HStack(spacing: 6) {
                    Text("v\(app.version)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    if !app.isSized {
                        Text("\u{2022} Calculating...")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    } else {
                        let totalData = app.dataSizeBytes + app.groupSizeBytes
                        if totalData > 0 {
                            Text("\u{2022} Data: \(ByteCountFormatter.string(fromByteCount: totalData, countStyle: .file))")
                                .font(.system(size: 11))
                                .foregroundColor(.blue)
                        }

                        if app.appSizeBytes > 0 {
                            Text("\u{2022} App: \(ByteCountFormatter.string(fromByteCount: app.appSizeBytes, countStyle: .file))")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }

                        if totalData == 0 && app.appSizeBytes == 0 {
                            Text("\u{2022} 0 KB")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Spacer()

            if !isSelectionMode {
                HStack(spacing: 8) {
                    Button(action: onExploreTap) {
                        Image(systemName: "folder.badge.gearshape")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                            .padding(6)
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(8)
                    }
                    .buttonStyle(BorderlessButtonStyle())

                    Button(action: onBackupTap) {
                        Text("Backup")
                            .font(.system(size: 13, weight: .bold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(14)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelectionMode {
                onToggleSelect()
            }
        }
    }
}
