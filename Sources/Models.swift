import Foundation
import UIKit
import Darwin

// MARK: - Thread-Safe Device Info Snapshot (Avoids @MainActor UIDevice calls on background threads)
public enum DeviceInfoSnapshot {
    public static let model: String = {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0)
            }
        }
        return machine ?? "iOS Device"
    }()

    public static let systemVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }()
}

// MARK: - Backup Mode
public enum BackupMode: String, Codable, CaseIterable, Identifiable {
    case full = "Full"
    case dataOnly = "DataOnly"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .full: return "Full (App + Data)"
        case .dataOnly: return "Data Only"
        }
    }

    public var subtitle: String {
        switch self {
        case .full: return "Preserves the .app bundle, container data, and shared App Groups."
        case .dataOnly: return "Backs up user data, preferences, databases, and shared App Groups."
        }
    }
}

// MARK: - Backup Destination
public enum BackupDestination: String, Codable, CaseIterable, Identifiable {
    case local = "Local"
    case googleDrive = "GoogleDrive"
    case webdav = "WebDAV"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .local: return "On Device"
        case .googleDrive: return "Google Drive"
        case .webdav: return "WebDAV / NAS"
        }
    }

    public var iconName: String {
        switch self {
        case .local: return "internaldrive"
        case .googleDrive: return "icloud.and.arrow.up"
        case .webdav: return "server.rack"
        }
    }
}

// MARK: - Backup List Scope
public enum BackupScope: String, CaseIterable, Identifiable {
    case onDevice = "On Device"
    case googleDrive = "Google Drive"
    case webdav = "WebDAV / NAS"

    public var id: String { rawValue }
}

// MARK: - Selective Restore Options
public struct SelectiveRestoreOptions: Codable, Equatable {
    public var restoreDocuments: Bool = true
    public var restorePreferences: Bool = true
    public var restoreAppSupport: Bool = true
    public var restoreAppGroups: Bool = true
    public var restoreKeychain: Bool = true
    public var restoreCaches: Bool = false
    public var createSafetySnapshot: Bool = true

    public init(
        restoreDocuments: Bool = true,
        restorePreferences: Bool = true,
        restoreAppSupport: Bool = true,
        restoreAppGroups: Bool = true,
        restoreKeychain: Bool = true,
        restoreCaches: Bool = false,
        createSafetySnapshot: Bool = true
    ) {
        self.restoreDocuments = restoreDocuments
        self.restorePreferences = restorePreferences
        self.restoreAppSupport = restoreAppSupport
        self.restoreAppGroups = restoreAppGroups
        self.restoreKeychain = restoreKeychain
        self.restoreCaches = restoreCaches
        self.createSafetySnapshot = createSafetySnapshot
    }

    public var hasAnySelected: Bool {
        restoreDocuments || restorePreferences || restoreAppSupport || restoreAppGroups || restoreKeychain || restoreCaches
    }
}

// MARK: - Installed Application Model
public struct InstalledApp: Identifiable, Hashable {
    public var id: String { bundleIdentifier }
    public let bundleIdentifier: String
    public let name: String
    public let version: String
    public let build: String
    public let bundleURL: URL?
    public let dataContainerURL: URL?
    public let groupContainerURLs: [String: URL]
    public let isSystemApp: Bool
    public var appSizeBytes: Int64
    public var dataSizeBytes: Int64
    public var groupSizeBytes: Int64
    public var isSized: Bool

    public var totalSizeBytes: Int64 {
        appSizeBytes + dataSizeBytes + groupSizeBytes
    }

    public init(
        bundleIdentifier: String,
        name: String,
        version: String = "1.0",
        build: String = "1",
        bundleURL: URL? = nil,
        dataContainerURL: URL? = nil,
        groupContainerURLs: [String: URL] = [:],
        isSystemApp: Bool = false,
        appSizeBytes: Int64 = 0,
        dataSizeBytes: Int64 = 0,
        groupSizeBytes: Int64 = 0,
        isSized: Bool = false
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name.isEmpty ? bundleIdentifier : name
        self.version = version.isEmpty ? "1.0" : version
        self.build = build.isEmpty ? "1" : build
        self.bundleURL = bundleURL
        self.dataContainerURL = dataContainerURL
        self.groupContainerURLs = groupContainerURLs
        self.isSystemApp = isSystemApp
        self.appSizeBytes = appSizeBytes
        self.dataSizeBytes = dataSizeBytes
        self.groupSizeBytes = groupSizeBytes
        self.isSized = isSized || (appSizeBytes > 0 || dataSizeBytes > 0 || groupSizeBytes > 0)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(bundleIdentifier)
    }

