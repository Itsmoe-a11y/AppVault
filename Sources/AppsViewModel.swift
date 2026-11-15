import Foundation
import SwiftUI
import Combine

@MainActor
public final class AppsViewModel: ObservableObject {
    @Published public var apps: [InstalledApp] = []
    @Published public var searchQuery: String = ""
    @Published public var showSystemApps: Bool = false
    @Published public var isScanning: Bool = false
    @Published public var backupTargetApp: InstalledApp? = nil
    @Published public var exploreTargetApp: InstalledApp? = nil

    // Batch Multi-Selection Mode
    @Published public var isSelectionMode: Bool = false
    @Published public var selectedAppIDs: Set<String> = []
    @Published public var showBatchBackupSheet: Bool = false

    private var cancellables = Set<AnyCancellable>()

    public init() {
        refreshApps()
    }

    public var filteredApps: [InstalledApp] {
        apps.filter { app in
            let matchesScope = showSystemApps ? true : !app.isSystemApp
            guard matchesScope else { return false }

            if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }

            let q = searchQuery.lowercased()
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
        isScanning = true
        Task.detached(priority: .userInitiated) {
            let discovered = AppDiscoveryService.shared.fetchInstalledApps()
            await MainActor.run {
                self.apps = discovered
                self.isScanning = false
            }

            for app in discovered {
                let sizes = AppDiscoveryService.shared.calculateAppSizes(for: app)
                await MainActor.run {
                    if let index = self.apps.firstIndex(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
                        self.apps[index].appSizeBytes = sizes.appSize
                        self.apps[index].dataSizeBytes = sizes.dataSize
                        self.apps[index].groupSizeBytes = sizes.groupSize
                    }
                }
            }
        }
    }
}
