import Foundation
import Network
import UIKit

public final class LocalWebServer: ObservableObject {
    public static let shared = LocalWebServer()

    @Published public var isRunning: Bool = false
    @Published public var serverURLString: String = ""
    @Published public var connectionStatus: String = "Stopped"

    private var listener: NWListener?
    private let port: NWEndpoint.Port = 8080
    private var activeConnections: Set<NWConnection> = []
    private let connectionQueue = DispatchQueue(label: "dev.moe.appvault.webserver.connection", qos: .userInitiated)

    // Limits for security and stability
    private let maxHeaderSize = 65_536 // 64 KB max HTTP header
    private let maxUploadSize: Int64 = 10 * 1024 * 1024 * 1024 // 10 GB max upload file size

    private init() {}

    // MARK: - Start Server
    public func start() {
        guard !isRunning else { return }

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
            for connection in self.activeConnections {
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

    // MARK: - Connection Handler & State Management
    private func handleConnection(_ connection: NWConnection) {
        connectionQueue.async {
            self.activeConnections.insert(connection)
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
            self.activeConnections.remove(connection)
        }
        connection.cancel()
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

            // Check if HTTP header delimiter \r\n\r\n is reached
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
                // Continue reading header
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

        if method == "GET" && (fullPath == "/" || fullPath.starts(with: "/?")) {
            serveDashboard(connection: connection)
        } else if method == "GET" && fullPath.starts(with: "/download") {
            serveDownload(path: fullPath, connection: connection)
        } else if method == "POST" && fullPath.starts(with: "/upload") {
            let contentLength = Int64(headers["content-length"] ?? "0") ?? 0
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

    // MARK: - Dashboard HTML
    private func serveDashboard(connection: NWConnection) {
        let backupsDir = BackupEngine.shared.backupsDirectory
        let backups = (try? FileManager.default.contentsOfDirectory(at: backupsDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var filesListHtml = ""

        for file in backups where file.pathExtension == "adbk" || file.pathExtension == "zip" {
            let rawName = file.lastPathComponent
            let escapedName = escapeHTML(rawName)
            let encodedParam = rawName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? rawName

            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)

            filesListHtml += """
            <tr>
                <td><strong>\(escapedName)</strong></td>
                <td>\(sizeStr)</td>
                <td><a href="/download?file=\(encodedParam)" class="btn download-btn">Download</a></td>
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
                .container { max-width: 820px; margin: 0 auto; }
                .header { display: flex; align-items: center; justify-content: space-between; border-bottom: 1px solid #334155; padding-bottom: 16px; margin-bottom: 24px; }
                h1 { margin: 0; color: #38bdf8; font-size: 22px; font-weight: 700; }
                .badge { background: #15803d; color: #86efac; font-size: 12px; font-weight: 600; padding: 4px 10px; border-radius: 9999px; }
                .card { background: #1e293b; border-radius: 12px; padding: 20px; margin-bottom: 24px; border: 1px solid #334155; }
                table { width: 100%; border-collapse: collapse; margin-top: 12px; }
                th, td { text-align: left; padding: 12px; border-bottom: 1px solid #334155; }
                th { color: #94a3b8; font-size: 12px; text-transform: uppercase; letter-spacing: 0.05em; }
                .btn { display: inline-block; padding: 8px 16px; border-radius: 6px; text-decoration: none; font-weight: 600; font-size: 13px; }
                .download-btn { background: #0284c7; color: white; transition: background 0.15s; }
                .download-btn:hover { background: #0369a1; }
                .upload-box { border: 2px dashed #475569; border-radius: 8px; padding: 28px; text-align: center; cursor: pointer; display: block; transition: border-color 0.2s; }
                .upload-box:hover { border-color: #38bdf8; }
                input[type=file] { display: none; }
            </style>
        </head>
        <body>
            <div class="container">
                <div class="header">
                    <h1>AppVault Local Wi-Fi Manager</h1>
                    <span class="badge">● Live Secure Connection</span>
                </div>
                <div class="card">
                    <h3 style="margin-top:0;">Upload Backup Archive (.adbk / .zip)</h3>
                    <form action="/upload" method="post" enctype="multipart/form-data">
                        <label class="upload-box" id="drop-zone">
                            <p style="margin:0; font-size: 14px; color: #cbd5e1;">Click here or drag-and-drop a backup file to import to this device</p>
                            <input type="file" name="file" onchange="this.form.submit()">
                        </label>
                    </form>
                </div>
                <div class="card">
                    <h3 style="margin-top:0;">On-Device Backups</h3>
                    <table>
                        <thead>
                            <tr><th>Archive Name</th><th>Size</th><th>Action</th></tr>
                        </thead>
                        <tbody>
                            \(filesListHtml)
                        </tbody>
                    </table>
                </div>
            </div>
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

    // MARK: - Serve File Download with Strict Path Traversal Protection & Zero OOM Streaming
    private func serveDownload(path: String, connection: NWConnection) {
        guard let urlComponents = URLComponents(string: path),
              let requestedFile = urlComponents.queryItems?.first(where: { $0.name == "file" })?.value else {
            sendError(connection: connection, status: "400 Bad Request", message: "Missing file parameter.")
            return
        }

        // 1. Strict Path Traversal Defense (CWE-22)
        // Disallow path traversal indicators
        if requestedFile.contains("..") || requestedFile.contains("/") || requestedFile.contains("\\") || requestedFile.contains("\0") {
            NSLog("[LocalWebServer] Security Alert: Path traversal attempt blocked: %@", requestedFile)
            sendError(connection: connection, status: "403 Forbidden", message: "Access denied: Invalid file path.")
            return
        }

        let sanitizedName = (requestedFile as NSString).lastPathComponent
        guard !sanitizedName.isEmpty, sanitizedName != "." && sanitizedName != ".." else {
            sendError(connection: connection, status: "400 Bad Request", message: "Invalid filename.")
            return
        }

        let backupsDir = BackupEngine.shared.backupsDirectory.standardizedFileURL
        let candidateURL = backupsDir.appendingPathComponent(sanitizedName).standardizedFileURL

        // Verify the file resides strictly inside backupsDirectory
        guard candidateURL.path.hasPrefix(backupsDir.path) else {
            NSLog("[LocalWebServer] Security Alert: File escape attempt blocked: %@", candidateURL.path)
            sendError(connection: connection, status: "403 Forbidden", message: "Access denied: Path outside root.")
            return
        }

        // Verify file exists and is regular file
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidateURL.path, isDirectory: &isDir), !isDir.boolValue else {
            sendError(connection: connection, status: "404 Not Found", message: "File not found.")
            return
        }

        guard let fileAttributes = try? FileManager.default.attributesOfItem(atPath: candidateURL.path),
              let fileSize = fileAttributes[.size] as? Int64 else {
            sendError(connection: connection, status: "500 Internal Server Error", message: "Cannot read file attributes.")
            return
        }

        // Stream file without loading entire payload into RAM
        guard let fileHandle = try? FileHandle(forReadingFrom: candidateURL) else {
            sendError(connection: connection, status: "500 Internal Server Error", message: "Failed to open file for streaming.")
            return
        }

        let header = "HTTP/1.1 200 OK\r\n" +
                     "Content-Type: application/octet-stream\r\n" +
                     "Content-Length: \(fileSize)\r\n" +
                     "Content-Disposition: attachment; filename=\"\(sanitizedName)\"\r\n" +
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
        let chunkSize = 131_072 // 128 KB chunk
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

    // MARK: - Handle Streaming Upload to Disk
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

        if totalBytesReceived >= contentLength && contentLength > 0 {
            try? fileHandle.close()
            finalizeUpload(tempURL: tempUploadURL, contentType: contentType, connection: connection)
            return
        }

        // Read remaining body chunks from connection
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

        connection.receive(minimumIncompleteLength: 1, maximumLength: 131072) { [weak self] content, _, isComplete, error in
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

            if currentBytes >= targetLength || (isComplete && targetLength <= 0) {
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

    private func finalizeUpload(tempURL: URL, contentType: String, connection: NWConnection) {
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let timestamp = Int(Date().timeIntervalSince1970)
        let finalFileName = "Imported_\(timestamp).adbk"
        let destURL = BackupEngine.shared.backupsDirectory.appendingPathComponent(finalFileName)

        // Extract boundary if multipart/form-data
        if contentType.contains("multipart/form-data"),
           let boundary = extractBoundary(from: contentType) {
            do {
                try extractPayloadFromMultipart(sourceURL: tempURL, destinationURL: destURL, boundary: boundary)
            } catch {
                sendError(connection: connection, status: "500 Internal Server Error", message: "Failed to extract multipart data: \(error.localizedDescription)")
                return
            }
        } else {
            // Direct binary upload
            try? FileManager.default.removeItem(at: destURL)
            do {
                try FileManager.default.copyItem(at: tempURL, to: destURL)
            } catch {
                sendError(connection: connection, status: "500 Internal Server Error", message: "Failed to save upload.")
                return
            }
        }

        PosixHelper.shared.fixPermissions(at: destURL.path)

        let redirectHtml = """
        <!DOCTYPE html>
        <html><head><meta http-equiv="refresh" content="2;url=/"><style>body{font-family:sans-serif;background:#0f172a;color:#f8fafc;padding:40px;text-align:center;}</style></head>
        <body><h2>Archive Uploaded Successfully!</h2><p>Redirecting to dashboard...</p></body></html>
        """
        sendResponse(connection: connection, status: "200 OK", contentType: "text/html; charset=utf-8", body: redirectHtml.data(using: .utf8)!)
    }

    private func extractBoundary(from contentType: String) -> String? {
        let parts = contentType.components(separatedBy: ";")
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().starts(with: "boundary=") {
                var b = String(trimmed.dropFirst("boundary=".count))
                if b.hasPrefix("\"") && b.hasSuffix("\"") {
                    b = String(b.dropFirst().dropLast())
                }
                return b
            }
        }
        return nil
    }

    private func extractPayloadFromMultipart(sourceURL: URL, destinationURL: URL, boundary: String) throws {
        // Find multipart header end and trailing boundary
        guard let data = try? Data(contentsOf: sourceURL) else {
            throw NSError(domain: "LocalWebServer", code: 500, userInfo: [NSLocalizedDescriptionKey: "Cannot read temp upload file."])
        }

        let delimiter = "\r\n\r\n".data(using: .utf8)!
        guard let headerEndRange = data.range(of: delimiter) else {
            throw NSError(domain: "LocalWebServer", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid multipart payload."])
        }

        let bodyStart = headerEndRange.upperBound
        let endBoundary = ("\r\n--" + boundary).data(using: .utf8)!

        let bodyEnd: Int
        if let trailerRange = data.range(of: endBoundary, options: .backwards, in: bodyStart..<data.count) {
            bodyEnd = trailerRange.lowerBound
        } else {
            bodyEnd = data.count
        }

        let filePayload = data.subdata(in: bodyStart..<bodyEnd)
        try filePayload.write(to: destinationURL)
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

    // MARK: - IP Address Discovery
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
