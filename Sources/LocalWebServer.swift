import Foundation
import Network
import UIKit

@MainActor
public final class LocalWebServer: ObservableObject {
    public static let shared = LocalWebServer()

    @Published public var isRunning: Bool = false
    @Published public var serverURLString: String = ""
    @Published public var connectionStatus: String = "Stopped"

    private var listener: NWListener?
    private let port: NWEndpoint.Port = 8080

    private override init() {
        super.init()
    }

    // MARK: - Start Server
    public func start() {
        guard !isRunning else { return }

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: port)

            listener?.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self = self else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        let ip = self.getWiFiAddress() ?? "localhost"
                        self.serverURLString = "http://\(ip):\(self.port.rawValue)"
                        self.connectionStatus = "Running at \(self.serverURLString)"
                    case .failed(let error):
                        self.isRunning = false
                        self.connectionStatus = "Failed: \(error.localizedDescription)"
                    case .cancelled:
                        self.isRunning = false
                        self.connectionStatus = "Stopped"
                    default:
                        break
                    }
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            listener?.start(queue: .global(qos: .userInitiated))
        } catch {
            connectionStatus = "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Stop Server
    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        serverURLString = ""
        connectionStatus = "Stopped"
    }

    // MARK: - Connection Handler
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receiveRequest(on: connection)
    }

    private func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, _ in
            guard let self = self, let data = content, !data.isEmpty else {
                connection.cancel()
                return
            }

            let requestStr = String(data: data, encoding: .utf8) ?? ""
            let lines = requestStr.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else {
                connection.cancel()
                return
            }

            let parts = requestLine.components(separatedBy: " ")
            let method = parts.first ?? "GET"
            let path = parts.count > 1 ? parts[1] : "/"

            if method == "GET" && path == "/" {
                self.serveDashboard(connection: connection)
            } else if method == "GET" && path.starts(with: "/download") {
                self.serveDownload(path: path, connection: connection)
            } else if method == "POST" && path.starts(with: "/upload") {
                self.handleUpload(requestData: data, connection: connection)
            } else {
                self.sendResponse(connection: connection, status: "404 Not Found", contentType: "text/plain", body: "Not Found".data(using: .utf8)!)
            }
        }
    }

    // MARK: - Web Dashboard HTML
    private func serveDashboard(connection: NWConnection) {
        let backups = (try? FileManager.default.contentsOfDirectory(at: BackupEngine.shared.backupsDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var filesListHtml = ""

        for file in backups where file.pathExtension == "adbk" || file.pathExtension == "zip" {
            let name = file.lastPathComponent
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            filesListHtml += """
            <tr>
                <td><strong>\(name)</strong></td>
                <td>\(sizeStr)</td>
                <td><a href="/download?file=\(name)" class="btn download-btn">Download</a></td>
            </tr>
            """
        }

        if filesListHtml.isEmpty {
            filesListHtml = "<tr><td colspan='3' style='text-align:center; color:#888;'>No backups on device yet.</td></tr>"
        }

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>AppVault Wi-Fi Manager</title>
            <style>
                body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; background: #0f172a; color: #f8fafc; margin: 0; padding: 24px; }
                .container { max-width: 800px; margin: 0 auto; }
                .header { display: flex; align-items: center; justify-content: space-between; border-bottom: 1px solid #334155; padding-bottom: 16px; margin-bottom: 24px; }
                h1 { margin: 0; color: #38bdf8; font-size: 24px; }
                .card { background: #1e293b; border-radius: 12px; padding: 20px; margin-bottom: 24px; border: 1px solid #334155; }
                table { width: 100%; border-collapse: collapse; margin-top: 12px; }
                th, td { text-align: left; padding: 12px; border-bottom: 1px solid #334155; }
                th { color: #94a3b8; font-size: 13px; text-transform: uppercase; }
                .btn { display: inline-block; padding: 8px 16px; border-radius: 6px; text-decoration: none; font-weight: bold; font-size: 13px; }
                .download-btn { background: #0284c7; color: white; }
                .upload-box { border: 2px dashed #475569; border-radius: 8px; padding: 32px; text-align: center; cursor: pointer; }
                .upload-box:hover { border-color: #38bdf8; }
                input[type=file] { display: none; }
            </style>
        </head>
        <body>
            <div class="container">
                <div class="header">
                    <h1>AppVault Local Wi-Fi Manager</h1>
                    <span style="color:#22c55e;">● Live Connection</span>
                </div>
                <div class="card">
                    <h3>Upload Backup (.adbk / .zip)</h3>
                    <form action="/upload" method="post" enctype="multipart/form-data">
                        <label class="upload-box" id="drop-zone">
                            <p>Click here or drag-and-drop a backup file to send to this iPhone</p>
                            <input type="file" name="file" onchange="this.form.submit()">
                        </label>
                    </form>
                </div>
                <div class="card">
                    <h3>On-Device Backups</h3>
                    <table>
                        <thead>
                            <tr><th>File Name</th><th>Size</th><th>Action</th></tr>
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

        sendResponse(connection: connection, status: "200 OK", contentType: "text/html; charset=utf-8", body: html.data(using: .utf8)!)
    }

    // MARK: - Serve File Download
    private func serveDownload(path: String, connection: NWConnection) {
        guard let urlComponents = URLComponents(string: path),
              let fileName = urlComponents.queryItems?.first(where: { $0.name == "file" })?.value else {
            sendResponse(connection: connection, status: "400 Bad Request", contentType: "text/plain", body: "Missing file parameter".data(using: .utf8)!)
            return
        }

        let fileURL = BackupEngine.shared.backupsDirectory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: fileURL) else {
            sendResponse(connection: connection, status: "404 Not Found", contentType: "text/plain", body: "File not found".data(using: .utf8)!)
            return
        }

        sendResponse(
            connection: connection,
            status: "200 OK",
            contentType: "application/octet-stream",
            extraHeaders: ["Content-Disposition": "attachment; filename=\"\(fileName)\""],
            body: data
        )
    }

    // MARK: - Handle File Upload
    private func handleUpload(requestData: Data, connection: NWConnection) {
        // Simple multipart body extraction
        let timestamp = Int(Date().timeIntervalSince1970)
        let filename = "Imported_\(timestamp).adbk"
        let dest = BackupEngine.shared.backupsDirectory.appendingPathComponent(filename)

        // Find boundary and extract file payload
        let raw = requestData
        if let headerEnd = raw.range(of: "\r\n\r\n".data(using: .utf8)!) {
            let bodyData = raw.subdata(in: headerEnd.upperBound..<raw.count)
            try? bodyData.write(to: dest)
            PosixHelper.shared.fixPermissions(at: dest.path)
        }

        let redirectHtml = "<html><head><meta http-equiv='refresh' content='1;url=/'></head><body>Upload received! Redirecting...</body></html>"
        sendResponse(connection: connection, status: "200 OK", contentType: "text/html", body: redirectHtml.data(using: .utf8)!)
    }

    private func sendResponse(connection: NWConnection, status: String, contentType: String, extraHeaders: [String: String] = [:], body: Data) {
        var header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (k, v) in extraHeaders {
            header += "\(k): \(v)\r\n"
        }
        header += "\r\n"

        var responseData = header.data(using: .utf8)!
        responseData.append(body)

        connection.send(content: responseData, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
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
