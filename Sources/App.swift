import SwiftUI

@main
public struct AppVaultApp: App {
    public init() {
        configureEnvironment()
    }

    public var body: some Scene {
        WindowGroup {
            MainTabView()
        }
    }

    private func configureEnvironment() {
        // Ensure backups directory exists
        _ = BackupEngine.shared.backupsDirectory

        // Fix permissions of backups directory
        PosixHelper.shared.fixPermissions(at: BackupEngine.shared.backupsDirectory.path)
    }
}
