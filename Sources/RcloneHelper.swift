import Foundation
import UIKit

public struct RcloneRemote: Identifiable, Hashable {
    public var id: String { name }
    public let name: String
    public let type: String
    public let clientId: String?
    public let clientSecret: String?
    public let accessToken: String?
    public let refreshToken: String?

    public init(
        name: String,
        type: String,
        clientId: String? = nil,
        clientSecret: String? = nil,
        accessToken: String? = nil,
        refreshToken: String? = nil
    ) {
        self.name = name
        self.type = type
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }
}

@MainActor
public final class RcloneHelper: ObservableObject {
    public static let shared = RcloneHelper()

    // Public Fallback OAuth credentials for rclone remotes configured with default settings
    public static let rcloneDefaultClientId = "202264815644.apps.googleusercontent.com"
    public static let rcloneDefaultClientSecret = "b92Ljd-DO-vrv8V_e1-Fae-t"

    @Published public var isRcloneBinaryPresent: Bool = false
    @Published public var rcloneBinaryPath: String? = nil
    @Published public var detectedConfigPath: String? = nil
    @Published public var detectedRemotes: [RcloneRemote] = []
    @Published public var isBridgeRunning: Bool = false
    @Published public var activeBridgePort: Int = 8085
    @Published public var selectedRemoteName: String = ""
    @Published public var statusMessage: String? = nil

    private var bridgePid: pid_t? = nil

    private static let candidateBinaries = [
        "/var/jb/usr/bin/rclone",
        "/usr/local/bin/rclone",
        "/usr/bin/rclone",
        "/var/jb/bin/rclone"
    ]

