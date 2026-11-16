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
            let discovered = AppDiscoveryService.shared.fetchInstalledApps()
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

            // High performance bounded concurrent sizing (4 workers)
            let batchSize = 4
            var index = 0
            while index < orderedIndices.count {
                guard !Task.isCancelled else { break }
                let chunkEnd = min(index + batchSize, orderedIndices.count)
                let chunk = Array(orderedIndices[index..<chunkEnd])

                await withTaskGroup(of: (Int, Int64, Int64, Int64).self) { group in
                    for idx in chunk {
                        let app = currentApps[idx]
                        group.addTask {
                            let sizes = AppDiscoveryService.shared.calculateAppSizes(for: app)
                            return (idx, sizes.appSize, sizes.dataSize, sizes.groupSize)
                        }
                    }

                    for await (idx, appSize, dataSize, groupSize) in group {
                        currentApps[idx].appSizeBytes = appSize
                        currentApps[idx].dataSizeBytes = dataSize
                        currentApps[idx].groupSizeBytes = groupSize
                        currentApps[idx].isSized = true
                    }
                }

                index = chunkEnd
                let snapshot = currentApps
                await MainActor.run {
                    self.apps = snapshot
                }
            }

            await MainActor.run {
                self.apps = currentApps
                self.isScanning = false
            }
        }
    }
}
