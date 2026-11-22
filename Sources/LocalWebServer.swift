import Foundation
import Network
import UIKit

public final class LocalWebServer: ObservableObject {
    public static let shared = LocalWebServer()

    @Published public var isRunning: Bool = false
    @Published public var serverURLString: String = ""
    @Published public var connectionStatus: String = "Stopped"
    @Published public var accessPIN: String = ""

    private var listener: NWListener?
    private let port: NWEndpoint.Port = 8080
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]
    private let connectionQueue = DispatchQueue(label: "dev.moe.appvault.webserver.connection", qos: .userInitiated)

    private let maxHeaderSize = 65_536
    private let maxUploadSize: Int64 = 10 * 1024 * 1024 * 1024 // 10 GB

    private init() {
        self.accessPIN = Self.generatePIN()
    }

    public static func generatePIN() -> String {
        var val: UInt32 = 0
        _ = SecRandomCopyBytes(kSecRandomDefault, MemoryLayout<UInt32>.size, &val)
        return String(format: "%04d", val % 10_000)
    }

    public func regeneratePIN() {
        DispatchQueue.main.async {
            self.accessPIN = Self.generatePIN()
        }
    }

    // MARK: - Start Server
    public func start() {
        guard !isRunning else { return }
        if accessPIN.isEmpty {
            accessPIN = Self.generatePIN()
        }

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true

            let listener = try NWListener(using: params, on: port)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        let ip = self.getWiFiAddress() ?? "localhost"
                        self.serverURLString = "http://\(ip):\(self.port.rawValue)"
                        self.connectionStatus = "Running at \(self.serverURLString)"
                    case .waiting(let error):
                        self.connectionStatus = "Waiting: \(error.localizedDescription)"
                    case .failed(let error):
                        self.stop()
                        self.connectionStatus = "Failed: \(error.localizedDescription)"
                    case .cancelled:
                        self.isRunning = false
                        self.connectionStatus = "Stopped"
                    default:
                        break
                    }
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            listener.start(queue: connectionQueue)
        } catch {
            DispatchQueue.main.async {
                self.isRunning = false
                self.connectionStatus = "Error starting server: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Stop Server
    public func stop() {
        connectionQueue.async { [weak self] in
            guard let self = self else { return }
            for connection in self.activeConnections.values {
                connection.cancel()
            }
            self.activeConnections.removeAll()

            self.listener?.cancel()
            self.listener = nil

            DispatchQueue.main.async {
                self.isRunning = false
                self.serverURLString = ""
                self.connectionStatus = "Stopped"
            }
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connectionQueue.async {
            self.activeConnections[ObjectIdentifier(connection)] = connection
        }

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection = connection else { return }
            switch state {
            case .failed, .cancelled:
                self?.cleanupConnection(connection)
            default:
                break
            }
        }

        connection.start(queue: connectionQueue)
        readRequest(on: connection, accumulatedData: Data())
    }

    private func cleanupConnection(_ connection: NWConnection) {
        connectionQueue.async {
            self.activeConnections.removeValue(forKey: ObjectIdentifier(connection))
        }
        connection.cancel()
    }

    // MARK: - PIN Session Verification
    private func isAuthorized(headers: [String: String], path: String) -> Bool {
        let pin = self.accessPIN
        guard !pin.isEmpty else { return true }

        if let headerPin = headers["x-appvault-pin"], headerPin == pin {
            return true
        }
        if let cookie = headers["cookie"] {
            let cookies = cookie.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            if cookies.contains("appvault_pin=\(pin)") {
                return true
            }
        }
        if let comps = URLComponents(string: path),
           let qPin = comps.queryItems?.first(where: { $0.name == "pin" })?.value,
           qPin == pin {
            return true
        }
        return false
    }

    // MARK: - HTTP Request Parsing
    private func readRequest(on connection: NWConnection, accumulatedData: Data) {
        var buffer = accumulatedData

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else {
                connection.cancel()
                return
            }

            if let error = error {
                NSLog("[LocalWebServer] Connection error: %@", error.localizedDescription)
                self.cleanupConnection(connection)
                return
            }

            if let data = content, !data.isEmpty {
                buffer.append(data)
            }

            let headerDelimiter = "\r\n\r\n".data(using: .utf8)!
            if let delimiterRange = buffer.range(of: headerDelimiter) {
                let headerData = buffer.subdata(in: 0..<delimiterRange.lowerBound)
                let bodyInitialData = buffer.subdata(in: delimiterRange.upperBound..<buffer.count)

                guard let headerString = String(data: headerData, encoding: .utf8) else {
                    self.sendError(connection: connection, status: "400 Bad Request", message: "Malformed UTF-8 header.")
                    return
                }

                self.processHTTPRequest(
                    headerString: headerString,
                    bodyInitialData: bodyInitialData,
                    connection: connection
                )
            } else if buffer.count > self.maxHeaderSize {
                self.sendError(connection: connection, status: "431 Request Header Fields Too Large", message: "Request header exceeds 64KB limit.")
            } else if isComplete {
                self.cleanupConnection(connection)
            } else {
                self.readRequest(on: connection, accumulatedData: buffer)
            }
        }
    }

    private func processHTTPRequest(
        headerString: String,
        bodyInitialData: Data,
        connection: NWConnection
    ) {
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            sendError(connection: connection, status: "400 Bad Request", message: "Empty request line.")
            return
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendError(connection: connection, status: "400 Bad Request", message: "Malformed request line.")
            return
        }

        let method = parts[0].uppercased()
        let fullPath = parts[1]

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colonIndex = line.firstIndex(of: ":") {
                let key = line[..<colonIndex].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        // Handle PIN login form submission
        if method == "GET" && fullPath.starts(with: "/auth") {
            if let comps = URLComponents(string: fullPath),
               let submitted = comps.queryItems?.first(where: { $0.name == "pin" })?.value,
               submitted == self.accessPIN {
                let redirect = "<html><head><meta http-equiv='refresh' content='0;url=/'></head><body></body></html>".data(using: .utf8)!
                sendResponse(
                    connection: connection,
                    status: "200 OK",
                    contentType: "text/html; charset=utf-8",
                    extraHeaders: ["Set-Cookie": "appvault_pin=\(self.accessPIN); Path=/; HttpOnly; SameSite=Strict"],
                    body: redirect
                )
                return
            }
            servePinGate(connection: connection, errorMessage: "Incorrect 4-digit pairing PIN.")
            return
        }

        // Enforce 4-digit pairing PIN on all routes
        guard isAuthorized(headers: headers, path: fullPath) else {
            if method == "GET" && (fullPath == "/" || fullPath.starts(with: "/?")) {
                servePinGate(connection: connection, errorMessage: nil)
            } else {
                sendError(connection: connection, status: "401 Unauthorized", message: "Valid AppVault pairing PIN required.")
            }
            return
        }

        if method == "GET" && (fullPath == "/" || fullPath.starts(with: "/?")) {
            serveDashboard(connection: connection)
        } else if method == "GET" && fullPath.starts(with: "/download") {
            serveDownload(path: fullPath, connection: connection)
        } else if method == "POST" && fullPath.starts(with: "/delete") {
            handleDelete(path: fullPath, connection: connection)
        } else if method == "POST" && fullPath.starts(with: "/upload") {
            if (headers["transfer-encoding"] ?? "").lowercased().contains("chunked") {
                sendError(connection: connection, status: "411 Length Required", message: "Chunked transfer encoding is not supported. Please send a Content-Length header.")
                return
            }
            guard let rawLen = headers["content-length"], let contentLength = Int64(rawLen), contentLength > 0 else {
                sendError(connection: connection, status: "411 Length Required", message: "Missing or invalid Content-Length header.")
                return
            }
            let contentType = headers["content-type"] ?? ""
            handleUploadStreaming(
                contentLength: contentLength,
                contentType: contentType,
                initialBody: bodyInitialData,
                connection: connection
            )
        } else {
            sendError(connection: connection, status: "404 Not Found", message: "Resource Not Found")
        }
    }

    // MARK: - PIN Authentication Screen
    private func servePinGate(connection: NWConnection, errorMessage: String?) {
        let errHtml = errorMessage != nil ? "<p style='color:#f87171;font-size:13px;margin:0 0 12px;'>\(escapeHTML(errorMessage!))</p>" : ""
        let html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
            <title>AppVault Pairing PIN</title>
            <style>
                body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #0f172a; color: #f8fafc; display: flex; align-items: center; justify-content: center; min-height: 100vh; margin: 0; }
                .box { background: #1e293b; border: 1px solid #334155; border-radius: 12px; padding: 28px; width: 320px; text-align: center; }
                h2 { margin: 0 0 8px; color: #38bdf8; font-size: 20px; }
                p { color: #94a3b8; font-size: 13px; margin: 0 0 18px; }
                input { width: 100%; box-sizing: border-box; padding: 12px; font-size: 22px; text-align: center; letter-spacing: 8px; border-radius: 8px; border: 1px solid #475569; background: #0f172a; color: #f8fafc; margin-bottom: 14px; }
                button { width: 100%; padding: 10px; border: none; border-radius: 8px; background: #0284c7; color: white; font-weight: 600; font-size: 14px; cursor: pointer; }
            </style>
        </head>
        <body>
            <div class="box">
                <h2>AppVault Wi-Fi Transfer</h2>
                <p>Enter the 4-digit pairing PIN displayed in AppVault Settings on your iOS device.</p>
                \(errHtml)
                <form action="/auth" method="get">
                    <input type="text" name="pin" maxlength="4" pattern="[0-9]{4}" inputmode="numeric" placeholder="0000" required autofocus>
                    <button type="submit">Unlock Dashboard</button>
                </form>
            </div>
        </body>
        </html>
        """
        sendResponse(connection: connection, status: "200 OK", contentType: "text/html; charset=utf-8", body: html.data(using: .utf8)!)
    }

    // MARK: - Dashboard HTML (Live XHR Upload Progress + Delete Support)
    private func serveDashboard(connection: NWConnection) {
        let backupsDir = BackupEngine.shared.backupsDirectory
        let backups = (try? FileManager.default.contentsOfDirectory(at: backupsDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var filesListHtml = ""

        var queryAllowed = CharacterSet.alphanumerics
        queryAllowed.insert(charactersIn: "-._~")

        for file in backups where file.pathExtension == "adbk" || file.pathExtension == "zip" {
            let rawName = file.lastPathComponent
            let escapedName = escapeHTML(rawName)
            let encodedParam = rawName.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? rawName

            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)

            filesListHtml += """
            <tr>
                <td><strong>\(escapedName)</strong></td>
                <td>\(sizeStr)</td>
                <td style="white-space:nowrap;">
                    <a href="/download?file=\(encodedParam)" class="btn download-btn">Download</a>
                    <button onclick="deleteFile('\(encodedParam)')" class="btn delete-btn">Delete</button>
                </td>
            </tr>
            """
        }

        if filesListHtml.isEmpty {
            filesListHtml = "<tr><td colspan='3' style='text-align:center; color:#94a3b8; padding: 24px;'>No backups stored on this device yet.</td></tr>"
        }

        let html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>AppVault Wi-Fi Manager</title>
            <style>
                body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; background: #0f172a; color: #f8fafc; margin: 0; padding: 24px; }
                .container { max-width: 860px; margin: 0 auto; }
                .header { display: flex; align-items: center; justify-content: space-between; border-bottom: 1px solid #334155; padding-bottom: 16px; margin-bottom: 24px; }
                h1 { margin: 0; color: #38bdf8; font-size: 22px; font-weight: 700; }
                .meta { color: #94a3b8; font-size: 12px; }
                .card { background: #1e293b; border-radius: 12px; padding: 20px; margin-bottom: 24px; border: 1px solid #334155; }
                table { width: 100%; border-collapse: collapse; margin-top: 12px; }
                th, td { text-align: left; padding: 12px; border-bottom: 1px solid #334155; }
                th { color: #94a3b8; font-size: 12px; text-transform: uppercase; letter-spacing: 0.05em; }
                .btn { display: inline-block; padding: 7px 14px; border-radius: 6px; text-decoration: none; font-weight: 600; font-size: 13px; border: none; cursor: pointer; }
                .download-btn { background: #0284c7; color: white; margin-right: 6px; }
                .delete-btn { background: #7f1d1d; color: #fecaca; }
                .upload-box { border: 2px dashed #475569; border-radius: 8px; padding: 28px; text-align: center; cursor: pointer; display: block; }
                input[type=file] { display: none; }
                .progress-wrap { display: none; margin-top: 14px; }
                .bar-bg { background: #0f172a; border-radius: 6px; height: 10px; overflow: hidden; }
                .bar-fill { background: #38bdf8; height: 100%; width: 0%; transition: width 0.15s; }
            </style>
        </head>
        <body>
            <div class="container">
                <div class="header">
                    <h1>AppVault Local Wi-Fi Manager</h1>
                    <span class="meta">Local Network · PIN Protected</span>
                </div>
                <div class="card">
                    <h3 style="margin-top:0;">Upload Backup Archive (.adbk / .zip)</h3>
                    <label class="upload-box" id="drop-zone">
                        <p style="margin:0; font-size: 14px; color: #cbd5e1;" id="upload-label">Click here to select a backup archive to stream to this device</p>
                        <input type="file" id="file-input" accept=".adbk,.zip">
                    </label>
                    <div class="progress-wrap" id="progress-wrap">
                        <div class="bar-bg"><div class="bar-fill" id="bar-fill"></div></div>
                        <p id="progress-text" style="font-size:12px; color:#94a3b8; margin:6px 0 0;">Uploading 0%</p>
                    </div>
                </div>
                <div class="card">
                    <h3 style="margin-top:0;">On-Device Backups</h3>
                    <table>
                        <thead><tr><th>Archive Name</th><th>Size</th><th>Actions</th></tr></thead>
                        <tbody>\(filesListHtml)</tbody>
                    </table>
                </div>
            </div>
            <script>
                document.getElementById('file-input').addEventListener('change', function(e) {
                    const file = e.target.files[0];
                    if (!file) return;
                    const formData = new FormData();
                    formData.append('file', file);
                    const xhr = new XMLHttpRequest();
                    document.getElementById('progress-wrap').style.display = 'block';
                    xhr.upload.onprogress = function(ev) {
                        if (ev.lengthComputable) {
                            const pct = Math.round((ev.loaded / ev.total) * 100);
                            document.getElementById('bar-fill').style.width = pct + '%';
                            document.getElementById('progress-text').textContent = 'Uploading ' + file.name + ': ' + pct + '%';
                        }
                    };
                    xhr.onload = function() { window.location.reload(); };
                    xhr.onerror = function() { document.getElementById('progress-text').textContent = 'Upload failed.'; };
                    xhr.open('POST', '/upload', true);
                    xhr.send(formData);
                });
                function deleteFile(encodedName) {
                    if (!confirm('Delete this archive from the device?')) return;
                    fetch('/delete?file=' + encodedName, { method: 'POST' }).then(() => window.location.reload());
                }
            </script>
        </body>
        </html>
        """

        sendResponse(
            connection: connection,
            status: "200 OK",
            contentType: "text/html; charset=utf-8",
            body: html.data(using: .utf8)!
        )
    }

    // MARK: - Resolve Confined File Path (Trailing Separator Check)
    private func resolveConfinedBackupURL(requestedFile: String) -> (url: URL, sanitizedName: String)? {
        if requestedFile.contains("..") || requestedFile.contains("/") || requestedFile.contains("\\") || requestedFile.contains("\0") {
            return nil
        }
        let sanitizedName = (requestedFile as NSString).lastPathComponent
        guard !sanitizedName.isEmpty, sanitizedName != ".", sanitizedName != ".." else { return nil }

        let backupsDir = BackupEngine.shared.backupsDirectory.resolvingSymlinksInPath().standardizedFileURL
        let rootBoundary = backupsDir.path.hasSuffix("/") ? backupsDir.path : backupsDir.path + "/"
        let candidateURL = backupsDir.appendingPathComponent(sanitizedName).standardizedFileURL

        guard candidateURL.path.hasPrefix(rootBoundary) else { return nil }
        return (candidateURL, sanitizedName)
    }

    // MARK: - Delete Remote File Handler
    private func handleDelete(path: String, connection: NWConnection) {
        guard let urlComponents = URLComponents(string: path),
              let requestedFile = urlComponents.queryItems?.first(where: { $0.name == "file" })?.value,
              let resolved = resolveConfinedBackupURL(requestedFile: requestedFile) else {
            sendError(connection: connection, status: "403 Forbidden", message: "Invalid file path.")
            return
        }
        try? FileManager.default.removeItem(at: resolved.url)
        sendResponse(connection: connection, status: "200 OK", contentType: "text/plain; charset=utf-8", body: Data("Deleted".utf8))
    }

    // MARK: - Serve File Download (Confined Path + Sanitized Header + Streaming)
    private func serveDownload(path: String, connection: NWConnection) {
        guard let urlComponents = URLComponents(string: path),
              let requestedFile = urlComponents.queryItems?.first(where: { $0.name == "file" })?.value else {
            sendError(connection: connection, status: "400 Bad Request", message: "Missing file parameter.")
            return
        }

        guard let resolved = resolveConfinedBackupURL(requestedFile: requestedFile) else {
            sendError(connection: connection, status: "403 Forbidden", message: "Access denied: Invalid file path.")
            return
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.url.path, isDirectory: &isDir), !isDir.boolValue else {
            sendError(connection: connection, status: "404 Not Found", message: "File not found.")
            return
        }

        guard let fileAttributes = try? FileManager.default.attributesOfItem(atPath: resolved.url.path),
              let fileSize = fileAttributes[.size] as? Int64,
              let fileHandle = try? FileHandle(forReadingFrom: resolved.url) else {
            sendError(connection: connection, status: "500 Internal Server Error", message: "Cannot read file.")
            return
        }

        // Prevent HTTP header injection in Content-Disposition
        let safeHeaderName = resolved.sanitizedName
            .replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")

        let header = "HTTP/1.1 200 OK\r\n" +
                     "Content-Type: application/octet-stream\r\n" +
                     "Content-Length: \(fileSize)\r\n" +
                     "Content-Disposition: attachment; filename=\"\(safeHeaderName)\"\r\n" +
                     "Connection: close\r\n\r\n"

        connection.send(content: header.data(using: .utf8)!, completion: .contentProcessed({ [weak self] error in
            if let error = error {
                NSLog("[LocalWebServer] Stream header error: %@", error.localizedDescription)
                try? fileHandle.close()
                self?.cleanupConnection(connection)
                return
            }
            self?.streamFileChunks(fileHandle: fileHandle, connection: connection)
        }))
    }

    private func streamFileChunks(fileHandle: FileHandle, connection: NWConnection) {
        let chunkSize = 131_072
        let chunk = fileHandle.readData(ofLength: chunkSize)

        if chunk.isEmpty {
            try? fileHandle.close()
            cleanupConnection(connection)
            return
        }

        connection.send(content: chunk, completion: .contentProcessed({ [weak self] error in
            if let error = error {
                NSLog("[LocalWebServer] Stream chunk error: %@", error.localizedDescription)
                try? fileHandle.close()
                self?.cleanupConnection(connection)
                return
            }
            self?.streamFileChunks(fileHandle: fileHandle, connection: connection)
        }))
    }

    // MARK: - Handle Streaming Upload to Disk (Zero OOM)
    private func handleUploadStreaming(
        contentLength: Int64,
        contentType: String,
        initialBody: Data,
        connection: NWConnection
    ) {
        if contentLength > maxUploadSize {
            sendError(connection: connection, status: "413 Payload Too Large", message: "File exceeds 10 GB limit.")
            return
        }

        let tempUploadURL = FileManager.default.temporaryDirectory.appendingPathComponent("upload_\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: tempUploadURL.path, contents: nil, attributes: nil)

        guard let fileHandle = try? FileHandle(forWritingTo: tempUploadURL) else {
            sendError(connection: connection, status: "500 Internal Server Error", message: "Cannot create temp file.")
            return
        }

        var totalBytesReceived: Int64 = 0
        if !initialBody.isEmpty {
            try? fileHandle.write(contentsOf: initialBody)
            totalBytesReceived += Int64(initialBody.count)
        }

        if totalBytesReceived >= contentLength {
            try? fileHandle.close()
            finalizeUpload(tempURL: tempUploadURL, contentType: contentType, connection: connection)
            return
        }

        readRemainingBody(
            fileHandle: fileHandle,
            totalBytesReceived: totalBytesReceived,
            targetLength: contentLength,
            tempURL: tempUploadURL,
            contentType: contentType,
            connection: connection
        )
    }

    private func readRemainingBody(
        fileHandle: FileHandle,
        totalBytesReceived: Int64,
        targetLength: Int64,
        tempURL: URL,
        contentType: String,
        connection: NWConnection
    ) {
        var currentBytes = totalBytesReceived

        connection.receive(minimumIncompleteLength: 1, maximumLength: 131_072) { [weak self] content, _, isComplete, error in
            guard let self = self else {
                try? fileHandle.close()
                try? FileManager.default.removeItem(at: tempURL)
                connection.cancel()
                return
            }

            if let error = error {
                NSLog("[LocalWebServer] Upload receive error: %@", error.localizedDescription)
                try? fileHandle.close()
                try? FileManager.default.removeItem(at: tempURL)
                self.cleanupConnection(connection)
                return
            }

            if let data = content, !data.isEmpty {
                try? fileHandle.write(contentsOf: data)
                currentBytes += Int64(data.count)
            }

            if currentBytes >= targetLength {
                try? fileHandle.close()
                self.finalizeUpload(tempURL: tempURL, contentType: contentType, connection: connection)
            } else if isComplete {
                try? fileHandle.close()
                try? FileManager.default.removeItem(at: tempURL)
                self.sendError(connection: connection, status: "400 Bad Request", message: "Client disconnected before completing upload.")
            } else {
                self.readRemainingBody(
                    fileHandle: fileHandle,
                    totalBytesReceived: currentBytes,
                    targetLength: targetLength,
                    tempURL: tempURL,
                    contentType: contentType,
                    connection: connection
                )
            }
        }
    }

    private func sanitizeUploadedFileName(_ raw: String?) -> String {
        let fallback = "Imported_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(4)).adbk"
        guard let raw = raw, !raw.isEmpty else { return fallback }
        let base = (raw as NSString).lastPathComponent
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>'\r\n\0")
        let clean = base.components(separatedBy: invalid).joined(separator: "_")
        guard !clean.isEmpty, clean != ".", clean != ".." else { return fallback }
        let ext = (clean as NSString).pathExtension.lowercased()
        let finalName = (ext == "adbk" || ext == "zip") ? clean : "\(clean).adbk"

        let candidate = BackupEngine.shared.backupsDirectory.appendingPathComponent(finalName)
        if FileManager.default.fileExists(atPath: candidate.path) {
            let stem = (finalName as NSString).deletingPathExtension
            let finalExt = (finalName as NSString).pathExtension
            return "\(stem)_\(Int(Date().timeIntervalSince1970)).\(finalExt)"
        }
        return finalName
    }

    private func finalizeUpload(tempURL: URL, contentType: String, connection: NWConnection) {
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var finalDestURL = BackupEngine.shared.backupsDirectory.appendingPathComponent(sanitizeUploadedFileName(nil))

        if contentType.lowercased().contains("multipart/form-data"),
           let boundary = extractBoundary(from: contentType) {
            do {
                finalDestURL = try extractPayloadFromMultipartStreaming(sourceURL: tempURL, boundary: boundary)
            } catch {
                sendError(connection: connection, status: "500 Internal Server Error", message: "Failed to extract multipart data: \(error.localizedDescription)")
                return
            }
        } else {
            try? FileManager.default.removeItem(at: finalDestURL)
            do {
                try FileManager.default.copyItem(at: tempURL, to: finalDestURL)
            } catch {
                sendError(connection: connection, status: "500 Internal Server Error", message: "Failed to save upload.")
                return
            }
        }

        PosixHelper.shared.fixPermissions(at: finalDestURL.path)

        let redirectHtml = """
        <!DOCTYPE html>
        <html><head><meta http-equiv="refresh" content="1;url=/"><style>body{font-family:sans-serif;background:#0f172a;color:#f8fafc;padding:40px;text-align:center;}</style></head>
        <body><h2>Archive Uploaded Successfully!</h2><p>Saved as \(escapeHTML(finalDestURL.lastPathComponent)). Redirecting...</p></body></html>
        """
        sendResponse(connection: connection, status: "200 OK", contentType: "text/html; charset=utf-8", body: redirectHtml.data(using: .utf8)!)
    }

    private func extractBoundary(from contentType: String) -> String? {
        let parts = contentType.components(separatedBy: ";")
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().starts(with: "boundary=") {
                var b = String(trimmed.dropFirst("boundary=".count))
                if b.hasPrefix("\"") && b.hasSuffix("\"") && b.count >= 2 {
                    b = String(b.dropFirst().dropLast())
                }
                return b
            }
        }
        return nil
    }

    // Zero-OOM streaming multipart extractor: reads only header & trailer windows, then stream-copies payload in 256 KB chunks
    private func extractPayloadFromMultipartStreaming(sourceURL: URL, boundary: String) throws -> URL {
        let attrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let totalSize = (attrs[.size] as? UInt64) ?? 0
        guard totalSize > 0 else {
            throw NSError(domain: "LocalWebServer", code: 400, userInfo: [NSLocalizedDescriptionKey: "Empty upload."])
        }

        let reader = try FileHandle(forReadingFrom: sourceURL)
        defer { try? reader.close() }

        // 1. Inspect first 16 KB to locate multipart part header delimiter & original filename
        let headData = try reader.read(upToCount: 16_384) ?? Data()
        let delimiter = "\r\n\r\n".data(using: .utf8)!
        guard let headerEndRange = headData.range(of: delimiter) else {
            throw NSError(domain: "LocalWebServer", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid multipart payload."])
        }

        let partHeaderString = String(data: headData.subdata(in: 0..<headerEndRange.lowerBound), encoding: .utf8) ?? ""
        var parsedFilename: String? = nil
        if let fnRange = partHeaderString.range(of: "filename=\"") {
            let rest = partHeaderString[fnRange.upperBound...]
            if let endQuote = rest.firstIndex(of: "\"") {
                parsedFilename = String(rest[..<endQuote])
            }
        }

        let bodyStart = UInt64(headerEndRange.upperBound)

        // 2. Inspect last 8 KB to locate trailing "\r\n--<boundary>"
        let tailWindowSize: UInt64 = min(totalSize - bodyStart, 8192)
        let tailOffset = totalSize - tailWindowSize
        try reader.seek(toOffset: tailOffset)
        let tailData = try reader.read(upToCount: Int(tailWindowSize)) ?? Data()

        let endBoundary = ("\r\n--" + boundary).data(using: .utf8)!
        let bodyEnd: UInt64
        if let trailerRange = tailData.range(of: endBoundary, options: .backwards) {
            bodyEnd = tailOffset + UInt64(trailerRange.lowerBound)
        } else {
            bodyEnd = totalSize
        }

        guard bodyEnd >= bodyStart else {
            throw NSError(domain: "LocalWebServer", code: 400, userInfo: [NSLocalizedDescriptionKey: "Malformed multipart boundaries."])
        }

        // 3. Stream-copy payload bytes in 256 KB chunks to final destination
        let finalFileName = sanitizeUploadedFileName(parsedFilename)
        let destURL = BackupEngine.shared.backupsDirectory.appendingPathComponent(finalFileName)
        try? FileManager.default.removeItem(at: destURL)
        FileManager.default.createFile(atPath: destURL.path, contents: nil, attributes: nil)

        let writer = try FileHandle(forWritingTo: destURL)
        defer { try? writer.close() }

        try reader.seek(toOffset: bodyStart)
        var remaining = bodyEnd - bodyStart
        let copyChunkSize: UInt64 = 262_144

        while remaining > 0 {
            let toRead = Int(min(copyChunkSize, remaining))
            guard let chunk = try reader.read(upToCount: toRead), !chunk.isEmpty else { break }
            try writer.write(contentsOf: chunk)
            remaining -= UInt64(chunk.count)
        }

        return destURL
    }

    // MARK: - Responses & Error Handlers
    private func sendResponse(
        connection: NWConnection,
        status: String,
        contentType: String,
        extraHeaders: [String: String] = [:],
        body: Data
    ) {
        var header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (k, v) in extraHeaders {
            header += "\(k): \(v)\r\n"
        }
        header += "\r\n"

        var responseData = header.data(using: .utf8)!
        responseData.append(body)

        connection.send(content: responseData, completion: .contentProcessed({ [weak self] _ in
            self?.cleanupConnection(connection)
        }))
    }

    private func sendError(connection: NWConnection, status: String, message: String) {
        let body = "\(status)\r\n\(message)\r\n".data(using: .utf8)!
        sendResponse(connection: connection, status: status, contentType: "text/plain; charset=utf-8", body: body)
    }

    private func escapeHTML(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func getWiFiAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            var addr = ptr.pointee.ifa_addr.pointee

            if (flags & (IFF_UP|IFF_RUNNING|IFF_LOOPBACK)) == (IFF_UP|IFF_RUNNING) {
                if addr.sa_family == UInt8(AF_INET) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(&addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST) == 0 {
                        address = String(cString: hostname)
                        break
                    }
                }
            }
        }
        freeifaddrs(ifaddr)
        return address
    }
}
