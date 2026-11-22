import SwiftUI
import SQLite3

// MARK: - File Item Model
public struct ContainerFileItem: Identifiable, Hashable {
    public var id: String { url.path }
    public let url: URL
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let symlinkDestination: String?
    public let size: Int64
    public let modifiedDate: Date
    public let isReadable: Bool
    public let isWritable: Bool

    public var name: String { url.lastPathComponent }

    public var formattedSize: String {
        if isSymbolicLink {
            if let dest = symlinkDestination {
                return "Link \u{2192} \(dest)"
            }
            return "Symbolic Link"
        }
        if isDirectory {
            return "Folder"
        }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    public var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: modifiedDate)
    }

    public var iconName: String {
        if isSymbolicLink {
            return isDirectory ? "folder.badge.gearshape" : "arrow.triangle.turn.up.right.circle"
        }
        if isDirectory { return "folder.fill" }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "plist":
            return "slider.horizontal.3"
        case "sqlite", "db", "sqlite3", "wal", "shm":
            return "cylinder.split.1x2.fill"
        case "png", "jpg", "jpeg", "gif", "heic", "webp":
            return "photo"
        case "json", "txt", "log", "xml", "strings", "html":
            return "doc.text"
        case "zip", "adbk", "tar", "gz":
            return "archivebox.fill"
        case "p12", "cer", "key", "pem":
            return "key.fill"
        default:
            return "doc.fill"
        }
    }
}

private enum DataExplorerSheet: Identifiable {
    case plist(URL)
    case sqlite(URL)

    var id: String {
        switch self {
        case .plist(let u): return "plist_\(u.path)"
        case .sqlite(let u): return "sqlite_\(u.path)"
        }
    }
}

private struct ContainerRootOption: Identifiable, Hashable {
    let id: String
    let label: String
    let url: URL
}

// MARK: - Data Explorer View
public struct DataExplorerView: View {
    public let app: InstalledApp
    private let availableRoots: [ContainerRootOption]

    @State private var selectedRootID: String
    @State private var rootDirectory: URL
    @State private var currentDirectory: URL
    @State private var items: [ContainerFileItem] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil
    @State private var searchQuery: String = ""
    @State private var activeSheet: DataExplorerSheet? = nil
    @State private var deleteConfirmItem: ContainerFileItem? = nil
    @State private var deleteErrorMessage: String? = nil

    public init(app: InstalledApp) {
        self.app = app
        var roots: [ContainerRootOption] = []
        if let dataURL = app.dataContainerURL {
            roots.append(ContainerRootOption(id: "data", label: "Data Container", url: dataURL))
        }
        for groupID in app.groupContainerURLs.keys.sorted() {
            if let groupURL = app.groupContainerURLs[groupID] {
                roots.append(ContainerRootOption(id: "group_\(groupID)", label: "Group: \(groupID)", url: groupURL))
            }
        }
        if let bundleURL = app.bundleURL {
            roots.append(ContainerRootOption(id: "bundle", label: "App Bundle (.app)", url: bundleURL))
        }
        if roots.isEmpty {
            roots.append(ContainerRootOption(id: "root", label: "Filesystem Root", url: URL(fileURLWithPath: "/")))
        }
        self.availableRoots = roots
        let initial = roots[0]
        _selectedRootID = State(initialValue: initial.id)
        _rootDirectory = State(initialValue: initial.url)
        _currentDirectory = State(initialValue: initial.url)
    }

    private var canNavigateUp: Bool {
        let standardCurrent = currentDirectory.standardized.path
        let standardRoot = rootDirectory.standardized.path
        return standardCurrent != standardRoot && standardCurrent != "/"
    }

