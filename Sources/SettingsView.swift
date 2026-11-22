import SwiftUI

private enum SettingsActiveSheet: Identifiable {
    case googleGuide
    case rcloneConf

    var id: String {
        switch self {
        case .googleGuide: return "googleGuide"
        case .rcloneConf: return "rcloneConf"
        }
    }
}

public struct SettingsView: View {
    @EnvironmentObject var settingsVM: SettingsViewModel
    @ObservedObject var googleDrive = GoogleDriveService.shared
    @ObservedObject var webServer = LocalWebServer.shared
    @ObservedObject var webdav = WebDAVService.shared
    @ObservedObject var rclone = RcloneHelper.shared

    @State private var showAdvancedOAuth = false
    @State private var activeSheet: SettingsActiveSheet? = nil
    @State private var directTokenInput = ""
    @State private var isTestingWebDAV = false
    @State private var webdavTestStatus: String? = nil
    @State private var webdavTestSuccess = false
    @State private var isTestingGDrive = false
    @State private var gdriveTestStatus: String? = nil
    @State private var gdriveTestSuccess = false
    @State private var showDeviceFlowSection = false
    @State private var deviceFlowClientId = ""
    @State private var deviceFlowClientSecret = ""

    public init() {}

    private var appVersionLabel: String {
        let shortVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.2.0"
        let buildVer = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "15"
        return "\(shortVer) (Build \(buildVer))"
    }