    private static var appDocumentsConfigPath: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("rclone.conf").path
    }

    private static var candidateConfigs: [String] {
        let paths = [
            appDocumentsConfigPath,
            "/var/mobile/.config/rclone/rclone.conf",
            "/var/root/.config/rclone/rclone.conf",
            "/var/jb/var/mobile/.config/rclone/rclone.conf",
            "/var/jb/root/.config/rclone/rclone.conf",
            "/var/jb/etc/rclone/rclone.conf",
            "/private/var/mobile/.config/rclone/rclone.conf"
        ]
        return paths
    }

    private init() {
        scanEnvironment()
    }

    // MARK: - Scan Environment for Rclone Binary and Config
    public func scanEnvironment() {
        let fileManager = FileManager.default

        // Detect binary
        self.rcloneBinaryPath = Self.candidateBinaries.first { fileManager.isExecutableFile(atPath: $0) }
        self.isRcloneBinaryPresent = (rcloneBinaryPath != nil)

        // Detect config
        self.detectedConfigPath = Self.candidateConfigs.first { fileManager.fileExists(atPath: $0) }

        if let confPath = detectedConfigPath,
           let content = try? String(contentsOfFile: confPath, encoding: .utf8) {
            self.detectedRemotes = parseConfig(content: content)
            if !detectedRemotes.isEmpty && selectedRemoteName.isEmpty {
                self.selectedRemoteName = detectedRemotes.first?.name ?? ""
            }
        }
    }

    // MARK: - Import Config from String or File
    @discardableResult
    public func importFromConfString(_ content: String, saveToAppStorage: Bool = true) -> Bool {
        let parsed = parseConfig(content: content)
        guard !parsed.isEmpty else {
            statusMessage = "No valid [remotes] found in rclone configuration text."
            return false
        }

        self.detectedRemotes = parsed
        if selectedRemoteName.isEmpty || !parsed.contains(where: { $0.name == selectedRemoteName }) {
            self.selectedRemoteName = parsed.first?.name ?? ""
        }

        if saveToAppStorage {
            let path = Self.appDocumentsConfigPath
            try? content.write(toFile: path, atomically: true, encoding: .utf8)
            self.detectedConfigPath = path
        }

        statusMessage = "Successfully parsed \(parsed.count) remote(s) from rclone.conf!"
        return true
    }

    // MARK: - Parse rclone.conf INI Content
    public func parseConfig(content: String) -> [RcloneRemote] {
        var remotes: [RcloneRemote] = []
        let lines = content.components(separatedBy: .newlines)

        var currentSection = ""
        var currentProperties: [String: String] = [:]

        func finishSection() {
            guard !currentSection.isEmpty else { return }
            let type = currentProperties["type"] ?? "unknown"
            let clientId = currentProperties["client_id"]
            let clientSecret = currentProperties["client_secret"]

            var accessToken: String? = nil
            var refreshToken: String? = nil

            if let tokenStr = currentProperties["token"],
               let tokenData = tokenStr.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: tokenData) as? [String: Any] {
                accessToken = json["access_token"] as? String
                refreshToken = json["refresh_token"] as? String
            }

            remotes.append(RcloneRemote(
                name: currentSection,
                type: type,
                clientId: clientId,
                clientSecret: clientSecret,
                accessToken: accessToken,
                refreshToken: refreshToken
            ))
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") {
                continue
            }

            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                finishSection()
                currentSection = String(trimmed.dropFirst().dropLast())
                currentProperties.removeAll()
            } else if let eqIdx = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[..<eqIdx]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(trimmed[trimmed.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
                currentProperties[key] = value
            }
        }
        finishSection()

        return remotes
    }

    // MARK: - Import Direct Google Drive Credentials from Remote
    public func importGoogleDriveTokens(from remote: RcloneRemote) -> Bool {
        guard let refresh = remote.refreshToken, !refresh.isEmpty else {
            statusMessage = "No refresh token found in remote '\(remote.name)'."
            return false
        }

        let clientId = (remote.clientId?.isEmpty == false) ? remote.clientId! : Self.rcloneDefaultClientId
        let clientSecret = (remote.clientSecret?.isEmpty == false) ? remote.clientSecret! : Self.rcloneDefaultClientSecret

        GoogleDriveService.shared.customClientId = clientId
        GoogleDriveService.shared.customClientSecret = clientSecret
        GoogleDriveService.shared.setDirectTokens(accessToken: remote.accessToken, refreshToken: refresh)
        statusMessage = "Connected Google Drive from rclone remote '\(remote.name)'!"
        return true
    }

    // MARK: - Start Local WebDAV Bridge (rclone serve webdav)
    public func startWebDAVBridge(remoteName: String? = nil, port: Int = 8085) -> Bool {
        guard let binary = rcloneBinaryPath else {
            statusMessage = "rclone binary not found on device."
            return false
        }

        let targetRemote = remoteName ?? selectedRemoteName
        guard !targetRemote.isEmpty else {
            statusMessage = "No remote selected."
            return false
        }

        // Clean remote name (ensure it ends with colon if not present)
        let formattedRemote = targetRemote.hasSuffix(":") ? targetRemote : "\(targetRemote):"

        // Terminate any previous instance
        stopWebDAVBridge()

        var arguments = [
            "serve", "webdav",
            formattedRemote,
            "--addr", "127.0.0.1:\(port)",
            "--no-auth"
        ]

        if let conf = detectedConfigPath {
            arguments.append(contentsOf: ["--config", conf])
        }

        if let pid = PosixHelper.shared.spawnDaemon(binary, arguments: arguments) {
            self.bridgePid = pid
            self.isBridgeRunning = true
            self.activeBridgePort = port
            self.selectedRemoteName = targetRemote

            // Point WebDAV service to local bridge
            WebDAVService.shared.serverURL = "http://127.0.0.1:\(port)/"
            WebDAVService.shared.username = ""
            WebDAVService.shared.password = ""
            WebDAVService.shared.updateConfiguredState()

            statusMessage = "Rclone WebDAV bridge started for '\(formattedRemote)' on port \(port)."
            return true
        } else {
            statusMessage = "Failed to launch rclone daemon."
            return false
        }
    }

    // MARK: - Stop Local WebDAV Bridge
    public func stopWebDAVBridge() {
        if let pid = bridgePid {
            kill(pid, SIGTERM)
            self.bridgePid = nil
        }
        PosixHelper.shared.terminateApp(named: "rclone")
        self.isBridgeRunning = false
        statusMessage = "Rclone WebDAV bridge stopped."
    }
}
