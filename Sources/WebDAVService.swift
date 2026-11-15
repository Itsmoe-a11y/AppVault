import Foundation

public struct WebDAVFile: Identifiable, Hashable {
    public var id: String { name }
    public let name: String
    public let size: Int64
    public let modifiedDate: Date

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    public var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: modifiedDate)
    }
}

@MainActor
public final class WebDAVService: ObservableObject {
    public static let shared = WebDAVService()

    @Published public var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "webdav_server_url") }
    }
    @Published public var username: String {
        didSet { UserDefaults.standard.set(username, forKey: "webdav_username") }
    }
    @Published public var password: String {
        didSet { UserDefaults.standard.set(password, forKey: "webdav_password") }
    }
    @Published public var isConfigured: Bool = false
    @Published public var remoteFiles: [WebDAVFile] = []
    @Published public var isLoading: Bool = false

    private init() {
        self.serverURL = UserDefaults.standard.string(forKey: "webdav_server_url") ?? ""
        self.username = UserDefaults.standard.string(forKey: "webdav_username") ?? ""
        self.password = UserDefaults.standard.string(forKey: "webdav_password") ?? ""
        self.isConfigured = !serverURL.isEmpty && !username.isEmpty
    }

    private var authHeader: String? {
        guard !username.isEmpty else { return nil }
        let loginStr = "\(username):\(password)"
        guard let data = loginStr.data(using: .utf8) else { return nil }
        return "Basic \(data.base64EncodedString())"
    }

    // MARK: - Test Connection
    public func testConnection() async throws -> Bool {
        guard let url = URL(string: serverURL) else {
            throw NSError(domain: "WebDAV", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid server URL."])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("0", forHTTPHeaderField: "Depth")
        if let auth = authHeader { request.setValue(auth, forHTTPHeaderField: "Authorization") }

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (http.statusCode >= 200 && http.statusCode < 300) || http.statusCode == 207 else {
            return false
        }
        self.isConfigured = true
        return true
    }

    // MARK: - Upload File Chunk Stream
    public func upload(data: Data, remoteFileName: String) async throws {
        let base = serverURL.hasSuffix("/") ? serverURL : serverURL + "/"
        guard let targetURL = URL(string: "\(base)\(remoteFileName)") else {
            throw NSError(domain: "WebDAV", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid remote file URL."])
        }

        var request = URLRequest(url: targetURL)
        request.httpMethod = "PUT"
        if let auth = authHeader { request.setValue(auth, forHTTPHeaderField: "Authorization") }
        request.httpBody = data

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (http.statusCode >= 200 && http.statusCode < 300) else {
            throw NSError(domain: "WebDAV", code: 500, userInfo: [NSLocalizedDescriptionKey: "WebDAV upload failed."])
        }
    }

    // MARK: - Download File
    public func download(remoteFileName: String, destinationURL: URL) async throws {
        let base = serverURL.hasSuffix("/") ? serverURL : serverURL + "/"
        guard let targetURL = URL(string: "\(base)\(remoteFileName)") else {
            throw NSError(domain: "WebDAV", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid remote file URL."])
        }

        var request = URLRequest(url: targetURL)
        request.httpMethod = "GET"
        if let auth = authHeader { request.setValue(auth, forHTTPHeaderField: "Authorization") }

        let (tempURL, res) = try await URLSession.shared.download(for: request)
        guard let http = res as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "WebDAV", code: 500, userInfo: [NSLocalizedDescriptionKey: "WebDAV download failed."])
        }

        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
        PosixHelper.shared.fixPermissions(at: destinationURL.path)
    }

    public func disconnect() {
        serverURL = ""
        username = ""
        password = ""
        isConfigured = false
        remoteFiles = []
        UserDefaults.standard.removeObject(forKey: "webdav_server_url")
        UserDefaults.standard.removeObject(forKey: "webdav_username")
        UserDefaults.standard.removeObject(forKey: "webdav_password")
    }
}
