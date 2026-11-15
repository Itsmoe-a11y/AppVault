import SwiftUI

public struct SettingsView: View {
    @EnvironmentObject var settingsVM: SettingsViewModel
    @ObservedObject var googleDrive = GoogleDriveService.shared
    @ObservedObject var webServer = LocalWebServer.shared
    @ObservedObject var webdav = WebDAVService.shared
    @State private var showAdvancedOAuth = false
    @State private var showGoogleGuide = false

    public init() {}

    public var body: some View {
        NavigationView {
            Form {
                // Section 1: Local Wi-Fi Transfer Server
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
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Open in any PC or phone browser on this Wi-Fi:")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(webServer.serverURLString)
                                .font(.system(size: 15, weight: .bold, design: .monospaced))
                                .foregroundColor(.blue)
                            Text("Download and upload backups directly over local network with zero cloud quota.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }

                // Section 2: Google Drive Cloud Integration
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

                        HStack {
                            Label("Target Cloud Folder", systemImage: "folder.badge.gearshape")
                            Spacer()
                            Text("AppVault Backups")
                                .foregroundColor(.secondary)
                        }

                        Button(action: { googleDrive.signOut() }) {
                            Text("Disconnect Google Drive")
                                .foregroundColor(.red)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Stream backups directly into your personal Google Drive with 0 MB device storage used.")
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
                                }
                                .padding(8)
                                .background(Color.red.opacity(0.1))
                                .cornerRadius(8)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("OAuth 2.0 Client ID")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Button(action: { showGoogleGuide = true }) {
                                        Label("Setup Guide", systemImage: "questionmark.circle")
                                            .font(.caption)
                                            .foregroundColor(.blue)
                                    }
                                }

                                TextField("xxxxxx.apps.googleusercontent.com", text: $googleDrive.customClientId)
                                    .font(.system(size: 13, design: .monospaced))
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                                    .padding(8)
                                    .background(Color(UIColor.secondarySystemBackground))
                                    .cornerRadius(6)
                            }

                            Button(action: {
                                if googleDrive.customClientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    showGoogleGuide = true
                                } else {
                                    googleDrive.signIn()
                                }
                            }) {
                                HStack {
                                    if googleDrive.isAuthenticating {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    } else {
                                        Image(systemName: "link.badge.plus")
                                    }
                                    Text(googleDrive.customClientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Setup Google Client ID (2 min)" : "Sign In with Google")
                                }
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.blue)
                                .cornerRadius(8)
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    DisclosureGroup("Advanced OAuth Settings (Optional)", isExpanded: $showAdvancedOAuth) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Client Secret is optional for iOS PKCE clients. Only provide if you created a Web Application client.")
                                .font(.caption2)
                                .foregroundColor(.secondary)

                            SecureField("Client Secret (Optional)", text: $googleDrive.customClientSecret)
                                .font(.system(size: 12, design: .monospaced))
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .padding(6)
                                .background(Color(UIColor.secondarySystemBackground))
                                .cornerRadius(6)
                        }
                        .padding(.vertical, 4)
                    }
                }

                // Section 3: WebDAV / Nextcloud / Synology NAS
                Section(header: Text("WebDAV / Nextcloud / NAS")) {
                    TextField("Server URL (https://...)", text: $webdav.serverURL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.system(size: 12, design: .monospaced))

                    TextField("Username", text: $webdav.username)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)

                    SecureField("Password", text: $webdav.password)

                    Button("Test & Save Connection") {
                        Task {
                            _ = try? await webdav.testConnection()
                        }
                    }
                }

                // Section 2: System Environment
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
                        Text("\(UIDevice.current.model) • iOS \(UIDevice.current.systemVersion)")
                            .foregroundColor(.secondary)
                    }
                }

                // Section 3: Storage Statistics
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

                // Section 4: Storage Locations
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

                // Section 5: About
                Section(header: Text("About AppVault")) {
                    HStack {
                        Text("App Version")
                        Spacer()
                        Text("2.0.2 (Ultimate Edition)")
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
        .sheet(isPresented: $showGoogleGuide) {
            GoogleSetupGuideSheet()
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
