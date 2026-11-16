import Foundation

public struct WebDAVFile: Identifiable, Hashable {
    public var id: String { name }
    public let name: String
    public let size: Int64
    public let modifiedDate: Date

    public init(name: String, size: Int64, modifiedDate: Date) {
        self.name = name
        self.size = size
        self.modifiedDate = modifiedDate
    }

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

// MARK: - WebDAV RFC 4918 XML Response Parser
private final class WebDAVXMLParser: NSObject, XMLParserDelegate {
    private var files: [WebDAVFile] = []
    private var currentElement: String = ""
    private var currentText: String = ""

    private var currentHref: String = ""
    private var currentDisplayName: String?
    private var currentContentLength: Int64 = 0
    private var currentLastModified: String = ""
    private var isCurrentCollection: Bool = false

    private static let rfc1123Formatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return df
    }()

    private static let rfc850Formatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "EEEE, dd-MMM-yy HH:mm:ss zzz"
        return df
    }()

    private static let isoFormatter = ISO8601DateFormatter()

    func parse(data: Data) -> [WebDAVFile] {
        files.removeAll()
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.parse()
        return files
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let tag = elementName.lowercased()
        let cleanTag = tag.components(separatedBy: ":").last ?? tag
        currentElement = cleanTag
        currentText = ""

        if cleanTag == "response" {
            currentHref = ""
            currentDisplayName = nil
            currentContentLength = 0
            currentLastModified = ""
            isCurrentCollection = false
        } else if cleanTag == "collection" {
            isCurrentCollection = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let tag = elementName.lowercased()
        let cleanTag = tag.components(separatedBy: ":").last ?? tag
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch cleanTag {
        case "href":
            currentHref = trimmed
        case "displayname":
            currentDisplayName = trimmed
        case "getcontentlength":
            currentContentLength = Int64(trimmed) ?? 0
        case "getlastmodified":
            currentLastModified = trimmed
        case "response":
            if !isCurrentCollection && !currentHref.isEmpty {
                let decodedHref = currentHref.removingPercentEncoding ?? currentHref
                let fileName = currentDisplayName ?? (decodedHref as NSString).lastPathComponent
                if !fileName.isEmpty && fileName != "/" {
                    let date = parseDate(currentLastModified) ?? Date()
                    let file = WebDAVFile(name: fileName, size: currentContentLength, modifiedDate: date)
                    files.append(file)
                }
            }
        default:
            break
        }
    }

    private func parseDate(_ string: String) -> Date? {
        guard !string.isEmpty else { return nil }
        if let d = Self.rfc1123Formatter.date(from: string) { return d }
        if let d = Self.isoFormatter.date(from: string) { return d }
        if let d = Self.rfc850Formatter.date(from: string) { return d }
        return nil
    }
}

// MARK: - WebDAV Service
@MainActor
public final class WebDAVService: ObservableObject {
    public static let shared = WebDAVService()

    private static let keychainService = "dev.moe.appvault.webdav"
    private static let keychainPasswordAccount = "webdav_password"

    @Published public var serverURL: String {
        didSet {
            UserDefaults.standard.set(serverURL, forKey: "webdav_server_url")
            updateConfiguredState()
        }
    }
    @Published public var username: String {
        didSet {
            UserDefaults.standard.set(username, forKey: "webdav_username")
            updateConfiguredState()
        }
    }
    @Published public var password: String {
        didSet {
            // Store password securely in Keychain
            KeychainService.shared.savePassword(service: Self.keychainService, account: Self.keychainPasswordAccount, password: password)
        }
    }
    @Published public var isConfigured: Bool = false
    @Published public var remoteFiles: [WebDAVFile] = []
    @Published public var isLoading: Bool = false

    public func updateConfiguredState() {
        let clean = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isConfigured = !clean.isEmpty && (clean.hasPrefix("http://") || clean.hasPrefix("https://"))
    }

    private init() {
        self.serverURL = UserDefaults.standard.string(forKey: "webdav_server_url") ?? ""
        self.username = UserDefaults.standard.string(forKey: "webdav_username") ?? ""

        // Migrate password from legacy UserDefaults to Keychain if found
        if let legacyPass = UserDefaults.standard.string(forKey: "webdav_password"), !legacyPass.isEmpty {
            KeychainService.shared.savePassword(service: Self.keychainService, account: Self.keychainPasswordAccount, password: legacyPass)
            UserDefaults.standard.removeObject(forKey: "webdav_password")
            self.password = legacyPass
        } else {
            self.password = KeychainService.shared.loadPassword(service: Self.keychainService, account: Self.keychainPasswordAccount) ?? ""
        }

        updateConfiguredState()
    }