    public var body: some View {
        NavigationView {
            Form {
                // Section 1: Local Wi-Fi Transfer Server (PIN-Protected)
                Section(header: Text("Local Wi-Fi Browser Transfer")) {
                    Toggle(isOn: Binding(
                        get: { webServer.isRunning },
                        set: { val in
                            if val { webServer.start() } else { webServer.stop() }
                        }
                    )) {
                        Label("Wi-Fi Web Dashboard", systemImage: "wifi")
                    }

                    if webServer.isRunning {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Open in any PC or phone browser on this Wi-Fi:")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(webServer.serverURLString)
                                .font(.system(size: 15, weight: .bold, design: .monospaced))
                                .foregroundColor(.blue)

                            HStack {
                                Label("Pairing PIN:", systemImage: "lock.shield.fill")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(webServer.accessPIN)
                                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                                    .foregroundColor(.green)
                                Spacer()
                                Button("New PIN") {
                                    webServer.regeneratePIN()
                                }
                                .buttonStyle(BorderlessButtonStyle())
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.12))
                                .foregroundColor(.blue)
                                .cornerRadius(6)
                            }
                            .padding(.top, 2)

                            Text("Protected with a 4-digit session PIN. Supports streaming large uploads and remote backup management.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }

                // Section 2: Google Drive Cloud Storage (1-Tap Sign In with Google)
                Section(header: Text("Google Drive Cloud Storage")) {
                    if googleDrive.isAuthenticated {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 24))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(googleDrive.userName.isEmpty ? "Connected" : googleDrive.userName)
                                    .font(.headline)
                                Text(googleDrive.userEmail)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label("Target Cloud Folder / Path", systemImage: "folder.badge.gearshape")
                                    .font(.subheadline)
                                Spacer()
                            }

                            TextField("e.g. AppVault Backups or Backups/iOS", text: $googleDrive.targetFolderName)
                                .font(.system(size: 13, design: .monospaced))
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .padding(8)
                                .background(Color(UIColor.secondarySystemBackground))
                                .cornerRadius(6)

                            Text("Any folder name or nested path. Folders are created automatically in your Google Drive if they don't exist.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)

                        Button(action: {
                            isTestingGDrive = true
                            gdriveTestStatus = nil
                            Task {
                                do {
                                    let msg = try await googleDrive.testDriveConnection()
                                    await MainActor.run {
                                        isTestingGDrive = false
                                        gdriveTestSuccess = true
                                        gdriveTestStatus = msg
                                    }
                                } catch {
                                    await MainActor.run {
                                        isTestingGDrive = false
                                        gdriveTestSuccess = false
                                        gdriveTestStatus = error.localizedDescription
                                    }
                                }
                            }
                        }) {
                            HStack {
                                if isTestingGDrive {
                                    ProgressView().scaleEffect(0.8)
                                    Text("Testing Google Drive Upload...")
                                } else {
                                    Label("Test Google Drive Upload", systemImage: "checkmark.icloud")
                                }
                            }
                        }
                        .disabled(isTestingGDrive)

                        if let status = gdriveTestStatus {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: gdriveTestSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundColor(gdriveTestSuccess ? .green : .red)
                                Text(status)
                                    .font(.caption)
                                    .foregroundColor(gdriveTestSuccess ? .green : .red)
                            }
                        }

                        Button(action: {
                            gdriveTestStatus = nil
                            googleDrive.signOut()
                        }) {
                            Text("Disconnect Google Drive")
                                .foregroundColor(.red)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Sign in with your Google email, password, and 2FA in Apple's secure Safari sheet to stream backups directly to Google Drive.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if let error = googleDrive.errorMessage {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.orange)
                                    Text(error)
                                        .font(.caption)
                                        .foregroundColor(.red)
                                    Spacer()
                                    Button(action: { googleDrive.errorMessage = nil }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(BorderlessButtonStyle())
                                }
                                .padding(8)
                                .background(Color.red.opacity(0.1))
                                .cornerRadius(8)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Target Cloud Folder / Path")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                TextField("e.g. AppVault Backups or Backups/iOS", text: $googleDrive.targetFolderName)
                                    .font(.system(size: 13, design: .monospaced))
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                                    .padding(8)
                                    .background(Color(UIColor.secondarySystemBackground))
                                    .cornerRadius(6)
                            }

                            Button(action: {
                                if googleDrive.canStartOneTapSignIn {
                                    googleDrive.signIn()
                                } else {
                                    activeSheet = .googleGuide
                                }
                            }) {
                                HStack {
                                    if googleDrive.isAuthenticating {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    } else {
                                        Image(systemName: "person.badge.key.fill")
                                    }
                                    Text(googleDrive.canStartOneTapSignIn ? "Sign In with Google" : "Configure Google Sign-In (2 min)")
                                }
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.blue)
                                .cornerRadius(8)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            .padding(.vertical, 2)

                            if googleDrive.canStartOneTapSignIn {
                                HStack(spacing: 8) {
                                    Button(action: {
                                        googleDrive.signIn(ephemeral: true)
                                    }) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "hand.raised.fill")
                                            Text("Private Sheet")
                                        }
                                        .font(.caption.weight(.semibold))
                                        .foregroundColor(.blue)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                        .background(Color.blue.opacity(0.1))
                                        .cornerRadius(8)
                                    }
                                    .buttonStyle(BorderlessButtonStyle())

                                    Button(action: {
                                        googleDrive.signInWithExternalBrowser()
                                    }) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "safari")
                                            Text("External Browser")
                                        }
                                        .font(.caption.weight(.semibold))
                                        .foregroundColor(.blue)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                        .background(Color.blue.opacity(0.1))
                                        .cornerRadius(8)
                                    }
                                    .buttonStyle(BorderlessButtonStyle())
                                }
                            }

                            DisclosureGroup("Jailbreak / Zero-WebKit Login (google.com/device)", isExpanded: $showDeviceFlowSection) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("If Google shows 'Something went wrong' on a jailbroken iOS 16 device, sign in on any PC or other phone using a Google 'TV & Limited Input' OAuth Client ID (no iOS WebKit used).")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)

                                    if let code = googleDrive.deviceUserCode, let urlStr = googleDrive.deviceVerificationURL {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text("1. Open \(urlStr) on any PC/phone browser")
                                                .font(.caption)
                                            HStack {
                                                Text(code)
                                                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                                                    .foregroundColor(.blue)
                                                Spacer()
                                                Button("Copy Code") {
                                                    UIPasteboard.general.string = code
                                                }
                                                .buttonStyle(BorderlessButtonStyle())
                                                .font(.caption)
                                            }
                                            HStack {
                                                ProgressView().scaleEffect(0.8)
                                                Text("Waiting for approval...")
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                                Spacer()
                                                Button("Cancel") {
                                                    googleDrive.cancelDeviceFlow()
                                                }
                                                .buttonStyle(BorderlessButtonStyle())
                                                .font(.caption)
                                                .foregroundColor(.red)
                                            }
                                        }
                                        .padding(8)
                                        .background(Color(UIColor.secondarySystemBackground))
                                        .cornerRadius(8)
                                    } else {
                                        TextField("TV/Device Client ID", text: $deviceFlowClientId)
                                            .font(.system(size: 12, design: .monospaced))
                                            .autocapitalization(.none)
                                            .disableAutocorrection(true)
                                            .padding(6)
                                            .background(Color(UIColor.secondarySystemBackground))
                                            .cornerRadius(6)

                                        SecureField("TV/Device Client Secret", text: $deviceFlowClientSecret)
                                            .font(.system(size: 12, design: .monospaced))
                                            .autocapitalization(.none)
                                            .disableAutocorrection(true)
                                            .padding(6)
                                            .background(Color(UIColor.secondarySystemBackground))
                                            .cornerRadius(6)

                                        Button("Generate Device Sign-In Code") {
                                            googleDrive.startDeviceFlow(
                                                deviceClientId: deviceFlowClientId,
                                                deviceClientSecret: deviceFlowClientSecret
                                            )
                                        }
                                        .buttonStyle(BorderlessButtonStyle())
                                        .font(.caption.weight(.semibold))
                                        .foregroundColor(.white)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                        .background(deviceFlowClientId.isEmpty || deviceFlowClientSecret.isEmpty ? Color.gray : Color.blue)
                                        .cornerRadius(8)
                                        .disabled(deviceFlowClientId.isEmpty || deviceFlowClientSecret.isEmpty)
                                    }
                                }
                                .padding(.vertical, 4)
                            }

                            if !googleDrive.customClientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                HStack {
                                    Text(googleDrive.isUsingRcloneClientOverride
                                         ? "Saved rclone Client ID override detected."
                                         : "Using Custom Client ID override.")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                    Spacer()
                                    Button("Reset") {
                                        googleDrive.clearCustomOAuthOverride()
                                    }
                                    .buttonStyle(BorderlessButtonStyle())
                                    .font(.caption2)
                                    .foregroundColor(.blue)
                                }
                            }

                            if googleDrive.hasBundledDefaultClientId && googleDrive.customClientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.seal.fill")
                                        .foregroundColor(.green)
                                        .font(.caption)
                                    Text("1-tap Sign in with Google is pre-configured — no Client ID or token pasting required.")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }

                    DisclosureGroup("Advanced OAuth Settings (Optional)", isExpanded: $showAdvancedOAuth) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Custom OAuth 2.0 Client ID Override:")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button(action: { activeSheet = .googleGuide }) {
                                    Label("Setup Guide", systemImage: "questionmark.circle")
                                        .font(.caption2)
                                        .foregroundColor(.blue)
                                }
                                .buttonStyle(BorderlessButtonStyle())
                            }

                            TextField("xxxxxx.apps.googleusercontent.com", text: $googleDrive.customClientId)
                                .font(.system(size: 12, design: .monospaced))
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .padding(6)
                                .background(Color(UIColor.secondarySystemBackground))
                                .cornerRadius(6)

                            Text("Client Secret (Stored in Keychain — Optional for iOS PKCE):")
                                .font(.caption2)
                                .foregroundColor(.secondary)

                            SecureField("Client Secret", text: $googleDrive.customClientSecret)
                                .font(.system(size: 12, design: .monospaced))
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .padding(6)
                                .background(Color(UIColor.secondarySystemBackground))
                                .cornerRadius(6)

                            Divider().padding(.vertical, 2)

                            Text("Or Direct Refresh Token (Bypasses OAuth Login):")
                                .font(.caption2)
                                .foregroundColor(.secondary)

                            HStack {
                                SecureField("Paste Refresh Token (1//...)", text: $directTokenInput)
                                    .font(.system(size: 12, design: .monospaced))
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                                    .padding(6)
                                    .background(Color(UIColor.secondarySystemBackground))
                                    .cornerRadius(6)

                                Button("Save") {
                                    let trimmed = directTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !trimmed.isEmpty {
                                        googleDrive.setDirectTokens(accessToken: nil, refreshToken: trimmed)
                                        directTokenInput = ""
                                    }
                                }
                                .buttonStyle(BorderlessButtonStyle())
                                .font(.caption)
                                .disabled(directTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                // Section 3: Rclone Integration (Token-Free Cloud)
                Section(header: Text("Rclone Integration (Token-Free Cloud)")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Connect your existing rclone Google Drive remote with 1 tap. Bypasses Google OAuth browser setup entirely.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if let msg = rclone.statusMessage {
                            Text(msg)
                                .font(.caption2)
                                .foregroundColor(.blue)
                                .padding(.vertical, 2)
                        }
                    }

                    if rclone.detectedRemotes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No rclone remotes found in standard locations.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            HStack {
                                Button(action: {
                                    rclone.scanEnvironment()
                                }) {
                                    Label("Re-scan Device", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(BorderlessButtonStyle())
                                .font(.caption)

                                Spacer()

                                Button(action: {
                                    activeSheet = .rcloneConf
                                }) {
                                    Label("Paste / Import rclone.conf", systemImage: "doc.badge.plus")
                                }
                                .buttonStyle(BorderlessButtonStyle())
                                .font(.caption)
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        ForEach(rclone.detectedRemotes) { remote in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: remote.type == "drive" ? "externaldrive.badge.icloud" : "server.rack")
                                        .foregroundColor(.blue)
                                    Text(remote.name)
                                        .font(.headline)
                                    Spacer()
                                    Text(remote.type)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.15))
                                        .cornerRadius(4)
                                }

                                HStack(spacing: 10) {
                                    if remote.type == "drive" && (remote.refreshToken != nil || remote.accessToken != nil) {
                                        Button(action: {
                                            _ = rclone.importGoogleDriveTokens(from: remote)
                                        }) {
                                            Text("Connect Google Drive")
                                                .font(.caption.weight(.semibold))
                                                .foregroundColor(.white)
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 6)
                                                .background(Color.green)
                                                .cornerRadius(6)
                                        }
                                        .buttonStyle(BorderlessButtonStyle())
                                    }

                                    if rclone.isRcloneBinaryPresent {
                                        if rclone.isBridgeRunning && rclone.selectedRemoteName == remote.name {
                                            Button(action: {
                                                rclone.stopWebDAVBridge()
                                            }) {
                                                Text("Stop Local WebDAV")
                                                    .font(.caption)
                                                    .foregroundColor(.red)
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 6)
                                                    .background(Color.red.opacity(0.1))
                                                    .cornerRadius(6)
                                            }
                                            .buttonStyle(BorderlessButtonStyle())
                                        } else {
                                            Button(action: {
                                                _ = rclone.startWebDAVBridge(remoteName: remote.name)
                                            }) {
                                                Text("Serve WebDAV (127.0.0.1:\(rclone.activeBridgePort))")
                                                    .font(.caption)
                                                    .foregroundColor(.blue)
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 6)
                                                    .background(Color.blue.opacity(0.1))
                                                    .cornerRadius(6)
                                            }
                                            .buttonStyle(BorderlessButtonStyle())
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }

                        if rclone.isRcloneBinaryPresent {
                            HStack {
                                Text("Bridge Subfolder:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                TextField("Optional (e.g. Backups)", text: $rclone.targetFolder)
                                    .font(.system(size: 12, design: .monospaced))
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                                    .padding(4)
                                    .background(Color(UIColor.secondarySystemBackground))
                                    .cornerRadius(4)
                            }
                            .padding(.vertical, 2)
                        }

                        HStack {
                            Button(action: {
                                rclone.scanEnvironment()
                            }) {
                                Label("Re-scan", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            .font(.caption)

                            Spacer()

                            Button(action: {
                                activeSheet = .rcloneConf
                            }) {
                                Label("Edit / Import Config", systemImage: "doc.badge.plus")
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            .font(.caption)
                        }
                    }

                    if rclone.isBridgeRunning {
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundColor(.green)
                            Text("Active Local WebDAV Bridge: http://127.0.0.1:\(rclone.activeBridgePort)/")
                                .font(.caption2)
                                .foregroundColor(.green)
                        }
                    }
                }

                // Section 4: WebDAV / Nextcloud / Synology NAS
                Section(header: Text("WebDAV / Nextcloud / NAS")) {
                    HStack {
                        TextField("Server URL (http://...)", text: $webdav.serverURL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .font(.system(size: 12, design: .monospaced))

                        Button("Local Rclone") {
                            webdav.serverURL = "http://127.0.0.1:\(rclone.activeBridgePort)/"
                            webdav.username = ""
                            webdav.password = ""
                            webdav.updateConfiguredState()
                        }
                        .buttonStyle(BorderlessButtonStyle())
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.15))
                        .cornerRadius(6)
                    }

                    TextField("Username (Optional for local bridge)", text: $webdav.username)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)

                    SecureField("Password (Optional for local bridge)", text: $webdav.password)

                    Button(action: {
                        isTestingWebDAV = true
                        webdavTestStatus = nil
                        Task {
                            do {
                                let ok = try await webdav.testConnection()
                                await MainActor.run {
                                    isTestingWebDAV = false
                                    webdavTestSuccess = ok
                                    webdavTestStatus = ok ? "Connected and saved!" : "Server rejected PROPFIND credentials or path."
                                }
                            } catch {
                                await MainActor.run {
                                    isTestingWebDAV = false
                                    webdavTestSuccess = false
                                    webdavTestStatus = "Connection failed: \(error.localizedDescription)"
                                }
                            }
                        }
                    }) {
                        HStack {
                            if isTestingWebDAV {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Testing Connection...")
                            } else {
                                Text("Test & Save Connection")
                            }
                        }
                    }
                    .disabled(isTestingWebDAV || webdav.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let status = webdavTestStatus {
                        HStack(spacing: 6) {
                            Image(systemName: webdavTestSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(webdavTestSuccess ? .green : .red)
                            Text(status)
                                .font(.caption)
                                .foregroundColor(webdavTestSuccess ? .green : .red)
                        }
                    }
                }

                // Section 5: Backup Defaults & Retention
                Section(header: Text("Backup Defaults & Retention")) {
                    Picker("Default Backup Mode", selection: $settingsVM.defaultBackupMode) {
                        ForEach(BackupMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }

                    Toggle("Include Caches by Default", isOn: $settingsVM.defaultIncludeCaches)

                    Picker("Local Retention per App", selection: $settingsVM.maxBackupsPerApp) {
                        Text("Unlimited").tag(0)
                        Text("Keep Newest 1").tag(1)
                        Text("Keep Newest 3").tag(3)
                        Text("Keep Newest 5").tag(5)
                        Text("Keep Newest 10").tag(10)
                    }
                }

                // Section 6: System Environment
                Section(header: Text("Environment Diagnostics")) {
                    HStack {
                        Label("Filesystem Privileges", systemImage: "shield.checkerboard")
                        Spacer()
                        Text(settingsVM.canAccessRootMobile ? "Unsandboxed (Root/Mobile)" : "Sandboxed")
                            .foregroundColor(settingsVM.canAccessRootMobile ? .green : .orange)
                            .font(.system(size: 14, weight: .bold))
                    }

                    HStack {
                        Label("TrollStore Compatibility", systemImage: "checkmark.seal.fill")
                        Spacer()
                        Text(settingsVM.isTrollStoreEnvironment ? "Detected" : "Standard")
                            .foregroundColor(settingsVM.isTrollStoreEnvironment ? .green : .secondary)
                    }

                    HStack {
                        Label("Device & OS", systemImage: "iphone")
                        Spacer()
                        Text("\(UIDevice.current.model) \u{2022} iOS \(UIDevice.current.systemVersion)")
                            .foregroundColor(.secondary)
                    }
                }

                // Section 7: Storage Statistics
                Section(header: Text("Storage Management")) {
                    HStack {
                        Label("Free Device Storage", systemImage: "internaldrive")
                        Spacer()
                        Text(settingsVM.freeDiskSpace)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Label("AppVault Backups Storage", systemImage: "archivebox.fill")
                        Spacer()
                        Text(settingsVM.backupStorageUsed)
                            .foregroundColor(.blue)
                            .font(.system(size: 14, weight: .bold))
                    }

                    HStack {
                        Label("Temporary Staging Cache", systemImage: "trash.circle")
                        Spacer()
                        Text(settingsVM.tempStorageUsed)
                            .foregroundColor(.secondary)
                    }

                    Button(action: {
                        settingsVM.clearTemporaryFiles()
                    }) {
                        Label("Purge Staging Files", systemImage: "xmark.bin")
                            .foregroundColor(.red)
                    }
                }

                // Section 8: Storage Locations
                Section(header: Text("Storage Destination")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Active Backups Directory:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(BackupEngine.shared.backupsDirectory.path)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.primary)
                    }
                    .padding(.vertical, 4)
                }

                // Section 8.5: Debug & Diagnostic Logs
                Section(header: Text("Diagnostics & Debug Logs")) {
                    NavigationLink(destination: DebugLogsView()) {
                        HStack {
                            Label("View Live Debug Logs", systemImage: "terminal.fill")
                            Spacer()
                            Text("\(DebugLogger.shared.entries.count)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Button(action: {
                        UIPasteboard.general.string = DebugLogger.shared.exportTextReport()
                    }) {
                        Label("Copy Sanitized Diagnostic Report", systemImage: "doc.on.doc")
                            .font(.subheadline)
                    }
                }

                // Section 9: About
                Section(header: Text("About AppVault")) {
                    HStack {
                        Text("App Version")
                        Spacer()
                        Text(appVersionLabel)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Author")
                        Spacer()
                        Text("Moe (@Itsmoe-a11y)")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Source Code")
                        Spacer()
                        Link("GitHub Repository", destination: URL(string: "https://github.com/Itsmoe-a11y/AppVault")!)
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle("Settings & Cloud")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { settingsVM.refreshDiagnostics() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .googleGuide:
                GoogleSetupGuideSheet()
            case .rcloneConf:
                RcloneConfSheet()
            }
        }
    }
}

// MARK: - Google OAuth 2.0 Setup Guide Sheet
public struct GoogleSetupGuideSheet: View {
    @Environment(\.presentationMode) var presentationMode
    @ObservedObject var googleDrive = GoogleDriveService.shared
    @State private var copiedBundleId: Bool = false
    @State private var clientIdInput: String = ""

    public var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header Card
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Image(systemName: "icloud.and.arrow.up.fill")
                                .font(.system(size: 32))
                                .foregroundColor(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Google Cloud Setup")
                                    .font(.system(size: 20, weight: .bold))
                                Text("Free personal OAuth 2.0 Client ID (2 min)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Text("Google requires third-party iOS apps to use a registered OAuth Client ID. You can generate your own free Client ID in Google Cloud Console.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(12)

                    // Bundle Identifier Card
                    VStack(alignment: .leading, spacing: 8) {
                        Text("App Bundle Identifier:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack {
                            Text("dev.moe.appvault")
                                .font(.system(size: 15, weight: .bold, design: .monospaced))
                                .foregroundColor(.primary)

                            Spacer()

                            Button(action: {
                                UIPasteboard.general.string = "dev.moe.appvault"
                                copiedBundleId = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    copiedBundleId = false
                                }
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: copiedBundleId ? "checkmark" : "doc.on.doc")
                                    Text(copiedBundleId ? "Copied!" : "Copy")
                                }
                                .font(.system(size: 12, weight: .bold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(copiedBundleId ? Color.green : Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(6)
                            }
                        }
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(12)

                    // Numbered Steps
                    VStack(alignment: .leading, spacing: 16) {
                        guideStep(
                            number: "1",
                            title: "Open Google Cloud Console",
                            detail: "Go to console.cloud.google.com on your PC or phone and sign in with your Google account."
                        )

                        guideStep(
                            number: "2",
                            title: "Create Project & Enable Drive API",
                            detail: "Create a new project (e.g. 'AppVault'). In the top search bar, search for 'Google Drive API' and click 'Enable'."
                        )

                        guideStep(
                            number: "3",
                            title: "Configure OAuth Consent Screen",
                            detail: "Go to 'APIs & Services' > 'OAuth consent screen'. Choose 'External'. Fill in the App Name ('AppVault') and your email. In Scopes, add '.../auth/drive.file'. Under 'Test users', add your Google email."
                        )

                        guideStep(
                            number: "4",
                            title: "Create iOS Client ID",
                            detail: "Go to 'APIs & Services' > 'Credentials' > 'Create Credentials' > 'OAuth client ID'. Select 'iOS' as Application Type. Enter 'dev.moe.appvault' as the Bundle ID."
                        )

                        guideStep(
                            number: "5",
                            title: "Paste Client ID Below",
                            detail: "Copy the generated Client ID (looks like xxxx.apps.googleusercontent.com) and paste it into the field below."
                        )
                    }

                    // Input Box
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Paste your Client ID here:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        TextField("xxxxxx.apps.googleusercontent.com", text: $clientIdInput)
                            .font(.system(size: 13, design: .monospaced))
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .padding(10)
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(8)

                        Button(action: {
                            let trimmed = clientIdInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                googleDrive.customClientId = trimmed
                                presentationMode.wrappedValue.dismiss()
                                googleDrive.signIn()
                            }
                        }) {
                            Text("Save & Sign In with Google")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(clientIdInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray : Color.blue)
                                .cornerRadius(8)
                        }
                        .disabled(clientIdInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground).opacity(0.6))
                    .cornerRadius(12)

                    // Troubleshooting Card
                    VStack(alignment: .leading, spacing: 8) {
                        Text("⚠️ Troubleshooting Common Errors:")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.orange)

                        Text("• 'Error 401 invalid_client': You selected 'Web application' instead of 'iOS' when creating the OAuth Client ID in Google Cloud. Delete it and create an 'iOS' Client ID with Bundle ID: dev.moe.appvault.")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        Text("• 'Access blocked: Authorization Error': In Google Cloud Console under 'OAuth consent screen', scroll down to 'Test users' and add your Gmail address.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(12)

                    // Alternative Note
                    VStack(alignment: .leading, spacing: 6) {
                        Text("💡 Zero-Setup Alternative:")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.primary)

                        Text("If you prefer not setting up Google Cloud, use AppVault's built-in Local Wi-Fi Browser Transfer (port 8080) to download backups straight to your PC browser, or use WebDAV / Nextcloud.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(12)
                }
                .padding()
            }
            .navigationTitle("Google Drive Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .onAppear {
                clientIdInput = googleDrive.customClientId
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func guideStep(number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 28, height: 28)
                Text(number)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Rclone Configuration Sheet
public struct RcloneConfSheet: View {
    @Environment(\.presentationMode) var presentationMode
    @ObservedObject var rclone = RcloneHelper.shared
    @State private var configText: String = ""
    @State private var alertMessage: String? = nil
    @State private var showAlert: Bool = false

    public var body: some View {
        NavigationView {
            Form {
                Section(header: Text("rclone.conf Content")) {
                    Text("Paste the contents of your rclone.conf file below. AppVault will automatically parse your remotes and Google Drive credentials.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextEditor(text: $configText)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(minHeight: 200)

                    Button(action: {
                        if let clip = UIPasteboard.general.string, !clip.isEmpty {
                            configText = clip
                        }
                    }) {
                        Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                    }
                    .font(.caption)
                }

                Section(header: Text("Actions")) {
                    Button(action: {
                        let trimmed = configText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty {
                            alertMessage = "Configuration text is empty."
                            showAlert = true
                        } else if rclone.importFromConfString(trimmed, saveToAppStorage: true) {
                            presentationMode.wrappedValue.dismiss()
                        } else {
                            alertMessage = "Could not find any valid remote sections in the text."
                            showAlert = true
                        }
                    }) {
                        HStack {
                            Spacer()
                            Text("Parse & Save Remotes")
                                .font(.body.weight(.semibold))
                            Spacer()
                        }
                    }
                    .disabled(configText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section(header: Text("Where to find rclone.conf")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("• Jailbroken iOS: /var/mobile/.config/rclone/rclone.conf")
                        Text("• Windows: %APPDATA%\\rclone\\rclone.conf")
                        Text("• macOS / Linux: ~/.config/rclone/rclone.conf")
                        Text("• Android / Termux: ~/.config/rclone/rclone.conf")
                        Text("• Or run: 'rclone config file' in any terminal.")
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Import rclone.conf")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .alert(isPresented: $showAlert) {
                Alert(title: Text("Rclone Config"), message: Text(alertMessage ?? ""), dismissButton: .default(Text("OK")))
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}
