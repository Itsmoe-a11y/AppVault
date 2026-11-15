import Foundation
import UIKit
import AuthenticationServices

// MARK: - Google Drive File Model
public struct GoogleDriveFile: Identifiable, Codable, Hashable {
    public let id: String
    public let name: String
    public let size: Int64
    public let modifiedTime: Date
    public let mimeType: String

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    public var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: modifiedTime)
    }
}

// MARK: - Google Drive Service
@MainActor
public final class GoogleDriveService: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    public static let shared = GoogleDriveService()

    @Published public var isAuthenticated: Bool = false
    @Published public var userEmail: String = ""
    @Published public var userName: String = ""
    @Published public var isAuthenticating: Bool = false
    @Published public var errorMessage: String? = nil

    // Configurable Google OAuth Credentials
    // Users can provide their own Client ID & Secret in Settings, or use default OAuth
    @Published public var customClientId: String {
        didSet { UserDefaults.standard.set(customClientId, forKey: "gdrive_client_id") }
    }
    @Published public var customClientSecret: String {
        didSet { UserDefaults.standard.set(customClientSecret, forKey: "gdrive_client_secret") }
    }

    private var accessToken: String? {
        get { UserDefaults.standard.string(forKey: "gdrive_access_token") }
        set { UserDefaults.standard.set(newValue, forKey: "gdrive_access_token") }
    }
    private var refreshToken: String? {
        get { UserDefaults.standard.string(forKey: "gdrive_refresh_token") }
        set { UserDefaults.standard.set(newValue, forKey: "gdrive_refresh_token") }
    }
    private var tokenExpiry: Date? {
        get { UserDefaults.standard.object(forKey: "gdrive_token_expiry") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "gdrive_token_expiry") }
    }

    private var authSession: ASWebAuthenticationSession?

    private override init() {
        self.customClientId = UserDefaults.standard.string(forKey: "gdrive_client_id") ?? "907297314544-h8p0uqqp8j68n2j9c58t4aevl5a5t8j3.apps.googleusercontent.com"
        self.customClientSecret = UserDefaults.standard.string(forKey: "gdrive_client_secret") ?? ""
        super.init()

        if let token = accessToken, !token.isEmpty {
            self.isAuthenticated = true
            self.userEmail = UserDefaults.standard.string(forKey: "gdrive_user_email") ?? ""
            self.userName = UserDefaults.standard.string(forKey: "gdrive_user_name") ?? ""
        }
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first {
            return window
        }
        return ASPresentationAnchor()
    }

    // MARK: - OAuth 2.0 PKCE Sign In
    public func signIn() {
        isAuthenticating = true
        errorMessage = nil

        let redirectURI = "dev.moe.appvault:/oauth2redirect"
        let scope = "https://www.googleapis.com/auth/drive.file https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile"
        let state = UUID().uuidString

        // PKCE Code Verifier and Challenge
        let verifier = generateCodeVerifier()
        let challenge = generateCodeChallenge(from: verifier)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: customClientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]

        guard let authURL = components.url else {
            isAuthenticating = false
            errorMessage = "Invalid OAuth URL"
            return
        }

        authSession = ASWebAuthenticationSession(url: authURL, callbackURLScheme: "dev.moe.appvault") { [weak self] callbackURL, error in
            Task { @MainActor in
                guard let self = self else { return }
                self.isAuthenticating = false

                if let error = error {
                    self.errorMessage = error.localizedDescription
                    return
                }

                guard let callbackURL = callbackURL,
                      let queryItems = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems,
                      let code = queryItems.first(where: { $0.name == "code" })?.value else {
                    self.errorMessage = "Missing authorization code from Google."
                    return
                }

                await self.exchangeCodeForTokens(code: code, verifier: verifier, redirectURI: redirectURI)
            }
        }

        authSession?.presentationContextProvider = self
        authSession?.prefersEphemeralWebBrowserSession = false
        authSession?.start()
    }

    // MARK: - Exchange Code for Tokens
    private func exchangeCodeForTokens(code: String, verifier: String, redirectURI: String) async {
        guard let tokenURL = URL(string: "https://oauth2.googleapis.com/token") else { return }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var bodyParams: [String: String] = [
            "client_id": customClientId,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI
        ]
        if !customClientSecret.isEmpty {
            bodyParams["client_secret"] = customClientSecret
        }

        let bodyString = bodyParams.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }.joined(separator: "&")
        request.httpBody = bodyString.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let err = String(data: data, encoding: .utf8) ?? "HTTP Error"
                self.errorMessage = "Token exchange failed: \(err)"
                return
            }

            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let access = json["access_token"] as? String {
                    self.accessToken = access
                }
                if let refresh = json["refresh_token"] as? String {
                    self.refreshToken = refresh
                }
                if let expiresIn = json["expires_in"] as? Double {
                    self.tokenExpiry = Date().addingTimeInterval(expiresIn)
                }

                self.isAuthenticated = true
                await self.fetchUserProfile()
            }
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    // MARK: - Refresh Access Token if Expired
    public func ensureValidToken() async throws -> String {
        if let expiry = tokenExpiry, Date() < expiry.addingTimeInterval(-60), let token = accessToken {
            return token
        }

        guard let refresh = refreshToken, !refresh.isEmpty else {
            throw NSError(domain: "GoogleDrive", code: 401, userInfo: [NSLocalizedDescriptionKey: "Please sign in to Google Drive."])
        }

        guard let tokenURL = URL(string: "https://oauth2.googleapis.com/token") else {
            throw NSError(domain: "GoogleDrive", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid token endpoint."])
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var bodyParams = [
            "client_id": customClientId,
            "refresh_token": refresh,
            "grant_type": "refresh_token"
        ]
        if !customClientSecret.isEmpty {
            bodyParams["client_secret"] = customClientSecret
        }

        let bodyString = bodyParams.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }.joined(separator: "&")
        request.httpBody = bodyString.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccess = json["access_token"] as? String else {
            throw NSError(domain: "GoogleDrive", code: 401, userInfo: [NSLocalizedDescriptionKey: "Failed to refresh Google token."])
        }

        self.accessToken = newAccess
        if let expiresIn = json["expires_in"] as? Double {
            self.tokenExpiry = Date().addingTimeInterval(expiresIn)
        }

        return newAccess
    }

    // MARK: - User Profile
    private func fetchUserProfile() async {
        guard let token = try? await ensureValidToken() else { return }
        guard let url = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo") else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        if let (data, _) = try? await URLSession.shared.data(for: request),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            self.userEmail = json["email"] as? String ?? ""
            self.userName = json["name"] as? String ?? ""
            UserDefaults.standard.set(self.userEmail, forKey: "gdrive_user_email")
            UserDefaults.standard.set(self.userName, forKey: "gdrive_user_name")
        }
    }

    public func signOut() {
        accessToken = nil
        refreshToken = nil
        tokenExpiry = nil
        userEmail = ""
        userName = ""
        isAuthenticated = false
        UserDefaults.standard.removeObject(forKey: "gdrive_user_email")
        UserDefaults.standard.removeObject(forKey: "gdrive_user_name")
    }

    // MARK: - Get or Create "AppVault Backups" Folder in Google Drive
    public func getOrCreateAppFolder() async throws -> String {
        let token = try await ensureValidToken()
        let query = "name = 'AppVault Backups' and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
        guard let queryEncoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let listURL = URL(string: "https://www.googleapis.com/drive/v3/files?q=\(queryEncoded)&fields=files(id,name)") else {
            throw NSError(domain: "GoogleDrive", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid query URL."])
        }

        var listReq = URLRequest(url: listURL)
        listReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: listReq)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let files = json["files"] as? [[String: Any]],
           let first = files.first,
           let folderId = first["id"] as? String {
            return folderId
        }

        // Create folder if not found
        guard let createURL = URL(string: "https://www.googleapis.com/drive/v3/files") else {
            throw NSError(domain: "GoogleDrive", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid URL."])
        }

        var createReq = URLRequest(url: createURL)
        createReq.httpMethod = "POST"
        createReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        createReq.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let metadata: [String: Any] = [
            "name": "AppVault Backups",
            "mimeType": "application/vnd.google-apps.folder"
        ]
        createReq.httpBody = try? JSONSerialization.data(withJSONObject: metadata)

        let (createData, res) = try await URLSession.shared.data(for: createReq)
        guard let http = res as? HTTPURLResponse, (http.statusCode == 200 || http.statusCode == 201),
              let createJson = try? JSONSerialization.jsonObject(with: createData) as? [String: Any],
              let newId = createJson["id"] as? String else {
            throw NSError(domain: "GoogleDrive", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to create folder in Google Drive."])
        }

        return newId
    }

    // MARK: - Resumable Upload Session (Initiation)
    public func initiateResumableUpload(
        fileName: String,
        mimeType: String = "application/x-gzip"
    ) async throws -> URL {
        let token = try await ensureValidToken()
        let folderID = try await getOrCreateAppFolder()

        guard let uploadURL = URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable") else {
            throw NSError(domain: "GoogleDrive", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid upload URL."])
        }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(mimeType, forHTTPHeaderField: "X-Upload-Content-Type")

        let metadata: [String: Any] = [
            "name": fileName,
            "parents": [folderID]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: metadata)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let locationString = http.allHeaderFields["Location"] as? String ?? http.allHeaderFields["location"] as? String,
              let sessionURL = URL(string: locationString) else {
            throw NSError(domain: "GoogleDrive", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to initiate resumable upload session with Google Drive."])
        }

        return sessionURL
    }

    // MARK: - Upload Chunk
    public func uploadChunk(
        sessionURL: URL,
        chunkData: Data,
        startOffset: Int64,
        isFinal: Bool,
        totalFileSize: Int64?
    ) async throws -> (isComplete: Bool, fileID: String?) {
        var request = URLRequest(url: sessionURL)
        request.httpMethod = "PUT"
        request.httpBody = chunkData

        let endOffset = startOffset + Int64(chunkData.count) - 1
        let totalStr = totalFileSize != nil ? "\(totalFileSize!)" : (isFinal ? "\(endOffset + 1)" : "*")
        request.setValue("bytes \(startOffset)-\(endOffset)/\(totalStr)", forHTTPHeaderField: "Content-Range")
        request.setValue("\(chunkData.count)", forHTTPHeaderField: "Content-Length")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "GoogleDrive", code: 500, userInfo: [NSLocalizedDescriptionKey: "No response from Google Drive."])
        }

        if http.statusCode == 200 || http.statusCode == 201 {
            // Upload Finished!
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let fileID = json["id"] as? String {
                return (true, fileID)
            }
            return (true, nil)
        } else if http.statusCode == 308 {
            // Resume Incomplete (Chunk received successfully)
            return (false, nil)
        } else {
            let msg = String(data: data, encoding: .utf8) ?? "Upload chunk error \(http.statusCode)"
            throw NSError(domain: "GoogleDrive", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    // MARK: - List Cloud Backups
    public func fetchCloudBackups() async throws -> [GoogleDriveFile] {
        let token = try await ensureValidToken()
        let folderID = try await getOrCreateAppFolder()

        let query = "'\(folderID)' in parents and trashed = false"
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let listURL = URL(string: "https://www.googleapis.com/drive/v3/files?q=\(encodedQuery)&fields=files(id,name,size,modifiedTime,mimeType)&orderBy=modifiedTime desc") else {
            return []
        }

        var request = URLRequest(url: listURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fileList = json["files"] as? [[String: Any]] else {
            return []
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return fileList.compactMap { item in
            guard let id = item["id"] as? String,
                  let name = item["name"] as? String else { return nil }

            let size = Int64(item["size"] as? String ?? "0") ?? 0
            let timeString = item["modifiedTime"] as? String ?? ""
            let date = isoFormatter.date(from: timeString) ?? Date()
            let mime = item["mimeType"] as? String ?? ""

            return GoogleDriveFile(id: id, name: name, size: size, modifiedTime: date, mimeType: mime)
        }
    }

    // MARK: - Download Cloud Backup to File
    public func downloadFile(
        file: GoogleDriveFile,
        destinationURL: URL,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        let token = try await ensureValidToken()
        guard let downloadURL = URL(string: "https://www.googleapis.com/drive/v3/files/\(file.id)?alt=media") else {
            throw NSError(domain: "GoogleDrive", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid download URL."])
        }

        var request = URLRequest(url: downloadURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (tempURL, res) = try await URLSession.shared.download(for: request)
        guard let http = res as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "GoogleDrive", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to download file from Google Drive."])
        }

        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
        PosixHelper.shared.fixPermissions(at: destinationURL.path)
    }

    // MARK: - Delete Cloud Backup
    public func deleteCloudBackup(fileID: String) async throws {
        let token = try await ensureValidToken()
        guard let deleteURL = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)") else { return }

        var request = URLRequest(url: deleteURL)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        _ = try await URLSession.shared.data(for: request)
    }

    // MARK: - PKCE Utilities
    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        guard let data = verifier.data(using: .utf8) else { return "" }
        var digest = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// CommonCrypto bridging declaration
import CommonCrypto
