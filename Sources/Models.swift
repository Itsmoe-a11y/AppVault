import Foundation
import UIKit

// MARK: - Backup Mode
public enum BackupMode: String, Codable, CaseIterable, Identifiable {
    case dataOnly = "data_only"
    case full = "full"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dataOnly: return "Data Only"
        case .full: return "Full (App + Data)"
        }
    }

    public var subtitle: String {
        switch self {
        case .dataOnly:
            return "Backs up login sessions, settings, databases, and user documents. Compact and fast."
        case .full:
            return "Backs up the entire .app binary along with all app data and shared groups."
        }
    }

    public var iconName: String {
        switch self {
        case .dataOnly: return "internaldrive"
        case .full: return "shippingbox.fill"
        }
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

    // Calculated disk sizes in bytes
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
    public let archiveFileName: String
    public var fileSizeBytes: Int64
    public let hasAppBundle: Bool
    public let hasDataContainer: Bool
    public let appGroupIDs: [String]
    public let deviceModel: String
    public let systemVersion: String

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
        deviceModel: String = UIDevice.current.model,
        systemVersion: String = UIDevice.current.systemVersion
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
