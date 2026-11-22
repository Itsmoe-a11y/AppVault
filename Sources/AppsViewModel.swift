import Foundation
import SwiftUI
import Combine

public enum AppListSheet: Identifiable {
    case backup(InstalledApp)
    case explore(InstalledApp)
    case batchBackup([InstalledApp])

    public var id: String {
        switch self {
        case .backup(let a): return "backup_\(a.bundleIdentifier)"
        case .explore(let a): return "explore_\(a.bundleIdentifier)"
        case .batchBackup(let arr): return "batch_\(arr.map { $0.bundleIdentifier }.joined(separator: "_"))"
        }
    }
}

@MainActor
public final class AppsViewModel: ObservableObject {
    @Published public var apps: [InstalledApp] = []
    @Published public var searchQuery: String = ""
    @Published public var showSystemApps: Bool = false
    @Published public var isScanning: Bool = false

    // Unified Sheet Presentation to avoid iOS 15 multi-sheet collisions
    @Published public var activeSheet: AppListSheet? = nil

    // Batch Multi-Selection Mode
    @Published public var isSelectionMode: Bool = false
    @Published public var selectedAppIDs: Set<String> = []

    // Backwards compatibility properties
    public var backupTargetApp: InstalledApp? {
        get {
            if case .backup(let app) = activeSheet { return app }
            return nil
        }
        set {
            if let val = newValue {
                activeSheet = .backup(val)
            } else if case .backup = activeSheet {
                activeSheet = nil
            }
        }
    }

    public var exploreTargetApp: InstalledApp? {
        get {
            if case .explore(let app) = activeSheet { return app }
            return nil
        }
        set {
            if let val = newValue {
                activeSheet = .explore(val)
            } else if case .explore = activeSheet {
                activeSheet = nil
            }
        }
    }

    public var showBatchBackupSheet: Bool {
        get {
            if case .batchBackup = activeSheet { return true }
            return false
        }
        set {
            if newValue {
                activeSheet = .batchBackup(selectedApps)
            } else if case .batchBackup = activeSheet {
                activeSheet = nil
            }
        }
    }

    private var scanTask: Task<Void, Never>? = nil

    public init() {
        refreshApps()
    }

    deinit {
        scanTask?.cancel()
    }

    public var filteredApps: [InstalledApp] {
        apps.filter { app in
            let matchesScope = showSystemApps ? true : !app.isSystemApp
            guard matchesScope else { return false }

            let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return true
            }

            let q = trimmed.lowercased()
            return app.name.lowercased().contains(q) ||
                   app.bundleIdentifier.lowercased().contains(q)
        }
    }

    public var selectedApps: [InstalledApp] {
        apps.filter { selectedAppIDs.contains($0.bundleIdentifier) }
    }

    public func toggleSelection(for app: InstalledApp) {
        if selectedAppIDs.contains(app.bundleIdentifier) {
            selectedAppIDs.remove(app.bundleIdentifier)
        } else {
            selectedAppIDs.insert(app.bundleIdentifier)
        }
    }

    public func selectAll() {
        selectedAppIDs = Set(filteredApps.map { $0.bundleIdentifier })
    }

    public func clearSelection() {
        selectedAppIDs.removeAll()
    }

    public func refreshApps() {
        scanTask?.cancel()
        isScanning = true

        scanTask = Task.detached(priority: .userInitiated) {
            let discovered: [InstalledApp] = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: AppDiscoveryService.shared.fetchInstalledApps())
                }
            }
            guard !Task.isCancelled else {
                await MainActor.run { self.isScanning = false }
                return
            }

            await MainActor.run {
                self.apps = discovered
                // If there are no discovered apps, end scan state immediately
                if discovered.isEmpty {
                    self.isScanning = false
                }
            }

            guard !discovered.isEmpty else { return }

            var currentApps = discovered

            // Prioritize User Applications first (currently visible on screen)
            let userIndices = currentApps.indices.filter { !currentApps[$0].isSystemApp && !currentApps[$0].isSized }
            let sysIndices = currentApps.indices.filter { currentApps[$0].isSystemApp && !currentApps[$0].isSized }
            let orderedIndices = userIndices + sysIndices

            guard !orderedIndices.isEmpty else {
                await MainActor.run { self.isScanning = false }
                return
            }

            // Offload synchronous POSIX directory sizing onto a dedicated utility GCD queue
            // so we NEVER starve Swift's cooperative thread pool (which previously froze streaming backups on "Initializing")
            let sizingQueue = DispatchQueue(label: "dev.moe.appvault.sizing", qos: .utility, attributes: .concurrent)
            let maxWorkers = 2
            var nextToSubmit = 0

            func sizeOnUtilityQueue(_ targetApp: InstalledApp) async -> (Int64, Int64, Int64) {
                await withCheckedContinuation { continuation in
                    sizingQueue.async {
                        let sizes = AppDiscoveryService.shared.calculateAppSizes(for: targetApp)
                        continuation.resume(returning: (sizes.appSize, sizes.dataSize, sizes.groupSize))
                    }
                }
            }

            await withTaskGroup(of: (Int, Int64, Int64, Int64).self) { group in
                // Initial worker window
                while nextToSubmit < orderedIndices.count && nextToSubmit < maxWorkers {
                    let idx = orderedIndices[nextToSubmit]
                    let app = currentApps[idx]
                    group.addTask {
                        let sizes = await sizeOnUtilityQueue(app)
                        return (idx, sizes.0, sizes.1, sizes.2)
                    }
                    nextToSubmit += 1
                }

                var lastUIUpdateTime = Date()
                var completedBatchCount = 0

                // As soon as ANY single worker finishes: update that app and submit the next unsized app!
                for await (idx, appSize, dataSize, groupSize) in group {
                    guard !Task.isCancelled else { break }

                    currentApps[idx].appSizeBytes = appSize
                    currentApps[idx].dataSizeBytes = dataSize
                    currentApps[idx].groupSizeBytes = groupSize
                    currentApps[idx].isSized = true
                    completedBatchCount += 1

                    if nextToSubmit < orderedIndices.count {
                        let nextIdx = orderedIndices[nextToSubmit]
                        let nextApp = currentApps[nextIdx]
                        group.addTask {
                            let sizes = await sizeOnUtilityQueue(nextApp)
                            return (nextIdx, sizes.0, sizes.1, sizes.2)
                        }
                        nextToSubmit += 1
                    }

                    // Smooth UI streaming: push updates every 3 completed apps or every 0.25s
                    let now = Date()
                    if completedBatchCount >= 3 || now.timeIntervalSince(lastUIUpdateTime) >= 0.25 || nextToSubmit == orderedIndices.count {
                        let snapshot = currentApps
                        await MainActor.run {
                            self.apps = snapshot
                        }
                        lastUIUpdateTime = now
                        completedBatchCount = 0
                    }
                }
            }

            // Final persistent disk commit and state completion
            AppDiscoveryService.shared.flushSizeCacheToDisk()
            await MainActor.run {
                self.apps = currentApps
                self.isScanning = false
            }
        }
    }
}
