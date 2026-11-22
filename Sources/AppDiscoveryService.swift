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

    // MARK: - Thread-safe App Size Cache
    private struct AppSizeCacheEntry: Codable {
        let appSize: Int64
        let dataSize: Int64
        let groupSize: Int64
        let timestamp: Date
    }

    private var appSizeCache: [String: AppSizeCacheEntry] = [:]
    private var groupPathSizeCache: [String: (size: Int64, timestamp: Date)] = [:]
    private let sizeCacheLock = NSLock()
    private let sizeCacheTTL: TimeInterval = 1800.0 // 30 minutes cache TTL
    private let groupPathCacheTTL: TimeInterval = 300.0 // 5 minutes shared AppGroup path cache

    private init() {
        if let data = UserDefaults.standard.data(forKey: "appvault_size_cache_v1"),
           let decoded = try? JSONDecoder().decode([String: AppSizeCacheEntry].self, from: data) {
            self.appSizeCache = decoded
        }
    }

    private var lastDiskSaveTime = Date.distantPast
    private func saveSizeCacheToDisk(force: Bool = false) {
        let now = Date()
        if !force && now.timeIntervalSince(lastDiskSaveTime) < 2.0 {
            return
        }
        lastDiskSaveTime = now
        if let data = try? JSONEncoder().encode(appSizeCache) {
            UserDefaults.standard.set(data, forKey: "appvault_size_cache_v1")
        }
    }

    public func flushSizeCacheToDisk() {
        sizeCacheLock.lock()
        defer { sizeCacheLock.unlock() }
        saveSizeCacheToDisk(force: true)
    }

    public func invalidateCache() {
        cacheLock.lock()
        cachedContainerMaps = nil
        containerMapsCacheDate = nil
        cacheLock.unlock()

        invalidateSizeCache()
    }

    public func getCachedAppSizes(for bundleID: String) -> (appSize: Int64, dataSize: Int64, groupSize: Int64)? {
        sizeCacheLock.lock()
        defer { sizeCacheLock.unlock() }
        guard let cached = appSizeCache[bundleID],
              Date().timeIntervalSince(cached.timestamp) < sizeCacheTTL else {
            return nil
        }
        // Do not return as valid cache if all values are 0 (e.g. before initial scan completed)
        if cached.appSize == 0 && cached.dataSize == 0 && cached.groupSize == 0 {
            return nil
        }
        return (cached.appSize, cached.dataSize, cached.groupSize)
    }

    public func invalidateSizeCache(for bundleID: String? = nil) {
        sizeCacheLock.lock()
        defer { sizeCacheLock.unlock() }
        if let bID = bundleID {
            appSizeCache.removeValue(forKey: bID)
        } else {
            appSizeCache.removeAll()
            groupPathSizeCache.removeAll()
        }
        saveSizeCacheToDisk()
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
        let dataRoots = [
            URL(fileURLWithPath: "/var/mobile/Containers/Data/Application"),
            URL(fileURLWithPath: "/var/mobile/Containers/Data/Internal/Application"),
            URL(fileURLWithPath: "/var/mobile/Containers/Data/System")
        ]
        for dataRoot in dataRoots {
            if let dataUUIDs = try? fileManager.contentsOfDirectory(at: dataRoot, includingPropertiesForKeys: nil) {
                for dir in dataUUIDs {
                    let meta = dir.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
                    if let data = try? Data(contentsOf: meta),
                       let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                        let identifier = (dict["MCMMetadataIdentifier"] as? String) ??
                                         (dict["MCMMetadataBundleID"] as? String) ??
                                         (dict["CFBundleIdentifier"] as? String)
                        if let identifier = identifier {
                            maps.dataContainers[identifier] = dir
                            maps.dataContainers[identifier.lowercased()] = dir
                            let clean = cleanIdentifier(identifier)
                            maps.dataContainers[clean] = dir
                            maps.dataContainers[clean.lowercased()] = dir
                        }
                    } else {
                        let containerPlist = dir.appendingPathComponent("Container.plist")
                        if let cData = try? Data(contentsOf: containerPlist),
                           let cDict = try? PropertyListSerialization.propertyList(from: cData, format: nil) as? [String: Any],
                           let cId = (cDict["MCMMetadataIdentifier"] as? String) ?? (cDict["CFBundleIdentifier"] as? String) {
                            maps.dataContainers[cId] = dir
                            maps.dataContainers[cId.lowercased()] = dir
                        }
                    }
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
                       let identifier = (dict["MCMMetadataIdentifier"] as? String) ??
                                        (dict["MCMMetadataBundleID"] as? String) ??
                                        (dict["CFBundleIdentifier"] as? String) {
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
                   let identifier = (dict["MCMMetadataIdentifier"] as? String) ??
                                    (dict["MCMMetadataBundleID"] as? String) ??
                                    (dict["CFBundleIdentifier"] as? String) {
                    maps.groupContainers[identifier] = dir
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

        // 2. Group is sub-group of bundle or contains bundle
        if cleanGroup.hasPrefix(cleanBundle + ".") || cleanGroup.hasPrefix(cleanBundle + "_") || cleanGroup.contains(cleanBundle) {
            return true
        }

        // 3. Bundle hasPrefix group or contains group
        if cleanBundle.hasPrefix(cleanGroup + ".") || cleanBundle.contains(cleanGroup) {
            return true
        }

        // 4. Strict 3-segment app-specific match (avoids merging unrelated apps like com.google.Gmail & com.google.Chrome)
        let groupParts = cleanGroup.components(separatedBy: ".")
        let bundleParts = cleanBundle.components(separatedBy: ".")
        if groupParts.count >= 3 && bundleParts.count >= 3 {
            if groupParts[0] == bundleParts[0] &&
               groupParts[1] == bundleParts[1] &&
               groupParts[2] == bundleParts[2] {
                return true
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
                                      containerMaps.groupContainers[cleanIdentifier(gid)] {
                            groups[gid] = gURL
                        }
                    }
                }
            }
        }

        // 2. Match any filesystem groupContainers that match this app's bundleID (deduplicated by directory path)
        var existingPaths = Set(groups.values.map { $0.standardized.path })
        for (groupID, gURL) in containerMaps.groupContainers {
            let path = gURL.standardized.path
            if !existingPaths.contains(path) && matchesAppGroup(groupID: groupID, bundleID: bundleID) {
                groups[groupID] = gURL
                existingPaths.insert(path)
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
            var bundleURL = urlProperty(proxy, selectorName: "bundleURL") ??
                            containerMaps.bundleContainers[bundleID] ??
                            containerMaps.bundleContainers[bundleID.lowercased()] ??
                            containerMaps.bundleContainers[cleanIdentifier(bundleID).lowercased()]
            if bundleURL == nil, let bCont = urlProperty(proxy, selectorName: "bundleContainerURL") {
                if let subs = try? fileManager.contentsOfDirectory(at: bCont, includingPropertiesForKeys: nil),
                   let appDir = subs.first(where: { $0.pathExtension == "app" }) {
                    bundleURL = appDir
                }
            }

            let dataContainerURL = urlProperty(proxy, selectorName: "dataContainerURL") ??
                                   urlProperty(proxy, selectorName: "containerURL") ??
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

            let cachedSizes = getCachedAppSizes(for: bundleID)
            let app = InstalledApp(
                bundleIdentifier: bundleID,
                name: displayName,
                version: shortVersion,
                build: buildVersion,
                bundleURL: bundleURL,
                dataContainerURL: dataContainerURL,
                groupContainerURLs: groupContainerURLs,
                isSystemApp: isSystem,
                appSizeBytes: cachedSizes?.appSize ?? 0,
                dataSizeBytes: cachedSizes?.dataSize ?? 0,
                groupSizeBytes: cachedSizes?.groupSize ?? 0,
                isSized: cachedSizes != nil
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

                let dataURL = containerMaps.dataContainers[bundleID] ?? containerMaps.dataContainers[bundleID.lowercased()]

                let groups = resolveGroupContainers(
                    for: bundleID,
                    proxyGroups: [:],
                    bundleURL: appBundle,
                    containerMaps: containerMaps
                )

                let cachedSizes = getCachedAppSizes(for: bundleID)
                results[bundleID] = InstalledApp(
                    bundleIdentifier: bundleID,
                    name: appName,
                    version: version,
                    build: build,
                    bundleURL: appBundle,
                    dataContainerURL: dataURL,
                    groupContainerURLs: groups,
                    isSystemApp: false,
                    appSizeBytes: cachedSizes?.appSize ?? 0,
                    dataSizeBytes: cachedSizes?.dataSize ?? 0,
                    groupSizeBytes: cachedSizes?.groupSize ?? 0,
                    isSized: cachedSizes != nil
                )
            }
        }

        return Array(results.values)
    }

    // MARK: - Disk Size Calculations
    public func calculateAppSizes(
        for app: InstalledApp,
        forceRefresh: Bool = false,
        shouldCancel: (() -> Bool)? = nil
    ) -> (appSize: Int64, dataSize: Int64, groupSize: Int64) {
        if !forceRefresh {
            sizeCacheLock.lock()
            if let cached = appSizeCache[app.bundleIdentifier],
               Date().timeIntervalSince(cached.timestamp) < sizeCacheTTL,
               (cached.appSize > 0 || cached.dataSize > 0 || cached.groupSize > 0) {
                sizeCacheLock.unlock()
                return (cached.appSize, cached.dataSize, cached.groupSize)
            }
            sizeCacheLock.unlock()
        }

        var appSize: Int64 = 0
        var dataSize: Int64 = 0
        var groupSize: Int64 = 0

        if let bundleURL = app.bundleURL {
            appSize = directorySize(atPath: bundleURL.path, shouldCancel: shouldCancel)
        }
        if shouldCancel?() == true { return (appSize, dataSize, groupSize) }

        if let dataURL = app.dataContainerURL {
            dataSize = directorySize(atPath: dataURL.path, shouldCancel: shouldCancel)
        }
        if shouldCancel?() == true { return (appSize, dataSize, groupSize) }

        // Deduplicate & cache shared AppGroup directories so multi-app groups are scanned only once
        let uniqueGroupPaths = Set(app.groupContainerURLs.values.map { $0.standardized.path })
        for groupPath in uniqueGroupPaths {
            if shouldCancel?() == true { return (appSize, dataSize, groupSize) }
            if !forceRefresh {
                sizeCacheLock.lock()
                if let cachedGroup = groupPathSizeCache[groupPath],
                   Date().timeIntervalSince(cachedGroup.timestamp) < groupPathCacheTTL {
                    sizeCacheLock.unlock()
                    groupSize += cachedGroup.size
                    continue
                }
                sizeCacheLock.unlock()
            }
            let measured = directorySize(atPath: groupPath, shouldCancel: shouldCancel)
            if shouldCancel?() == true { return (appSize, dataSize, groupSize) }
            sizeCacheLock.lock()
            groupPathSizeCache[groupPath] = (measured, Date())
            sizeCacheLock.unlock()
            groupSize += measured
        }

        if shouldCancel?() == true { return (appSize, dataSize, groupSize) }

        sizeCacheLock.lock()
        appSizeCache[app.bundleIdentifier] = AppSizeCacheEntry(
            appSize: appSize,
            dataSize: dataSize,
            groupSize: groupSize,
            timestamp: Date()
        )
        saveSizeCacheToDisk(force: false)
        sizeCacheLock.unlock()

        return (appSize, dataSize, groupSize)
    }

    public func directorySize(at url: URL) -> Int64 {
        return directorySize(atPath: url.path)
    }

    /// Ultra-fast pure POSIX directory size walker (opendir/readdir + fstatat).
    /// Avoids FileManager.default thread contention and per-file URL/Objective-C allocations (5-15x faster on APFS).
    public func directorySize(atPath path: String, shouldCancel: (() -> Bool)? = nil) -> Int64 {
        guard !path.isEmpty else { return 0 }

        var rootStat = stat()
        guard lstat(path, &rootStat) == 0 else { return 0 }
        let rootType = rootStat.st_mode & S_IFMT
        if rootType == S_IFREG {
            return Int64(rootStat.st_size)
        }
        guard rootType == S_IFDIR else { return 0 }

        var totalSize: Int64 = 0
        var dirStack: [String] = [path]
        var seenEntries = 0

        while let currentDir = dirStack.popLast() {
            if let cancelCheck = shouldCancel, cancelCheck() {
                break
            }
            guard let dir = opendir(currentDir) else { continue }
            let dfd = open(currentDir, O_RDONLY | O_DIRECTORY)

            while let entry = readdir(dir) {
                seenEntries += 1
                if (seenEntries & 2047) == 0 {
                    if let cancelCheck = shouldCancel, cancelCheck() {
                        break
                    }
                }

                let dType = Int(entry.pointee.d_type)
                if dType == Int(DT_LNK) {
                    continue
                }

                withUnsafePointer(to: &entry.pointee.d_name) { nameTuplePtr in
                    nameTuplePtr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) { cName in
                        // Fast-path skip "." (46, 0) and ".." (46, 46, 0) without String allocation
                        if cName[0] == 46 {
                            if cName[1] == 0 { return }
                            if cName[1] == 46 && cName[2] == 0 { return }
                        }

                        if dType == Int(DT_REG) {
                            var st = stat()
                            if dfd >= 0 {
                                if fstatat(dfd, cName, &st, AT_SYMLINK_NOFOLLOW) == 0 {
                                    totalSize += Int64(st.st_size)
                                }
                            } else {
                                let childPath = currentDir.hasSuffix("/") ? currentDir + String(cString: cName) : currentDir + "/" + String(cString: cName)
                                if lstat(childPath, &st) == 0 {
                                    totalSize += Int64(st.st_size)
                                }
                            }
                        } else if dType == Int(DT_DIR) {
                            let childName = String(cString: cName)
                            dirStack.append(currentDir.hasSuffix("/") ? currentDir + childName : currentDir + "/" + childName)
                        } else if dType == Int(DT_UNKNOWN) {
                            var st = stat()
                            let ok: Bool
                            if dfd >= 0 {
                                ok = (fstatat(dfd, cName, &st, AT_SYMLINK_NOFOLLOW) == 0)
                            } else {
                                let childPath = currentDir.hasSuffix("/") ? currentDir + String(cString: cName) : currentDir + "/" + String(cString: cName)
                                ok = (lstat(childPath, &st) == 0)
                            }
                            if ok {
                                let modeType = st.st_mode & S_IFMT
                                if modeType == S_IFREG {
                                    totalSize += Int64(st.st_size)
                                } else if modeType == S_IFDIR {
                                    let childName = String(cString: cName)
                                    dirStack.append(currentDir.hasSuffix("/") ? currentDir + childName : currentDir + "/" + childName)
                                }
                            }
                        }
                    }
                }
            }

            if dfd >= 0 {
                close(dfd)
            }
            closedir(dir)
        }

        return totalSize
    }

    // MARK: - Reflection Helpers
    private func stringProperty(_ object: NSObject, selectorName: String) -> String? {
        let selector = Selector((selectorName))
        guard object.responds(to: selector),
              let unmanaged = object.perform(selector) else {
            return nil
        }
        return unmanaged.takeUnretainedValue() as? String
    }

    private func urlProperty(_ object: NSObject, selectorName: String) -> URL? {
        let selector = Selector((selectorName))
        guard object.responds(to: selector),
              let unmanaged = object.perform(selector) else {
            return nil
        }
        let raw = unmanaged.takeUnretainedValue()
        if let url = raw as? URL {
            return url
        }
        if let str = raw as? String, !str.isEmpty {
            return URL(fileURLWithPath: str)
        }
        return nil
    }

    private func groupContainersProperty(_ object: NSObject) -> [String: URL] {
        let selector = Selector(("groupContainerURLs"))
        guard object.responds(to: selector),
              let unmanaged = object.perform(selector) else {
            return [:]
        }
        let raw = unmanaged.takeUnretainedValue()
        if let dict = raw as? [String: URL] {
            return dict
        }
        if let rawDict = raw as? [String: Any] {
            var result: [String: URL] = [:]
            for (k, v) in rawDict {
                if let u = v as? URL {
                    result[k] = u
                } else if let s = v as? String {
                    result[k] = URL(fileURLWithPath: s)
                }
            }
            return result
        }
        return [:]
    }
}