    // MARK: - Basic Auth Header (RFC 7617) with CRLF injection protection
    private var authHeader: String? {
        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        guard !cleanUser.isEmpty else { return nil }

        let cleanPass = password
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")

        let loginStr = "\(cleanUser):\(cleanPass)"
        guard let data = loginStr.data(using: .utf8) else { return nil }
        return "Basic \(data.base64EncodedString())"
    }

    // MARK: - Safe Target URL Builder with Percent Encoding
    private func buildTargetURL(for remoteFileName: String) throws -> URL {
        var baseStr = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !baseStr.hasSuffix("/") {
            baseStr += "/"
        }

        guard let encodedFileName = remoteFileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: baseStr + encodedFileName) else {
            throw NSError(domain: "WebDAV", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid remote file path or filename encoding: \(remoteFileName)"])
        }
        return url
    }

    // MARK: - Test Connection
    public func testConnection() async throws -> Bool {
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
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

    // MARK: - List Remote Files (PROPFIND Depth: 1 RFC 4918)
    public func fetchRemoteFiles() async throws -> [WebDAVFile] {
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw NSError(domain: "WebDAV", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid server URL."])
        }

        self.isLoading = true
        defer { self.isLoading = false }

        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let auth = authHeader { request.setValue(auth, forHTTPHeaderField: "Authorization") }

        let xmlBody = """
        <?xml version="1.0" encoding="utf-8" ?>
        <D:propfind xmlns:D="DAV:">
          <D:prop>
            <D:displayname/>
            <D:getcontentlength/>
            <D:getlastmodified/>
            <D:resourcetype/>
          </D:prop>
        </D:propfind>
        """
        request.httpBody = xmlBody.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 207 || (http.statusCode >= 200 && http.statusCode < 300) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \( (response as? HTTPURLResponse)?.statusCode ?? -1 )"
            throw NSError(domain: "WebDAV", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: "PROPFIND failed: \(msg)"])
        }

        let parser = WebDAVXMLParser()
        let parsedFiles = parser.parse(data: data)
            .sorted(by: { $0.modifiedDate > $1.modifiedDate })

        self.remoteFiles = parsedFiles
        return parsedFiles
    }

    // MARK: - Upload File from Data
    public func upload(data: Data, remoteFileName: String) async throws {
        let targetURL = try buildTargetURL(for: remoteFileName)

        var request = URLRequest(url: targetURL)
        request.httpMethod = "PUT"
        if let auth = authHeader { request.setValue(auth, forHTTPHeaderField: "Authorization") }
        request.httpBody = data

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (http.statusCode >= 200 && http.statusCode < 300) else {
            throw NSError(domain: "WebDAV", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: "WebDAV upload failed."])
        }
    }

    // MARK: - Upload File Stream from Disk (Zero Memory Spike)
    public func uploadFile(fileURL: URL, remoteFileName: String) async throws {
        let targetURL = try buildTargetURL(for: remoteFileName)

        var request = URLRequest(url: targetURL)
        request.httpMethod = "PUT"
        if let auth = authHeader { request.setValue(auth, forHTTPHeaderField: "Authorization") }

        let (_, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        guard let http = response as? HTTPURLResponse, (http.statusCode >= 200 && http.statusCode < 300) else {
            throw NSError(domain: "WebDAV", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: "WebDAV upload failed."])
        }
    }

    // MARK: - Download File
    public func download(remoteFileName: String, destinationURL: URL) async throws {
        let targetURL = try buildTargetURL(for: remoteFileName)

        var request = URLRequest(url: targetURL)
        request.httpMethod = "GET"
        if let auth = authHeader { request.setValue(auth, forHTTPHeaderField: "Authorization") }

        let (tempURL, res) = try await URLSession.shared.download(for: request)
        guard let http = res as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "WebDAV", code: (res as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: "WebDAV download failed."])
        }

        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
        PosixHelper.shared.fixPermissions(at: destinationURL.path)
    }

    // MARK: - Delete Remote File
    public func deleteFile(remoteFileName: String) async throws {
        let targetURL = try buildTargetURL(for: remoteFileName)

        var request = URLRequest(url: targetURL)
        request.httpMethod = "DELETE"
        if let auth = authHeader { request.setValue(auth, forHTTPHeaderField: "Authorization") }

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (http.statusCode >= 200 && http.statusCode < 300) else {
            throw NSError(domain: "WebDAV", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: "WebDAV delete failed."])
        }
    }

    public func disconnect() {
        serverURL = ""
        username = ""
        password = ""
        isConfigured = false
        remoteFiles = []
        UserDefaults.standard.removeObject(forKey: "webdav_server_url")
        UserDefaults.standard.removeObject(forKey: "webdav_username")
        KeychainService.shared.deletePassword(service: Self.keychainService, account: Self.keychainPasswordAccount)
    }
}
