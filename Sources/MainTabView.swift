import SwiftUI

public struct MainTabView: View {
    @StateObject private var appsVM = AppsViewModel()
    @StateObject private var backupsVM = BackupsViewModel()
    @StateObject private var settingsVM = SettingsViewModel()

    public init() {}

    public var body: some View {
        TabView {
            AppsListView()
                .environmentObject(appsVM)
                .environmentObject(backupsVM)
                .tabItem {
                    Label("Applications", systemImage: "square.grid.2x2.fill")
                }

            BackupsListView()
                .environmentObject(backupsVM)
                .tabItem {
                    Label("Backups", systemImage: "archivebox.fill")
                }
                .badge(backupsVM.backups.count)

            SettingsView()
                .environmentObject(settingsVM)
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
        .accentColor(.blue)
    }
}
