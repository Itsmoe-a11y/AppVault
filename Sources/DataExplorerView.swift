import SwiftUI
import SQLite3

// MARK: - File Item Model
public struct ContainerFileItem: Identifiable, Hashable {
    public var id: String { url.path }
    public let url: URL
    public let isDirectory: Bool
    public let size: Int64
    public let modifiedDate: Date

    public var name: String { url.lastPathComponent }

    public var formattedSize: String {
        isDirectory ? "Folder" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    public var iconName: String {
        if isDirectory { return "folder.fill" }
        let ext = url.pathExtension.lowercased()
        if ext == "plist" { return "slider.horizontal.3" }
        if ext == "sqlite" || ext == "db" || ext == "sqlite3" { return "cylinder.split.1x2.fill" }
        if ext == "png" || ext == "jpg" { return "photo" }
        if ext == "json" || ext == "txt" { return "doc.text" }
        return "doc.fill"
    }
}

// MARK: - Data Explorer View
public struct DataExplorerView: View {
    public let app: InstalledApp
    @State private var currentDirectory: URL
    @State private var items: [ContainerFileItem] = []
    @State private var selectedPlistURL: URL? = nil
    @State private var selectedSQLiteURL: URL? = nil
    @State private var deleteConfirmItem: ContainerFileItem? = nil

