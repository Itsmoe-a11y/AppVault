import Foundation
import UIKit

public final class AppDiscoveryService {
    public static let shared = AppDiscoveryService()

    private let fileManager = FileManager.default

    private init() {}

    // MARK: - Enumerate Installed Applications
    public func fetchInstalledApps() -> [InstalledApp] {
        // Try Primary Method: LSApplicationWorkspace via Objective-C Runtime
        var apps = fetchViaLSApplicationWorkspace()

        // If empty or missing apps, run filesystem scan fallback
        if apps.isEmpty {
            apps = scanFilesystemForApps()
        }

        // Sort alphabetically by display name
        return apps.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Primary: LSApplicationWorkspace
    private func fetchViaLSApplicationWorkspace() -> [InstalledApp] {
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              workspaceClass.responds(to: Selector(("defaultWorkspace"))),
              let workspace = workspaceClass.perform(Selector(("defaultWorkspace")))?.takeUnretainedValue() else {
            return []
        }

        let selector = Selector(("allInstalledApplications"))
        guard workspace.responds(to: selector),
              let appProxies = workspace.perform(selector)?.takeUnretainedValue() as? [NSObject] else {
            return []
        }

        var results: [InstalledApp] = []

        for proxy in appProxies {
            // Bundle Identifier
            guard let bundleID = stringProperty(proxy, selectorName: "applicationIdentifier") ??
                                 stringProperty(proxy, selectorName: "bundleIdentifier"),
                  !bundleID.isEmpty else {
                continue
            }

            // Exclude our own app from backup list to avoid recursive self-backup
            if bundleID == Bundle.main.bundleIdentifier {
                continue
            }

            // Display Name
            let displayName = stringProperty(proxy, selectorName: "localizedName") ??
                              stringProperty(proxy, selectorName: "itemName") ??
                              bundleID

            // Versions
            let shortVersion = stringProperty(proxy, selectorName: "shortVersionString") ?? "1.0"
            let buildVersion = stringProperty(proxy, selectorName: "bundleVersion") ?? "1"

            // URLs
            let bundleURL = urlProperty(proxy, selectorName: "bundleURL")
            let dataContainerURL = urlProperty(proxy, selectorName: "dataContainerURL")
            let groupContainerURLs = groupContainersProperty(proxy)

            // System App Check
            let appType = stringProperty(proxy, selectorName: "applicationType") ?? "User"
            let isSystem = (appType.caseInsensitiveCompare("System") == .orderedSame)

            let app = InstalledApp(
                bundleIdentifier: bundleID,
                name: displayName,
                version: shortVersion,
                build: buildVersion,
                bundleURL: bundleURL,
                dataContainerURL: dataContainerURL,
                groupContainerURLs: groupContainerURLs,
                isSystemApp: isSystem
            )
            results.append(app)
        }

        return results
    }

    // MARK: - Fallback: Filesystem Scanner
    private func scanFilesystemForApps() -> [InstalledApp] {
        var results: [String: InstalledApp] = [:]

        // 1. Scan Bundle Applications
        let bundleRoot = URL(fileURLWithPath: "/var/containers/Bundle/Application")
        if let bundleUUIDs = try? fileManager.contentsOfDirectory(at: bundleRoot, includingPropertiesForKeys: nil) {
            for uuidDir in bundleUUIDs {
                guard let contents = try? fileManager.contentsOfDirectory(at: uuidDir, includingPropertiesForKeys: nil) else { continue }
                guard let appBundle = contents.first(where: { $0.pathExtension == "app" }) else { continue }

                let infoPlistPath = appBundle.appendingPathComponent("Info.plist")
                guard let plistData = try? Data(contentsOf: infoPlistPath),
                      let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
                    continue
                }

                guard let bundleID = plist["CFBundleIdentifier"] as? String else { continue }
                let appName = (plist["CFBundleDisplayName"] as? String) ??
                              (plist["CFBundleName"] as? String) ??
                              appBundle.deletingPathExtension().lastPathComponent
                let version = (plist["CFBundleShortVersionString"] as? String) ?? "1.0"
                let build = (plist["CFBundleVersion"] as? String) ?? "1"

                results[bundleID] = InstalledApp(
                    bundleIdentifier: bundleID,
                    name: appName,
                    version: version,
                    build: build,
                    bundleURL: appBundle,
                    isSystemApp: false
                )
            }
        }

        // 2. Match Data Containers
        let dataRoot = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application")
        if let dataUUIDs = try? fileManager.contentsOfDirectory(at: dataRoot, includingPropertiesForKeys: nil) {
            for uuidDir in dataUUIDs {
                let metaPlist = uuidDir.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
                if let data = try? Data(contentsOf: metaPlist),
                   let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                   let identifier = dict["MCMMetadataIdentifier"] as? String {
                    if var existing = results[identifier] {
                        results[identifier] = InstalledApp(
                            bundleIdentifier: existing.bundleIdentifier,
                            name: existing.name,
                            version: existing.version,
                            build: existing.build,
                            bundleURL: existing.bundleURL,
                            dataContainerURL: uuidDir,
                            groupContainerURLs: existing.groupContainerURLs,
                            isSystemApp: existing.isSystemApp
                        )
                    }
                }
            }
        }

        return Array(results.values)
    }

    // MARK: - Disk Size Calculations
    public func calculateAppSizes(for app: InstalledApp) -> (appSize: Int64, dataSize: Int64, groupSize: Int64) {
        var appSize: Int64 = 0
        var dataSize: Int64 = 0
        var groupSize: Int64 = 0

        if let bundleURL = app.bundleURL {
            appSize = directorySize(at: bundleURL)
        }

        if let dataURL = app.dataContainerURL {
            dataSize = directorySize(at: dataURL)
        }

        for (_, groupURL) in app.groupContainerURLs {
            groupSize += directorySize(at: groupURL)
        }

        return (appSize, dataSize, groupSize)
    }

    public func directorySize(at url: URL) -> Int64 {
        var size: Int64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return 0
        }

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)) else { continue }
            size += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
        }

        return size
    }

    // MARK: - Reflection Helpers
    private func stringProperty(_ object: NSObject, selectorName: String) -> String? {
        let selector = Selector((selectorName))
        guard object.responds(to: selector),
              let result = object.perform(selector)?.takeUnretainedValue() as? String else {
            return nil
        }
        return result
    }

    private func urlProperty(_ object: NSObject, selectorName: String) -> URL? {
        let selector = Selector((selectorName))
        guard object.responds(to: selector),
              let result = object.perform(selector)?.takeUnretainedValue() as? URL else {
            return nil
        }
        return result
    }

    private func groupContainersProperty(_ object: NSObject) -> [String: URL] {
        let selector = Selector(("groupContainerURLs"))
        guard object.responds(to: selector),
              let dict = object.perform(selector)?.takeUnretainedValue() as? [String: URL] else {
            return [:]
        }
        return dict
    }
}
