import Foundation
import UIKit

public final class AppDiscoveryService {
    public static let shared = AppDiscoveryService()

    private let fileManager = FileManager.default

    private init() {}

    // MARK: - Enumerate Installed Applications
    public func fetchInstalledApps() -> [InstalledApp] {
        // Pre-scan filesystem container maps to resolve missing URLs for third-party apps like WhatsApp
        let containerMaps = buildContainerMaps()

        // 1. Fetch apps from LSApplicationWorkspace
        var apps = fetchViaLSApplicationWorkspace(containerMaps: containerMaps)

        // 2. Discover apps directly from filesystem that might be missing from workspace
        let fsApps = scanFilesystemForApps(containerMaps: containerMaps)

        // Merge: add any filesystem app not already present in workspace results
        let existingIDs = Set(apps.map { $0.bundleIdentifier })
        for fsApp in fsApps {
            if !existingIDs.contains(fsApp.bundleIdentifier) {
                apps.append(fsApp)
            }
        }

        // Sort alphabetically by display name
        return apps.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Container Mapping from Filesystem Metadata
    private struct ContainerMaps {
        var dataContainers: [String: URL] = [:]       // BundleID -> Data Container URL
        var bundleContainers: [String: URL] = [:]     // BundleID -> .app Bundle URL
        var groupContainers: [String: URL] = [:]      // GroupID -> AppGroup Container URL
    }

    private func buildContainerMaps() -> ContainerMaps {
        var maps = ContainerMaps()

        // 1. Data Containers: /var/mobile/Containers/Data/Application/<UUID>
        let dataRoot = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application")
        if let dataUUIDs = try? fileManager.contentsOfDirectory(at: dataRoot, includingPropertiesForKeys: nil) {
            for dir in dataUUIDs {
                let meta = dir.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
                if let data = try? Data(contentsOf: meta),
                   let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                   let identifier = dict["MCMMetadataIdentifier"] as? String {
                    maps.dataContainers[identifier] = dir
                }
            }
        }

        // 2. Bundle Containers: /var/containers/Bundle/Application/<UUID>/<AppName>.app
        let bundleRoot = URL(fileURLWithPath: "/var/containers/Bundle/Application")
        if let bundleUUIDs = try? fileManager.contentsOfDirectory(at: bundleRoot, includingPropertiesForKeys: nil) {
            for dir in bundleUUIDs {
                guard let contents = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
                if let appBundle = contents.first(where: { $0.pathExtension == "app" }) {
                    let meta = dir.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
                    if let data = try? Data(contentsOf: meta),
                       let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                       let identifier = dict["MCMMetadataIdentifier"] as? String {
                        maps.bundleContainers[identifier] = appBundle
                    } else {
                        // Fallback: parse Info.plist inside the .app bundle
                        let infoPlist = appBundle.appendingPathComponent("Info.plist")
                        if let pData = try? Data(contentsOf: infoPlist),
                           let pDict = try? PropertyListSerialization.propertyList(from: pData, format: nil) as? [String: Any],
                           let bId = pDict["CFBundleIdentifier"] as? String {
                            maps.bundleContainers[bId] = appBundle
                        }
                    }
                }
            }
        }

        // 3. Shared App Groups: /var/mobile/Containers/Shared/AppGroup/<UUID>
        let groupRoot = URL(fileURLWithPath: "/var/mobile/Containers/Shared/AppGroup")
        if let groupUUIDs = try? fileManager.contentsOfDirectory(at: groupRoot, includingPropertiesForKeys: nil) {
            for dir in groupUUIDs {
                let meta = dir.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
                if let data = try? Data(contentsOf: meta),
                   let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                   let identifier = dict["MCMMetadataIdentifier"] as? String {
                    maps.groupContainers[identifier] = dir
                }
            }
        }

        return maps
    }

    // MARK: - Primary: LSApplicationWorkspace
    private func fetchViaLSApplicationWorkspace(containerMaps: ContainerMaps) -> [InstalledApp] {
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
            // Bundle Identifier: Prefer pure bundleIdentifier over applicationIdentifier (which may include team ID prefix)
            var bundleID = stringProperty(proxy, selectorName: "bundleIdentifier") ??
                           stringProperty(proxy, selectorName: "applicationIdentifier") ?? ""

            // Strip 10-char team prefix if present (e.g. "5A44372955.net.whatsapp.WhatsApp" -> "net.whatsapp.WhatsApp")
            if let dotIndex = bundleID.firstIndex(of: ".") {
                let prefix = String(bundleID[..<dotIndex])
                if prefix.count == 10 && prefix.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) == nil {
                    let cleaned = String(bundleID[bundleID.index(after: dotIndex)...])
                    if !cleaned.isEmpty {
                        bundleID = cleaned
                    }
                }
            }

            guard !bundleID.isEmpty else { continue }

            // Exclude our own app from backup list to avoid recursive self-backup
            if bundleID == Bundle.main.bundleIdentifier || bundleID == "dev.moe.appvault" {
                continue
            }

            // Display Name
            let displayName = stringProperty(proxy, selectorName: "localizedName") ??
                              stringProperty(proxy, selectorName: "itemName") ??
                              bundleID

            // Versions
            let shortVersion = stringProperty(proxy, selectorName: "shortVersionString") ?? "1.0"
            let buildVersion = stringProperty(proxy, selectorName: "bundleVersion") ?? "1"

            // URLs with filesystem metadata fallback
            let bundleURL = urlProperty(proxy, selectorName: "bundleURL") ?? containerMaps.bundleContainers[bundleID]
            let dataContainerURL = urlProperty(proxy, selectorName: "dataContainerURL") ?? containerMaps.dataContainers[bundleID]

            // Group Containers: merge workspace groups with filesystem groupContainers matching app bundleID
            var groupContainerURLs = groupContainersProperty(proxy)
            if groupContainerURLs.isEmpty {
                for (groupID, gURL) in containerMaps.groupContainers {
                    // Match groups like "group.net.whatsapp.WhatsApp.shared" to "net.whatsapp.WhatsApp"
                    if groupID.contains(bundleID) || bundleID.contains(groupID.replacingOccurrences(of: "group.", with: "")) {
                        groupContainerURLs[groupID] = gURL
                    }
                }
            }

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

    // MARK: - Fallback / Supplementary Filesystem Scanner
    private func scanFilesystemForApps(containerMaps: ContainerMaps) -> [InstalledApp] {
        var results: [String: InstalledApp] = [:]

        // Scan Bundle Applications
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
                if bundleID == Bundle.main.bundleIdentifier || bundleID == "dev.moe.appvault" {
                    continue
                }

                let appName = (plist["CFBundleDisplayName"] as? String) ??
                              (plist["CFBundleName"] as? String) ??
                              appBundle.deletingPathExtension().lastPathComponent
                let version = (plist["CFBundleShortVersionString"] as? String) ?? "1.0"
                let build = (plist["CFBundleVersion"] as? String) ?? "1"

                let dataURL = containerMaps.dataContainers[bundleID]

                var groups: [String: URL] = [:]
                for (groupID, gURL) in containerMaps.groupContainers {
                    if groupID.contains(bundleID) || bundleID.contains(groupID.replacingOccurrences(of: "group.", with: "")) {
                        groups[groupID] = gURL
                    }
                }

                results[bundleID] = InstalledApp(
                    bundleIdentifier: bundleID,
                    name: appName,
                    version: version,
                    build: build,
                    bundleURL: appBundle,
                    dataContainerURL: dataURL,
                    groupContainerURLs: groups,
                    isSystemApp: false
                )
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
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return 0
        }

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)) else { continue }
            // Only count regular files to avoid blocking on sockets or FIFOs
            if values.isRegularFile == true {
                size += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
            }
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