    public static func == (lhs: InstalledApp, rhs: InstalledApp) -> Bool {
        lhs.bundleIdentifier == rhs.bundleIdentifier
    }
}

// MARK: - Backup Metadata & Record Model
public struct BackupRecord: Identifiable, Codable, Hashable {
    public let id: UUID
    public let bundleIdentifier: String
    public let appName: String
    public let appVersion: String
    public let appBuild: String
    public let createdAt: Date
    public let mode: BackupMode
    public let includesCaches: Bool
    public var note: String
    public var archiveFileName: String
    public var fileSizeBytes: Int64
    public let hasAppBundle: Bool
    public let hasDataContainer: Bool
    public let appGroupIDs: [String]
    public let deviceModel: String
    public let systemVersion: String
    public var isEncrypted: Bool
    public var sha256Checksum: String?

    enum CodingKeys: String, CodingKey {
        case id, bundleIdentifier, appName, appVersion, appBuild, createdAt
        case mode, includesCaches, note, archiveFileName, fileSizeBytes
        case hasAppBundle, hasDataContainer, appGroupIDs, deviceModel, systemVersion
        case isEncrypted, sha256Checksum
    }

    public init(
        id: UUID = UUID(),
        bundleIdentifier: String,
        appName: String,
        appVersion: String,
        appBuild: String,
        createdAt: Date = Date(),
        mode: BackupMode,
        includesCaches: Bool,
        note: String = "",
        archiveFileName: String,
        fileSizeBytes: Int64 = 0,
        hasAppBundle: Bool,
        hasDataContainer: Bool,
        appGroupIDs: [String] = [],
        deviceModel: String = DeviceInfoSnapshot.model,
        systemVersion: String = DeviceInfoSnapshot.systemVersion,
        isEncrypted: Bool = false,
        sha256Checksum: String? = nil
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.createdAt = createdAt
        self.mode = mode
        self.includesCaches = includesCaches
        self.note = note
        self.archiveFileName = archiveFileName
        self.fileSizeBytes = fileSizeBytes
        self.hasAppBundle = hasAppBundle
        self.hasDataContainer = hasDataContainer
        self.appGroupIDs = appGroupIDs
        self.deviceModel = deviceModel
        self.systemVersion = systemVersion
        self.isEncrypted = isEncrypted
        self.sha256Checksum = sha256Checksum
    }

    // Backwards-compatible decoding for v2.1.x BackupMetadata.plist archives
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        bundleIdentifier = try c.decode(String.self, forKey: .bundleIdentifier)
        appName = try c.decode(String.self, forKey: .appName)
        appVersion = try c.decode(String.self, forKey: .appVersion)
        appBuild = try c.decode(String.self, forKey: .appBuild)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        mode = try c.decode(BackupMode.self, forKey: .mode)
        includesCaches = try c.decode(Bool.self, forKey: .includesCaches)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        archiveFileName = try c.decode(String.self, forKey: .archiveFileName)
        fileSizeBytes = try c.decodeIfPresent(Int64.self, forKey: .fileSizeBytes) ?? 0
        hasAppBundle = try c.decode(Bool.self, forKey: .hasAppBundle)
        hasDataContainer = try c.decode(Bool.self, forKey: .hasDataContainer)
        appGroupIDs = try c.decodeIfPresent([String].self, forKey: .appGroupIDs) ?? []
        deviceModel = try c.decodeIfPresent(String.self, forKey: .deviceModel) ?? DeviceInfoSnapshot.model
        systemVersion = try c.decodeIfPresent(String.self, forKey: .systemVersion) ?? DeviceInfoSnapshot.systemVersion
        isEncrypted = try c.decodeIfPresent(Bool.self, forKey: .isEncrypted) ?? false
        sha256Checksum = try c.decodeIfPresent(String.self, forKey: .sha256Checksum)
    }

    public var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: createdAt)
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }
}

// MARK: - Operation Progress State
public struct OperationProgress: Equatable {
    public var stage: String
    public var fractionCompleted: Double
    public var statusDetail: String
    public var isCompleted: Bool
    public var error: String?

    public init(
        stage: String = "",
        fractionCompleted: Double = 0.0,
        statusDetail: String = "",
        isCompleted: Bool = false,
        error: String? = nil
    ) {
        self.stage = stage
        self.fractionCompleted = fractionCompleted
        self.statusDetail = statusDetail
        self.isCompleted = isCompleted
        self.error = error
    }
}