    public init(app: InstalledApp) {
        self.app = app
        _currentDirectory = State(initialValue: app.dataContainerURL ?? URL(fileURLWithPath: "/"))
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Path Navigation Breadcrumbs
            HStack {
                Text(currentDirectory.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if currentDirectory != app.dataContainerURL {
                    Button(action: navigateUp) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 20))
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(UIColor.secondarySystemBackground))

            // File Listing
            if items.isEmpty {
                Spacer()
                Text("Directory is Empty")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(items) { item in
                        HStack(spacing: 12) {
                            Image(systemName: item.iconName)
                                .font(.system(size: 22))
                                .foregroundColor(item.isDirectory ? .blue : .secondary)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.system(size: 14, weight: .medium))
                                    .lineLimit(1)
                                Text(item.formattedSize)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            // Action button based on type
                            if item.isDirectory {
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            } else if item.url.pathExtension.lowercased() == "plist" {
                                Button("Edit") {
                                    selectedPlistURL = item.url
                                }
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.15))
                                .foregroundColor(.blue)
                                .cornerRadius(6)
                            } else if ["sqlite", "db", "sqlite3"].contains(item.url.pathExtension.lowercased()) {
                                Button("Inspect") {
                                    selectedSQLiteURL = item.url
                                }
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.purple.opacity(0.15))
                                .foregroundColor(.purple)
                                .cornerRadius(6)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if item.isDirectory {
                                currentDirectory = item.url
                                loadDirectory()
                            }
                        }
                    }
                    .onDelete(perform: deleteItems)
                }
                .listStyle(PlainListStyle())
            }
        }
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadDirectory()
        }
        .sheet(item: Binding<URLItem?>(
            get: { selectedPlistURL.map { URLItem(url: $0) } },
            set: { selectedPlistURL = $0?.url }
        )) { item in
            PlistEditorView(fileURL: item.url)
        }
        .sheet(item: Binding<URLItem?>(
            get: { selectedSQLiteURL.map { URLItem(url: $0) } },
            set: { selectedSQLiteURL = $0?.url }
        )) { item in
            SQLiteInspectorView(fileURL: item.url)
        }
    }

    private func loadDirectory() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: currentDirectory, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .contentModificationDateKey], options: []) else {
            items = []
            return
        }

        items = contents.map { url in
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .contentModificationDateKey])
            return ContainerFileItem(
                url: url,
                isDirectory: vals?.isDirectory ?? false,
                size: Int64(vals?.fileSize ?? 0),
                modifiedDate: vals?.contentModificationDate ?? Date()
            )
        }.sorted {
            if $0.isDirectory != $1.isDirectory {
                return $0.isDirectory && !$1.isDirectory
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func navigateUp() {
        guard currentDirectory != app.dataContainerURL else { return }
        currentDirectory = currentDirectory.deletingLastPathComponent()
        loadDirectory()
    }

    private func deleteItems(at offsets: IndexSet) {
        let fm = FileManager.default
        for index in offsets {
            let item = items[index]
            try? fm.removeItem(at: item.url)
        }
        loadDirectory()
    }
}

// MARK: - Plist Editor View
struct PlistEditorView: View {
    let fileURL: URL
    @Environment(\.presentationMode) var presentationMode
    @State private var plistDict: [String: Any] = [:]
    @State private var keys: [String] = []
    @State private var editKey: String = ""
    @State private var editValue: String = ""
    @State private var isEditingKey = false
    @State private var saveStatus: String? = nil

    var body: some View {
        NavigationView {
            Form {
                if let status = saveStatus {
                    Section {
                        Text(status)
                            .foregroundColor(.green)
                            .font(.caption)
                    }
                }

                Section(header: Text("Entries (\(keys.count))")) {
                    ForEach(keys, id: \.self) { key in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(key)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.primary)

                            let val = plistDict[key]
                            if let b = val as? Bool {
                                Toggle(isOn: Binding(
                                    get: { b },
                                    set: { plistDict[key] = $0 }
                                )) {
                                    Text(b ? "true" : "false")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            } else {
                                Text("\(String(describing: val ?? ""))")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
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
                }
            }
            .onAppear { loadPlist() }
        }
    }

    private func loadPlist() {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return
        }
        plistDict = dict
        keys = Array(dict.keys).sorted()
    }

    private func savePlist() {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
            try data.write(to: fileURL)
            PosixHelper.shared.fixPermissions(at: fileURL.path)
            saveStatus = "Saved successfully!"
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

    var body: some View {
        NavigationView {
            VStack {
                if tables.isEmpty {
                    Spacer()
                    Text("No Tables Found in SQLite Database")
                        .foregroundColor(.secondary)
                    Spacer()
                } else {
                    Picker("Table", selection: $selectedTable) {
                        ForEach(tables, id: \.self) { t in
                            Text(t).tag(t as String?)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .padding()
                    .onChange(of: selectedTable) { newTable in
                        if let t = newTable { loadRows(for: t) }
                    }

                    List {
                        ForEach(0..<tableRows.count, id: \.self) { i in
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(0..<columnNames.count, id: \.self) { colIdx in
                                    HStack {
                                        Text(columnNames[colIdx])
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .frame(width: 80, alignment: .leading)
                                        Text(colIdx < tableRows[i].count ? tableRows[i][colIdx] : "")
                                            .font(.system(size: 12, design: .monospaced))
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
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
    }

    private func loadDatabase() {
        var db: OpaquePointer?
        guard sqlite3_open_v2(fileURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        let query = "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;"
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            var found: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let name = sqlite3_column_text(statement, 0) {
                    found.append(String(cString: name))
                }
            }
            sqlite3_finalize(statement)
            tables = found
            selectedTable = found.first
            if let first = found.first {
                loadRows(for: first)
            }
        }
    }

    private func loadRows(for tableName: String) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(fileURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        let query = "SELECT * FROM \"\(tableName)\" LIMIT 50;"
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            let colCount = sqlite3_column_count(statement)
            var cols: [String] = []
            for i in 0..<colCount {
                if let name = sqlite3_column_name(statement, i) {
                    cols.append(String(cString: name))
                }
            }
            columnNames = cols

            var rows: [[String]] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                var row: [String] = []
                for i in 0..<colCount {
                    if let text = sqlite3_column_text(statement, i) {
                        row.append(String(cString: text))
                    } else {
                        row.append("NULL")
                    }
                }
                rows.append(row)
            }
            sqlite3_finalize(statement)
            tableRows = rows
        }
    }
}
