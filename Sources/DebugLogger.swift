import Foundation
import SwiftUI
import UIKit

public enum DebugLogLevel: String, CaseIterable {
    case info = "INFO"
    case success = "OK"
    case warning = "WARN"
    case error = "ERR"

    public var color: Color {
        switch self {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

public struct DebugLogEntry: Identifiable, Hashable {
    public let id = UUID()
    public let timestamp: Date
    public let level: DebugLogLevel
    public let category: String
    public let message: String

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    public var formattedTime: String {
        Self.timeFormatter.string(from: timestamp)
    }

    public var formattedLine: String {
        "[\(formattedTime)] [\(level.rawValue)] [\(category)] \(message)"
    }
}

public final class DebugLogger: ObservableObject {
    public static let shared = DebugLogger()

    @Published public private(set) var entries: [DebugLogEntry] = []

    private let lock = NSLock()
    private var buffer: [DebugLogEntry] = []
    private let maxEntries = 600

    private init() {
        log("System", "AppVault session started (iOS \(DeviceInfoSnapshot.systemVersion), \(DeviceInfoSnapshot.model))", level: .info)
    }

    /// Redacts sensitive bearer tokens, OAuth secrets, and authorization codes before storing or copying logs.
    public static func redact(_ raw: String) -> String {
        var text = raw
        let patterns: [(String, String)] = [
            ("Bearer\\s+[A-Za-z0-9._\\-~+/=]+", "Bearer [REDACTED]"),
            ("\"(access_token|refresh_token|client_secret|id_token)\"\\s*:\\s*\"[^\"]+\"", "\"$1\":\"[REDACTED]\""),
            ("(access_token|refresh_token|client_secret|code)=[^&\\s]+", "$1=[REDACTED]")
        ]
        for (pattern, replacement) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(text.startIndex..., in: text)
                text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
            }
        }
        return text
    }

    public func log(_ category: String, _ message: String, level: DebugLogLevel = .info) {
        let safeMessage = Self.redact(message)
        let entry = DebugLogEntry(timestamp: Date(), level: level, category: category, message: safeMessage)

        lock.lock()
        buffer.append(entry)
        if buffer.count > maxEntries {
            buffer.removeFirst(buffer.count - maxEntries)
        }
        let snapshot = buffer
        lock.unlock()

        DispatchQueue.main.async {
            self.entries = snapshot
        }
    }

    public func clear() {
        lock.lock()
        buffer.removeAll()
        lock.unlock()

        DispatchQueue.main.async {
            self.entries = []
        }
        log("System", "Debug logs cleared by user.", level: .info)
    }

    @MainActor
    public func exportTextReport() -> String {
        let shortVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.2.0"
        let buildVer = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "15"
        let gd = GoogleDriveService.shared
        let header = """
        === AppVault Debug Report ===
        Version: \(shortVer) (Build \(buildVer))
        Device: \(DeviceInfoSnapshot.model) • iOS \(DeviceInfoSnapshot.systemVersion)
        Google Drive Authenticated: \(gd.isAuthenticated)
        Google Drive Folder: \(gd.targetFolderName)
        Bundled Client ID Active: \(gd.hasBundledDefaultClientId)
        Custom Client ID Override: \(!gd.customClientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Rclone Override Detected: \(gd.isUsingRcloneClientOverride)
        WebDAV Configured: \(WebDAVService.shared.isConfigured)
        Entries: \(entries.count)
        =============================
        """
        let lines = entries.map(\.formattedLine).joined(separator: "\n")
        return header + "\n" + lines
    }
}

// MARK: - SwiftUI Debug Logs Viewer
public struct DebugLogsView: View {
    @ObservedObject var logger = DebugLogger.shared
    @State private var selectedCategory: String = "All"
    @State private var errorsOnly: Bool = false
    @State private var copiedBanner: Bool = false

    private let categories = ["All", "GoogleDrive", "OAuth", "Backup", "Restore", "Export", "System"]

    public init() {}

    private var filteredEntries: [DebugLogEntry] {
        logger.entries.reversed().filter { entry in
            if errorsOnly && entry.level != .error && entry.level != .warning {
                return false
            }
            if selectedCategory != "All" && entry.category != selectedCategory {
                return false
            }
            return true
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Controls Bar
            VStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(categories, id: \.self) { cat in
                            Button(action: { selectedCategory = cat }) {
                                Text(cat)
                                    .font(.caption.weight(selectedCategory == cat ? .bold : .regular))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(selectedCategory == cat ? Color.blue : Color(UIColor.secondarySystemBackground))
                                    .foregroundColor(selectedCategory == cat ? .white : .primary)
                                    .cornerRadius(6)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                        }
                    }
                    .padding(.horizontal, 12)
                }

                HStack {
                    Toggle("Warnings & Errors Only", isOn: $errorsOnly)
                        .font(.caption)
                    Spacer()
                    Text("\(filteredEntries.count) events")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
            }
            .padding(.vertical, 8)
            .background(Color(UIColor.systemBackground))

            Divider()

            if copiedBanner {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Sanitized debug log copied to clipboard (tokens redacted).")
                        .font(.caption)
                }
                .foregroundColor(.green)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.green.opacity(0.1))
            }

            if filteredEntries.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No matching log entries yet")
                        .font(.headline)
                    Text("Try a Google Drive sign-in, upload, or export — every step and HTTP status will appear here.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }
                Spacer()
            } else {
                List(filteredEntries) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(entry.formattedTime)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text(entry.level.rawValue)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(entry.level.color)
                            Text("[\(entry.category)]")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(.primary)
                        }
                        Text(entry.message)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(entry.level == .error ? .red : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(PlainListStyle())
            }
        }
        .navigationTitle("Debug Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button(action: {
                    UIPasteboard.general.string = logger.exportTextReport()
                    copiedBanner = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        copiedBanner = false
                    }
                }) {
                    Image(systemName: "doc.on.doc")
                }

                Button(action: { logger.clear() }) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
            }
        }
    }
}
