import Foundation
import UIKit
import Darwin

public final class AppDiscoveryService {
    public static let shared = AppDiscoveryService()

    private let fileManager = FileManager.default

    // MARK: - Thread-safe Container Maps Cache
    private var cachedContainerMaps: ContainerMaps?
    private var containerMapsCacheDate: Date?
    private let cacheLock = NSLock()
    private let cacheTTL: TimeInterval = 60.0 // 60 seconds cache TTL

    private init() {}

    public func invalidateCache() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cachedContainerMaps = nil
        containerMapsCacheDate = nil
    }

    private func getContainerMaps(forceRefresh: Bool = false) -> ContainerMaps {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        if !forceRefresh,
           let cached = cachedContainerMaps,
           let cacheDate = containerMapsCacheDate,
           Date().timeIntervalSince(cacheDate) < cacheTTL {
            return cached
        }

        let maps = buildContainerMaps()
        cachedContainerMaps = maps
        containerMapsCacheDate = Date()
        return maps
    }

    // MARK: - Enumerate Installed Applications
    public func fetchInstalledApps(forceRefresh: Bool = false) -> [InstalledApp] {
        let containerMaps = getContainerMaps(forceRefresh: forceRefresh)

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
                    maps.dataContainers[identifier.lowercased()] = dir
                    let clean = cleanIdentifier(identifier)
                    maps.dataContainers[clean] = dir
                    maps.dataContainers[clean.lowercased()] = dir
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
                        maps.bundleContainers[identifier.lowercased()] = appBundle
                        let clean = cleanIdentifier(identifier)
                        maps.bundleContainers[clean] = appBundle
                        maps.bundleContainers[clean.lowercased()] = appBundle
                    } else {
                        // Fallback: parse Info.plist inside the .app bundle
                        let infoPlist = appBundle.appendingPathComponent("Info.plist")
                        if let pData = try? Data(contentsOf: infoPlist),
                           let pDict = try? PropertyListSerialization.propertyList(from: pData, format: nil) as? [String: Any],
                           let bId = pDict["CFBundleIdentifier"] as? String {
                            maps.bundleContainers[bId] = appBundle
                            maps.bundleContainers[bId.lowercased()] = appBundle
                            let clean = cleanIdentifier(bId)
                            maps.bundleContainers[clean] = appBundle
                            maps.bundleContainers[clean.lowercased()] = appBundle
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
                    maps.groupContainers[identifier.lowercased()] = dir
                    let clean = cleanIdentifier(identifier)
                    maps.groupContainers[clean] = dir
                    maps.groupContainers[clean.lowercased()] = dir
                }
            }
        }

        return maps
    }

    // MARK: - App Group Matching Helpers
    private func cleanIdentifier(_ identifier: String) -> String {
        var cleaned = identifier.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip "group." if at the beginning
        if cleaned.lowercased().hasPrefix("group.") {
            cleaned = String(cleaned.dropFirst(6))
        }

        // Strip 10-character alphanumeric Team ID prefix (e.g. "5A44372955.")
        if let dotIndex = cleaned.firstIndex(of: ".") {
            let prefix = String(cleaned[..<dotIndex])
            if prefix.count == 10 && prefix.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) == nil {
                cleaned = String(cleaned[cleaned.index(after: dotIndex)...])
            }
        }

        // Check if "group." was placed after Team ID: e.g. "5A44372955.group.net.whatsapp"
        if cleaned.lowercased().hasPrefix("group.") {
            cleaned = String(cleaned.dropFirst(6))
        }

        return cleaned
    }

    private func matchesAppGroup(groupID: String, bundleID: String) -> Bool {
        let cleanGroup = cleanIdentifier(groupID).lowercased()
        let cleanBundle = cleanIdentifier(bundleID).lowercased()

        guard !cleanGroup.isEmpty && !cleanBundle.isEmpty else { return false }

        // 1. Exact match
        if cleanGroup == cleanBundle { return true }

        // 2. Group is sub-group of bundle: e.g. "net.whatsapp.whatsapp.shared" hasPrefix "net.whatsapp.whatsapp"
        if cleanGroup.hasPrefix(cleanBundle + ".") || cleanGroup.hasPrefix(cleanBundle + "_") {
            return true
        }

        // 3. Bundle hasPrefix group: e.g. cleanGroup is "net.whatsapp" and cleanBundle is "net.whatsapp.whatsapp"
        if cleanBundle.hasPrefix(cleanGroup + ".") {
            return true
        }

        // 4. Common root domain matching
        let groupParts = cleanGroup.components(separatedBy: ".")
        let bundleParts = cleanBundle.components(separatedBy: ".")
        if groupParts.count >= 2 && bundleParts.count >= 2 {
            let genericDomains = ["com", "net", "org", "io", "app", "dev", "co", "uk", "de"]
            if !genericDomains.contains(groupParts[0]) {
                if groupParts[0] == bundleParts[0] {
                    return true
                }
            } else if groupParts.count >= 3 && bundleParts.count >= 3 {
                // e.g. com.google.chrome vs com.google.common
                if groupParts[0] == bundleParts[0] && groupParts[1] == bundleParts[1] && groupParts[2] == bundleParts[2] {
                    return true
                }
            }
        }

        return false
    }

    private func extractAppGroupsFromProvisionOrEntitlements(data: Data) -> [String] {
        guard let content = String(data: data, encoding: .isoLatin1) else { return [] }

        guard let plistStart = content.range(of: "<?xml"),
              let plistEnd = content.range(of: "</plist>", range: plistStart.lowerBound..<content.endIndex) else {
            return []
        }

        let plistXML = String(content[plistStart.lowerBound..<plistEnd.upperBound])
        guard let xmlData = plistXML.data(using: .utf8),
              let dict = (try? PropertyListSerialization.propertyList(from: xmlData, format: nil)) as? [String: Any] else {
            return []
        }

        // Check Entitlements dictionary
        if let entitlements = dict["Entitlements"] as? [String: Any],
           let groups = entitlements["com.apple.security.application-groups"] as? [String] {
            return groups
        }

        // Or direct key if this is an entitlements file
        if let groups = dict["com.apple.security.application-groups"] as? [String] {
            return groups
        }

        return []
    }

    private func resolveGroupContainers(
        for bundleID: String,
        proxyGroups: [String: URL],
        bundleURL: URL?,
        containerMaps: ContainerMaps
    ) -> [String: URL] {
        var groups = proxyGroups

        // 1. Check App Entitlements if bundle is accessible
        if let bundle = bundleURL {
            for entitlementFile in ["embedded.mobileprovision", "archived-expanded-entitlements.xcent"] {
                let fileURL = bundle.appendingPathComponent(entitlementFile)
                if let data = try? Data(contentsOf: fileURL) {
                    let groupIDs = extractAppGroupsFromProvisionOrEntitlements(data: data)
                    for gid in groupIDs {
                        if let gURL = containerMaps.groupContainers[gid] ??
                                      containerMaps.groupContainers[gid.lowercased()] ??
                                      containerMaps.groupContainers[cleanIdentifier(gid).lowercased()] {
                            groups[gid] = gURL
                        }
                    }
                }
            }
        }

        // 2. Match any filesystem groupContainers that match this app's bundleID
        for (groupID, gURL) in containerMaps.groupContainers {
            if groups[groupID] == nil && matchesAppGroup(groupID: groupID, bundleID: bundleID) {
                groups[groupID] = gURL
            }
        }

        return groups
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

            // Strip 10-char team prefix if present
            bundleID = cleanIdentifier(bundleID)

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

            // URLs with filesystem metadata fallback (case-insensitive & clean bundleID support)
            let bundleURL = urlProperty(proxy, selectorName: "bundleURL") ??
                            containerMaps.bundleContainers[bundleID] ??
                            containerMaps.bundleContainers[bundleID.lowercased()] ??
                            containerMaps.bundleContainers[cleanIdentifier(bundleID).lowercased()]

            let dataContainerURL = urlProperty(proxy, selectorName: "dataContainerURL") ??
                                   containerMaps.dataContainers[bundleID] ??
                                   containerMaps.dataContainers[bundleID.lowercased()] ??
                                   containerMaps.dataContainers[cleanIdentifier(bundleID).lowercased()]

            // Group Containers: merge workspace groups with filesystem groupContainers matching app bundleID
            let initialGroups = groupContainersProperty(proxy)
            let groupContainerURLs = resolveGroupContainers(
                for: bundleID,
                proxyGroups: initialGroups,
                bundleURL: bundleURL,
                containerMaps: containerMaps
            )

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

                guard let rawBundleID = plist["CFBundleIdentifier"] as? String else { continue }
                let bundleID = cleanIdentifier(rawBundleID)
                if bundleID == Bundle.main.bundleIdentifier || bundleID == "dev.moe.appvault" {
                    continue
                }

                let appName = (plist["CFBundleDisplayName"] as? String) ??
                              (plist["CFBundleName"] as? String) ??
                              appBundle.deletingPathExtension().lastPathComponent
                let version = (plist["CFBundleShortVersionString"] as? String) ?? "1.0"
                let build = (plist["CFBundleVersion"] as? String) ?? "1"

                let dataURL = containerMaps.dataContainers[bundleID]

                let groups = resolveGroupContainers(
                    for: bundleID,
                    proxyGroups: [:],
                    bundleURL: appBundle,
                    containerMaps: containerMaps
                )

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
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return 0
        }

        for case let fileURL as URL in enumerator {
            var st = stat()
            // Use lstat to avoid following symlinks into loops or opening sockets/FIFOs
            guard lstat(fileURL.path, &st) == 0 else { continue }
            let fileType = st.st_mode & S_IFMT

            if fileType == S_IFREG {
                size += Int64(st.st_size)
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