    private var filteredItems: [ContainerFileItem] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty {
            return items
        }
        return items.filter { $0.name.lowercased().contains(query) }
    }

    // Breadcrumbs Path Components relative to root (handles symlinks outside container safely)
    private var breadcrumbSegments: [(name: String, url: URL)] {
        var segments: [(name: String, url: URL)] = []
        var cursor = currentDirectory.standardized
        let root = rootDirectory.standardized
        let rootPrefix = root.path == "/" ? "/" : root.path + "/"
        let isInsideRoot = (cursor.path == root.path) || cursor.path.hasPrefix(rootPrefix)

        if isInsideRoot {
            while cursor.path != root.path && cursor.path != "/" {
                segments.append((name: cursor.lastPathComponent, url: cursor))
                cursor = cursor.deletingLastPathComponent().standardized
            }
            let rootName = availableRoots.first(where: { $0.id == selectedRootID })?.label ?? "Container"
            segments.append((name: rootName, url: root))
        } else {
            while cursor.path != "/" {
                segments.append((name: cursor.lastPathComponent, url: cursor))
                cursor = cursor.deletingLastPathComponent().standardized
            }
            segments.append((name: "/", url: URL(fileURLWithPath: "/")))
        }
        return segments.reversed()
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Container Switcher (Data / App Groups / App Bundle)
            if availableRoots.count > 1 {
                HStack {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.caption)
                        .foregroundColor(.blue)
                    Picker("Container", selection: $selectedRootID) {
                        ForEach(availableRoots) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .onChange(of: selectedRootID) { newID in
                        if let matched = availableRoots.first(where: { $0.id == newID }) {
                            rootDirectory = matched.url
                            currentDirectory = matched.url
                            searchQuery = ""
                            loadDirectory()
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(UIColor.tertiarySystemBackground))
                Divider()
            }

            // Header: Breadcrumb Trail & Quick Navigation
            navigationHeader

            // Search Filter Bar
            searchBar

            // Main Content Area
            contentArea
        }
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { loadDirectory() }) {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .onAppear {
            loadDirectory()
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .plist(let url):
                PlistEditorView(fileURL: url)
            case .sqlite(let url):
                SQLiteInspectorView(fileURL: url)
            }
        }
        .alert(isPresented: Binding<Bool>(
            get: { deleteErrorMessage != nil },
            set: { if !$0 { deleteErrorMessage = nil } }
        )) {
            Alert(
                title: Text("Deletion Error"),
                message: Text(deleteErrorMessage ?? "Unable to delete item."),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    // MARK: - Navigation Header (Breadcrumbs + Shortcuts)
    private var navigationHeader: some View {
        VStack(spacing: 4) {
            // Scrollable Breadcrumb Bar
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(breadcrumbSegments.enumerated()), id: \.offset) { index, segment in
                        Button(action: {
                            currentDirectory = segment.url
                            loadDirectory()
                        }) {
                            HStack(spacing: 4) {
                                if index == 0 {
                                    Image(systemName: "shippingbox.fill")
                                        .font(.system(size: 11))
                                }
                                Text(segment.name)
                                    .font(.system(size: 12, weight: index == breadcrumbSegments.count - 1 ? .bold : .regular))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(index == breadcrumbSegments.count - 1 ? Color.blue.opacity(0.15) : Color.clear)
                            .foregroundColor(index == breadcrumbSegments.count - 1 ? .blue : .primary)
                            .cornerRadius(6)
                        }

                        if index < breadcrumbSegments.count - 1 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer(minLength: 8)

                    if canNavigateUp {
                        Button(action: navigateUp) {
                            HStack(spacing: 2) {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 14))
                                Text("Up")
                                    .font(.caption2)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(UIColor.tertiarySystemFill))
                            .cornerRadius(6)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }

            // Quick Shortcut Chips
            quickShortcutsBar
        }
        .background(Color(UIColor.secondarySystemBackground))
    }

    // Quick Shortcuts: Documents, Library, Preferences, Caches, tmp
    private var quickShortcutsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                quickChip(title: "Root", path: rootDirectory.path)
                quickChip(title: "Documents", path: rootDirectory.appendingPathComponent("Documents").path)
                quickChip(title: "Preferences", path: rootDirectory.appendingPathComponent("Library/Preferences").path)
                quickChip(title: "App Support", path: rootDirectory.appendingPathComponent("Library/Application Support").path)
                quickChip(title: "Caches", path: rootDirectory.appendingPathComponent("Library/Caches").path)
                quickChip(title: "tmp", path: rootDirectory.appendingPathComponent("tmp").path)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }

    private func quickChip(title: String, path: String) -> some View {
        let exists = FileManager.default.fileExists(atPath: path)
        let isCurrent = currentDirectory.standardized.path == URL(fileURLWithPath: path).standardized.path

        return Button(action: {
            currentDirectory = URL(fileURLWithPath: path)
            loadDirectory()
        }) {
            Text(title)
                .font(.system(size: 10, weight: isCurrent ? .bold : .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(isCurrent ? Color.blue : (exists ? Color(UIColor.systemBackground) : Color(UIColor.systemGray5)))
                .foregroundColor(isCurrent ? .white : (exists ? .primary : .secondary.opacity(0.6)))
                .cornerRadius(4)
        }
        .disabled(!exists)
    }

    // MARK: - Search Bar
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.caption)
            TextField("Filter files in current folder...", text: $searchQuery)
                .font(.system(size: 13))
                .autocapitalization(.none)
                .disableAutocorrection(true)

            if !searchQuery.isEmpty {
                Button(action: { searchQuery = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(UIColor.tertiarySystemBackground))
        .cornerRadius(8)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - Content Area
    private var contentArea: some View {
        Group {
            if isLoading {
                Spacer()
                ProgressView("Scanning directory...")
                    .font(.caption)
                    .padding()
                Spacer()
            } else if let error = errorMessage {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.orange)
                    Text("Access Restricted")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    Button(action: { loadDirectory() }) {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.caption)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                }
                Spacer()
            } else if items.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 42))
                        .foregroundColor(.secondary)
                    Text("Directory is Empty")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else if filteredItems.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 38))
                        .foregroundColor(.secondary)
                    Text("No matching items found")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                List {
                    ForEach(filteredItems) { item in
                        fileRow(for: item)
                    }
                    .onDelete(perform: deleteItems)
                }
                .listStyle(PlainListStyle())
                .refreshable {
                    loadDirectory()
                }
            }
        }
    }

    // MARK: - File Row View
    private func fileRow(for item: ContainerFileItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.iconName)
                .font(.system(size: 20))
                .foregroundColor(item.isDirectory ? .blue : (item.isSymbolicLink ? .orange : .secondary))
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)

                    if item.isSymbolicLink {
                        Text("SYMLINK")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.2))
                            .foregroundColor(.orange)
                            .cornerRadius(3)
                    }
                }

                HStack(spacing: 6) {
                    Text(item.formattedSize)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Text("\u{2022}")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)

                    Text(item.formattedDate)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Context action button
            if item.isDirectory {
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
                    .font(.caption2)
            } else if item.url.pathExtension.lowercased() == "plist" {
                Button("Edit") {
                    activeSheet = .plist(item.url)
                }
                .buttonStyle(BorderlessButtonStyle())
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.12))
                .foregroundColor(.blue)
                .cornerRadius(6)
            } else if ["sqlite", "db", "sqlite3"].contains(item.url.pathExtension.lowercased()) {
                Button("Inspect") {
                    activeSheet = .sqlite(item.url)
                }
                .buttonStyle(BorderlessButtonStyle())
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.purple.opacity(0.12))
                .foregroundColor(.purple)
                .cornerRadius(6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            handleItemTap(item)
        }
    }

    // MARK: - Actions
    private func handleItemTap(_ item: ContainerFileItem) {
        if item.isDirectory {
            currentDirectory = item.url
            loadDirectory()
        } else if item.isSymbolicLink, let dest = item.symlinkDestination {
            let targetURL = (dest.hasPrefix("/") ? URL(fileURLWithPath: dest) : item.url.deletingLastPathComponent().appendingPathComponent(dest)).standardized
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDir), isDir.boolValue {
                currentDirectory = targetURL
                loadDirectory()
            } else {
                let ext = item.url.pathExtension.lowercased()
                if ext == "plist" { activeSheet = .plist(item.url) }
                else if ["sqlite", "db", "sqlite3"].contains(ext) { activeSheet = .sqlite(item.url) }
            }
        } else {
            let ext = item.url.pathExtension.lowercased()
            if ext == "plist" { activeSheet = .plist(item.url) }
            else if ["sqlite", "db", "sqlite3"].contains(ext) { activeSheet = .sqlite(item.url) }
        }
    }

    private func loadDirectory() {
        isLoading = true
        let targetDir = currentDirectory

        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            do {
                let contents = try fm.contentsOfDirectory(
                    at: targetDir,
                    includingPropertiesForKeys: [
                        .fileSizeKey,
                        .isDirectoryKey,
                        .isSymbolicLinkKey,
                        .contentModificationDateKey
                    ],
                    options: []
                )

                let loaded: [ContainerFileItem] = contents.map { url in
                    var isSymlink = false
                    var symlinkDest: String? = nil

                    if let res = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), res.isSymbolicLink == true {
                        isSymlink = true
                        symlinkDest = try? fm.destinationOfSymbolicLink(atPath: url.path)
                    }

                    var isDir = false
                    var fileSize: Int64 = 0
                    var modDate = Date()

                    if let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) {
                        isDir = vals.isDirectory ?? false
                        fileSize = Int64(vals.fileSize ?? 0)
                        modDate = vals.contentModificationDate ?? Date()
                    }

                    // For symlinks pointing to directories, detect target directory status
                    if isSymlink, let dest = symlinkDest {
                        let fullTarget = (dest.hasPrefix("/") ? URL(fileURLWithPath: dest) : url.deletingLastPathComponent().appendingPathComponent(dest)).standardized
                        var isTargetDir: ObjCBool = false
                        if fm.fileExists(atPath: fullTarget.path, isDirectory: &isTargetDir), isTargetDir.boolValue {
                            isDir = true
                        }
                    }

                    let readable = fm.isReadableFile(atPath: url.path)
                    let writable = fm.isWritableFile(atPath: url.path)

                    return ContainerFileItem(
                        url: url,
                        isDirectory: isDir,
                        isSymbolicLink: isSymlink,
                        symlinkDestination: symlinkDest,
                        size: fileSize,
                        modifiedDate: modDate,
                        isReadable: readable,
                        isWritable: writable
                    )
                }.sorted {
                    if $0.isDirectory != $1.isDirectory {
                        return $0.isDirectory && !$1.isDirectory
                    }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }

                await MainActor.run {
                    self.items = loaded
                    self.isLoading = false
                    self.errorMessage = nil
                }
            } catch {
                await MainActor.run {
                    self.items = []
                    self.isLoading = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func navigateUp() {
        guard canNavigateUp else { return }
        currentDirectory = currentDirectory.deletingLastPathComponent().standardized
        loadDirectory()
    }

    private func deleteItems(at offsets: IndexSet) {
        let fm = FileManager.default
        for index in offsets {
            guard index < filteredItems.count else { continue }
            let item = filteredItems[index]
            do {
                if fm.fileExists(atPath: item.url.path) {
                    try fm.removeItem(at: item.url)
                }
            } catch {
                deleteErrorMessage = "Cannot delete \(item.name): \(error.localizedDescription)"
            }
        }
        loadDirectory()
    }
}

// MARK: - Plist Entry Model
enum PlistEntryType: String, CaseIterable {
    case boolean = "Boolean"
    case string = "String"
    case number = "Number"
    case date = "Date"
    case data = "Data"
    case array = "Array"
    case dictionary = "Dictionary"
    case unknown = "Unknown"

    var badgeColor: Color {
        switch self {
        case .boolean: return .purple
        case .string: return .blue
        case .number: return .green
        case .date: return .orange
        case .data: return .gray
        case .array: return .indigo
        case .dictionary: return .teal
        case .unknown: return .secondary
        }
    }
}

struct PlistDisplayRow: Identifiable {
    let id: String
    let key: String
    let type: PlistEntryType
    let valueSummary: String
    let rawValue: Any
}

// MARK: - Plist Editor View
struct PlistEditorView: View {
    let fileURL: URL
    @Environment(\.presentationMode) var presentationMode

    @State private var plistFormat: PropertyListSerialization.PropertyListFormat = .xml
    @State private var rootDict: [String: Any]? = nil
    @State private var rootArray: [Any]? = nil
    @State private var displayRows: [PlistDisplayRow] = []
    @State private var searchQuery: String = ""
    @State private var loadError: String? = nil
    @State private var saveStatus: String? = nil
    @State private var editingRow: PlistDisplayRow? = nil
    @State private var editInput: String = ""
    @State private var editError: String? = nil

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if let status = saveStatus {
                    HStack {
                        Image(systemName: status.hasPrefix("Error") ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        Text(status)
                            .font(.caption)
                    }
                    .foregroundColor(status.hasPrefix("Error") ? .red : .green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(status.hasPrefix("Error") ? Color.red.opacity(0.1) : Color.green.opacity(0.1))
                }

                if let err = loadError {
                    Spacer()
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 44))
                            .foregroundColor(.orange)
                        Text("Failed to Read Plist")
                            .font(.headline)
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    Spacer()
                } else {
                    // Search bar
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Search keys or values...", text: $searchQuery)
                            .font(.system(size: 13))
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        if !searchQuery.isEmpty {
                            Button(action: { searchQuery = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(8)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(8)
                    .padding(.horizontal)
                    .padding(.vertical, 6)

                    List {
                        Section(header: Text("Entries (\(filteredRows.count))")) {
                            ForEach(filteredRows) { row in
                                plistRowView(for: row)
                            }
                        }
                    }
                    .listStyle(PlainListStyle())
                }
            }
            .navigationTitle(fileURL.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { savePlist() }
                        .disabled(loadError != nil)
                }
            }
            .onAppear { loadPlist() }
            .sheet(item: $editingRow) { row in
                editSheet(for: row)
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private var filteredRows: [PlistDisplayRow] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty { return displayRows }
        return displayRows.filter {
            $0.key.lowercased().contains(query) || $0.valueSummary.lowercased().contains(query)
        }
    }

    private func plistRowView(for row: PlistDisplayRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.key)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)

                Spacer()

                Text(row.type.rawValue)
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(row.type.badgeColor.opacity(0.15))
                    .foregroundColor(row.type.badgeColor)
                    .cornerRadius(4)
            }

            if row.type == .boolean {
                let boolVal = (row.rawValue as? Bool) ?? ((row.rawValue as? NSNumber)?.boolValue ?? false)
                Toggle(isOn: Binding(
                    get: { boolVal },
                    set: { newVal in
                        updateEntry(key: row.key, value: newVal)
                    }
                )) {
                    Text(boolVal ? "true" : "false")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            } else {
                HStack {
                    Text(row.valueSummary)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(2)

                    Spacer()

                    if row.type == .string || row.type == .number {
                        Button("Edit") {
                            editInput = row.valueSummary
                            editError = nil
                            editingRow = row
                        }
                        .buttonStyle(BorderlessButtonStyle())
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.blue.opacity(0.1))
                        .foregroundColor(.blue)
                        .cornerRadius(4)
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func editSheet(for row: PlistDisplayRow) -> some View {
        NavigationView {
            Form {
                Section(header: Text("Key")) {
                    Text(row.key)
                        .font(.system(size: 13, design: .monospaced))
                }

                Section(header: Text("Type: \(row.type.rawValue)")) {
                    if row.type == .number {
                        TextField("Enter numeric value", text: $editInput)
                            .keyboardType(.numbersAndPunctuation)
                            .font(.system(size: 14, design: .monospaced))
                    } else {
                        TextField("Enter string value", text: $editInput)
                            .font(.system(size: 14, design: .monospaced))
                    }

                    if let err = editError {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Edit Value")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        editError = nil
                        editingRow = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if applyEdit(row: row, newText: editInput) {
                            editError = nil
                            editingRow = nil
                        }
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    @discardableResult
    private func applyEdit(row: PlistDisplayRow, newText: String) -> Bool {
        if row.type == .number {
            let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
            if let intVal = Int(trimmed) {
                updateEntry(key: row.key, value: intVal)
                return true
            } else if let dblVal = Double(trimmed) {
                updateEntry(key: row.key, value: dblVal)
                return true
            } else {
                editError = "Invalid number. Enter an integer or decimal (e.g. 42 or 3.14) to preserve plist type."
                return false
            }
        } else {
            updateEntry(key: row.key, value: newText)
            return true
        }
    }

    private func updateEntry(key: String, value: Any) {
        if var dict = rootDict {
            dict[key] = value
            rootDict = dict
            rebuildDisplayRows()
        } else if var arr = rootArray, let idx = Int(key.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")), idx < arr.count {
            arr[idx] = value
            rootArray = arr
            rebuildDisplayRows()
        }
    }

    private func loadPlist() {
        do {
            let data = try Data(contentsOf: fileURL)
            var format: PropertyListSerialization.PropertyListFormat = .xml
            let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
            self.plistFormat = format

            if let dict = plist as? [String: Any] {
                self.rootDict = dict
                self.rootArray = nil
            } else if let arr = plist as? [Any] {
                self.rootArray = arr
                self.rootDict = nil
            } else {
                self.loadError = "Root of plist is neither Dictionary nor Array."
                return
            }

            rebuildDisplayRows()
            self.loadError = nil
        } catch {
            self.loadError = error.localizedDescription
        }
    }

    private func rebuildDisplayRows() {
        var rows: [PlistDisplayRow] = []

        if let dict = rootDict {
            for key in dict.keys.sorted() {
                if let val = dict[key] {
                    let type = detectType(of: val)
                    let summary = formatSummary(for: val, type: type)
                    rows.append(PlistDisplayRow(id: key, key: key, type: type, valueSummary: summary, rawValue: val))
                }
            }
        } else if let arr = rootArray {
            for (idx, val) in arr.enumerated() {
                let key = "[\(idx)]"
                let type = detectType(of: val)
                let summary = formatSummary(for: val, type: type)
                rows.append(PlistDisplayRow(id: key, key: key, type: type, valueSummary: summary, rawValue: val))
            }
        }

        self.displayRows = rows
    }

    private func detectType(of value: Any) -> PlistEntryType {
        if let num = value as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                return .boolean
            }
            return .number
        }
        if value is String { return .string }
        if value is Date { return .date }
        if value is Data { return .data }
        if value is [Any] { return .array }
        if value is [String: Any] { return .dictionary }
        return .unknown
    }

    private func formatSummary(for value: Any, type: PlistEntryType) -> String {
        switch type {
        case .boolean:
            let b = (value as? Bool) ?? ((value as? NSNumber)?.boolValue ?? false)
            return b ? "true" : "false"
        case .string:
            return (value as? String) ?? ""
        case .number:
            return "\(value)"
        case .date:
            if let date = value as? Date {
                let formatter = ISO8601DateFormatter()
                return formatter.string(from: date)
            }
            return "\(value)"
        case .data:
            if let data = value as? Data {
                return "<\(data.count) bytes>"
            }
            return "<Data>"
        case .array:
            if let arr = value as? [Any] {
                return "Array (\(arr.count) items)"
            }
            return "Array"
        case .dictionary:
            if let dict = value as? [String: Any] {
                return "Dictionary (\(dict.count) keys)"
            }
            return "Dictionary"
        case .unknown:
            return "\(String(describing: value))"
        }
    }

    private func savePlist() {
        do {
            let targetObj: Any = (rootDict as Any?) ?? (rootArray as Any?) ?? [:]
            let data = try PropertyListSerialization.data(fromPropertyList: targetObj, format: plistFormat, options: 0)
            try data.write(to: fileURL, options: .atomic)
            PosixHelper.shared.fixPermissions(at: fileURL.path)
            saveStatus = "Saved successfully!"
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.saveStatus = nil
            }
        } catch {
            saveStatus = "Error: \(error.localizedDescription)"
        }
    }
}

// MARK: - SQLite Inspector View
struct SQLiteInspectorView: View {
    let fileURL: URL
    @Environment(\.presentationMode) var presentationMode
    @State private var tables: [String] = []
    @State private var selectedTable: String? = nil
    @State private var tableRows: [[String]] = []
    @State private var columnNames: [String] = []
    @State private var errorMessage: String? = nil
    @State private var rowSearchQuery: String = ""

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if let error = errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.red.opacity(0.1))
                }

                if tables.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "cylinder.split.1x2")
                            .font(.system(size: 44))
                            .foregroundColor(.secondary)
                        Text("No User Tables Found")
                            .font(.headline)
                        Text("Database contains no user tables or is locked/encrypted.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                } else {
                    // Table Selection Bar
                    HStack {
                        Text("Table:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Picker("Table", selection: $selectedTable) {
                            ForEach(tables, id: \.self) { t in
                                Text(t).tag(t as String?)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())

                        Spacer()

                        Text("\(tableRows.count) rows")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .background(Color(UIColor.secondarySystemBackground))
                    .onChange(of: selectedTable) { newTable in
                        if let t = newTable { loadRows(for: t) }
                    }

                    // Row search filter
                    if !columnNames.isEmpty {
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                                .font(.caption)
                            TextField("Search in \(selectedTable ?? "table")...", text: $rowSearchQuery)
                                .font(.system(size: 12))
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                            if !rowSearchQuery.isEmpty {
                                Button(action: { rowSearchQuery = "" }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color(UIColor.tertiarySystemBackground))
                        .cornerRadius(6)
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                    }

                    // Records List
                    if filteredTableRows.isEmpty {
                        Spacer()
                        Text("No rows match the search query")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    } else {
                        List {
                            ForEach(0..<filteredTableRows.count, id: \.self) { i in
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(0..<columnNames.count, id: \.self) { colIdx in
                                        HStack(alignment: .top) {
                                            Text(columnNames[colIdx])
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundColor(.secondary)
                                                .frame(width: 85, alignment: .leading)
                                            Text(colIdx < filteredTableRows[i].count ? filteredTableRows[i][colIdx] : "NULL")
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundColor(.primary)
                                                .lineLimit(3)
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .listStyle(PlainListStyle())
                    }
                }
            }
            .navigationTitle(fileURL.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { presentationMode.wrappedValue.dismiss() }
                }
            }
            .onAppear { loadDatabase() }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private var filteredTableRows: [[String]] {
        let q = rowSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return tableRows }
        return tableRows.filter { row in
            row.contains { colVal in
                colVal.lowercased().contains(q)
            }
        }
    }

    private func loadDatabase() {
        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(fileURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        defer {
            if let db = db {
                sqlite3_close_v2(db)
            }
        }

        guard openResult == SQLITE_OK, let db = db else {
            let err = db != nil ? String(cString: sqlite3_errmsg(db)) : "Failed to open SQLite database"
            errorMessage = "SQLite Open Error: \(err)"
            return
        }

        var statement: OpaquePointer?
        let query = "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;"
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            defer {
                if let stmt = statement {
                    sqlite3_finalize(stmt)
                }
            }
            var found: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let name = sqlite3_column_text(statement, 0) {
                    found.append(String(cString: name))
                }
            }
            tables = found
            selectedTable = found.first
            if let first = found.first {
                loadRows(for: first)
            }
        } else {
            let err = String(cString: sqlite3_errmsg(db))
            errorMessage = "SQLite Query Error: \(err)"
        }
    }

    private func loadRows(for tableName: String) {
        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(fileURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        defer {
            if let db = db {
                sqlite3_close_v2(db)
            }
        }

        guard openResult == SQLITE_OK, let db = db else {
            errorMessage = "Unable to open database to read '\(tableName)'."
            return
        }

        var statement: OpaquePointer?
        let safeTable = tableName.replacingOccurrences(of: "\"", with: "\"\"")
        let query = "SELECT * FROM \"\(safeTable)\" LIMIT 100;"

        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            let err = String(cString: sqlite3_errmsg(db))
            errorMessage = "Error preparing query on \(tableName): \(err)"
            return
        }
        defer {
            if let stmt = statement {
                sqlite3_finalize(stmt)
            }
        }

        let colCount = sqlite3_column_count(statement)
        var cols: [String] = []
        for i in 0..<colCount {
            if let name = sqlite3_column_name(statement, i) {
                cols.append(String(cString: name))
            } else {
                cols.append("col_\(i)")
            }
        }
        columnNames = cols

        var rows: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String] = []
            for i in 0..<colCount {
                let colType = sqlite3_column_type(statement, i)
                switch colType {
                case SQLITE_INTEGER:
                    let val = sqlite3_column_int64(statement, i)
                    row.append("\(val)")
                case SQLITE_FLOAT:
                    let val = sqlite3_column_double(statement, i)
                    row.append(String(format: "%g", val))
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(statement, i) {
                        row.append(String(cString: text))
                    } else {
                        row.append("")
                    }
                case SQLITE_BLOB:
                    let bytes = sqlite3_column_bytes(statement, i)
                    row.append("<Blob \(bytes) B>")
                case SQLITE_NULL:
                    row.append("NULL")
                default:
                    if let text = sqlite3_column_text(statement, i) {
                        row.append(String(cString: text))
                    } else {
                        row.append("NULL")
                    }
                }
            }
            rows.append(row)
        }
        tableRows = rows
        errorMessage = nil
    }
}
