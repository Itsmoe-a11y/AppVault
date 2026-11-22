import Foundation
import UIKit
import AuthenticationServices
import CommonCrypto

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

// MARK: - Download Progress Tracking Helper (Validates HTTP Status & Avoids Saving Error JSON)
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private let lock = NSLock()

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func setContinuation(_ continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    private func resumeOnce(with result: Result<URL, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        guard let cont = cont else { return }
        switch result {
        case .success(let url): cont.resume(returning: url)
        case .failure(let err): cont.resume(throwing: err)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesExpectedToWrite > 0 {
            let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            DispatchQueue.main.async {
                self.onProgress(min(max(fraction, 0.0), 1.0))
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let errBody = (try? String(contentsOf: location, encoding: .utf8)) ?? "HTTP \(http.statusCode)"
            resumeOnce(with: .failure(NSError(
                domain: "GoogleDrive",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Google Drive download failed (HTTP \(http.statusCode)): \(errBody.prefix(200))"]
            )))
            return
        }

        let tempDir = FileManager.default.temporaryDirectory
        let destination = tempDir.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            resumeOnce(with: .success(destination))
        } catch {
            resumeOnce(with: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            resumeOnce(with: .failure(error))
        }
    }
}

// MARK: - Google Drive Service (1-Tap PKCE Sign-In + Verified Token Refresh + Resumable Streaming)
// MARK: - No-Redirect URLSession Delegate (Prevents iOS 16 URLSession from mistreating HTTP 308 Resume Incomplete as a redirect)
private final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

@MainActor
public final class GoogleDriveService: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    public static let shared = GoogleDriveService()

    // Public iOS OAuth 2.0 Client ID (PKCE, no client secret required).
    // Set once by the app maintainer so end users sign in with 1 tap via Google's Email + Password + 2FA Safari sheet.
    public static let bundledDefaultClientId = "890695287693-eq0tg23dgr9f98uh8dm4ubp6nctc6iph.apps.googleusercontent.com"

    private static let keychainService = "dev.moe.appvault.gdrive"
    private static let keychainRefreshTokenAccount = "oauth_refresh_token"
    private static let keychainAccessTokenAccount = "oauth_access_token"
    private static let keychainClientSecretAccount = "oauth_client_secret"

    @Published public var isAuthenticated: Bool = false
    @Published public var userEmail: String = ""
    @Published public var userName: String = ""
    @Published public var isAuthenticating: Bool = false
    @Published public var errorMessage: String? = nil

    // Optional power-user override; falls back to bundledDefaultClientId for 1-tap sign-in
    @Published public var customClientId: String {
        didSet { UserDefaults.standard.set(customClientId, forKey: "gdrive_client_id") }
    }
    @Published public var customClientSecret: String {
        didSet {
            if customClientSecret.isEmpty {
                KeychainService.shared.deletePassword(service: Self.keychainService, account: Self.keychainClientSecretAccount)
            } else {
                KeychainService.shared.savePassword(service: Self.keychainService, account: Self.keychainClientSecretAccount, password: customClientSecret)
            }
        }
    }
    @Published public var targetFolderName: String {
        didSet {
            UserDefaults.standard.set(targetFolderName, forKey: "gdrive_target_folder_name")
        }
    }

    public var hasBundledDefaultClientId: Bool {
        let trimmed = Self.bundledDefaultClientId.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.contains("__APPVAULT_GOOGLE_CLIENT_ID__") && trimmed.hasSuffix(".apps.googleusercontent.com")
    }

    public var isUsingRcloneClientOverride: Bool {
        let override = customClientId.trimmingCharacters(in: .whitespacesAndNewlines)
        return override == RcloneHelper.rcloneDefaultClientId
    }

    /// Client ID used for API token refresh (respects rclone imported tokens when signed in via rclone).
    public var effectiveClientId: String {
        let override = customClientId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty { return override }
        return hasBundledDefaultClientId ? Self.bundledDefaultClientId : ""
    }

    /// Client ID used for interactive iOS browser sign-in (never lets a stale rclone Desktop Client ID hijack AppVault OAuth).
    public var interactiveSignInClientId: String {
        let override = customClientId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty && override != RcloneHelper.rcloneDefaultClientId {
            return override
        }
        return hasBundledDefaultClientId ? Self.bundledDefaultClientId : ""
    }

    public var canStartOneTapSignIn: Bool {
        !interactiveSignInClientId.isEmpty
    }

    public func clearCustomOAuthOverride() {
        customClientId = ""
        customClientSecret = ""
    }

    // In-memory caching with Keychain backed persistent storage
    private var _cachedAccessToken: String?
    private var accessToken: String? {
        get {
            if let cached = _cachedAccessToken { return cached }
            let loaded = KeychainService.shared.loadPassword(service: Self.keychainService, account: Self.keychainAccessTokenAccount)
            _cachedAccessToken = loaded
            return loaded
        }
        set {
            _cachedAccessToken = newValue
            if let value = newValue {
                KeychainService.shared.savePassword(service: Self.keychainService, account: Self.keychainAccessTokenAccount, password: value)
            } else {
                KeychainService.shared.deletePassword(service: Self.keychainService, account: Self.keychainAccessTokenAccount)
            }
        }
    }

    private var _cachedRefreshToken: String?
    private var refreshToken: String? {
        get {
            if let cached = _cachedRefreshToken { return cached }
            let loaded = KeychainService.shared.loadPassword(service: Self.keychainService, account: Self.keychainRefreshTokenAccount)
            _cachedRefreshToken = loaded
            return loaded
        }
        set {
            _cachedRefreshToken = newValue
            if let value = newValue {
                KeychainService.shared.savePassword(service: Self.keychainService, account: Self.keychainRefreshTokenAccount, password: value)
            } else {
                KeychainService.shared.deletePassword(service: Self.keychainService, account: Self.keychainRefreshTokenAccount)
            }
        }
    }

    private var tokenExpiry: Date? {
        get { UserDefaults.standard.object(forKey: "gdrive_token_expiry") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "gdrive_token_expiry") }
    }

    private var authSession: ASWebAuthenticationSession?

    // Pending PKCE state for External Browser sign-in fallback (iOS 16.0 WebKit workaround)
    private var pendingExternalVerifier: String?
    private var pendingExternalState: String?
    private var pendingExternalRedirectURI: String?
    private var pendingExternalClientId: String?

    /// Dedicated API session with strict timeouts so calls never hang silently on "Initializing".
    private lazy var apiSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 90
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    private let noRedirectDelegate = NoRedirectSessionDelegate()

    // Google OAuth 2.0 Device Flow state (100% WebKit-free login for jailbroken iOS 16 devices)
    @Published public var deviceUserCode: String? = nil
    @Published public var deviceVerificationURL: String? = nil
    @Published public var isPollingDeviceFlow: Bool = false
    private var deviceFlowTask: Task<Void, Never>? = nil

    /// Dedicated upload session with NoRedirectSessionDelegate so HTTP 308 Resume Incomplete
    /// is always delivered directly to uploadChunk instead of triggering redirect handling on iOS 16.
    private lazy var uploadSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 600
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg, delegate: noRedirectDelegate, delegateQueue: nil)
    }()

    private override init() {
        let savedClientId = UserDefaults.standard.string(forKey: "gdrive_client_id") ?? ""
        if savedClientId.contains("h8p0uqqp8j68n2j9c58t4aevl5a5t8j3") {
            self.customClientId = ""
            UserDefaults.standard.removeObject(forKey: "gdrive_client_id")
        } else {
            self.customClientId = savedClientId
        }

        // Migrate legacy plaintext client secret from UserDefaults to Keychain
        if let legacySecret = UserDefaults.standard.string(forKey: "gdrive_client_secret"), !legacySecret.isEmpty {
            KeychainService.shared.savePassword(service: Self.keychainService, account: Self.keychainClientSecretAccount, password: legacySecret)
            UserDefaults.standard.removeObject(forKey: "gdrive_client_secret")
            self.customClientSecret = legacySecret
        } else {
            self.customClientSecret = KeychainService.shared.loadPassword(service: Self.keychainService, account: Self.keychainClientSecretAccount) ?? ""
        }

        let savedFolder = UserDefaults.standard.string(forKey: "gdrive_target_folder_name") ?? "AppVault Backups"
        self.targetFolderName = savedFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "AppVault Backups" : savedFolder

        super.init()

        migrateTokensFromUserDefaultsIfNeeded()

        if (accessToken != nil && !accessToken!.isEmpty) || (refreshToken != nil && !refreshToken!.isEmpty) {
            self.isAuthenticated = true
            self.userEmail = UserDefaults.standard.string(forKey: "gdrive_user_email") ?? ""
            self.userName = UserDefaults.standard.string(forKey: "gdrive_user_name") ?? ""
        }
    }

    private func migrateTokensFromUserDefaultsIfNeeded() {
        if let legacyRefresh = UserDefaults.standard.string(forKey: "gdrive_refresh_token"), !legacyRefresh.isEmpty {
            self.refreshToken = legacyRefresh
            UserDefaults.standard.removeObject(forKey: "gdrive_refresh_token")
        }
        if let legacyAccess = UserDefaults.standard.string(forKey: "gdrive_access_token"), !legacyAccess.isEmpty {
            self.accessToken = legacyAccess
            UserDefaults.standard.removeObject(forKey: "gdrive_access_token")
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

    // MARK: - 1-Tap OAuth 2.0 PKCE Sign In (Google Email + Password + 2FA via Native Safari Sheet)
    public func signIn(ephemeral: Bool = false) {
        if isUsingRcloneClientOverride { clearCustomOAuthOverride() }
        let clientId = interactiveSignInClientId
        DebugLogger.shared.log("OAuth", "Starting ASWebAuthenticationSession sign-in (ephemeral=\(ephemeral), clientPrefix=\(clientId.prefix(12))...)")
        guard !clientId.isEmpty else {
            errorMessage = "Google OAuth Client ID is not configured yet. Set a default iOS Client ID in this build or enter one under Advanced OAuth Settings."
            return
        }

        isAuthenticating = true
        errorMessage = nil

        let redirectURI: String
        let callbackScheme: String
        if clientId.hasSuffix(".apps.googleusercontent.com") {
            let prefix = clientId.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
            callbackScheme = "com.googleusercontent.apps.\(prefix)"
            redirectURI = "\(callbackScheme):/oauth2redirect"
        } else {
            callbackScheme = "dev.moe.appvault"
            redirectURI = "dev.moe.appvault:/oauth2redirect"
        }

        let scope = "https://www.googleapis.com/auth/drive.file https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile"
        let expectedState = UUID().uuidString

        guard let verifier = generateCodeVerifier(),
              let challenge = generateCodeChallenge(from: verifier) else {
            isAuthenticating = false
            errorMessage = "Failed to generate PKCE cryptographic material."
            return
        }

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: expectedState),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "select_account consent")
        ]

        guard let authURL = components.url else {
            isAuthenticating = false
            errorMessage = "Invalid OAuth URL."
            return
        }

        authSession = ASWebAuthenticationSession(url: authURL, callbackURLScheme: callbackScheme) { [weak self] callbackURL, error in
            Task { @MainActor in
                guard let self = self else { return }
                self.isAuthenticating = false

                if let error = error {
                    let nsError = error as NSError
                    if nsError.domain == ASWebAuthenticationSessionErrorDomain && nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        return
                    }
                    DebugLogger.shared.log("OAuth", "ASWebAuthenticationSession failed: \(error.localizedDescription)", level: .error)
                    self.errorMessage = error.localizedDescription
                    return
                }

                guard let callbackURL = callbackURL,
                      let queryItems = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems else {
                    self.errorMessage = "Invalid OAuth callback from Google."
                    return
                }

                // Verify OAuth state parameter to prevent CSRF / session-fixation attacks
                let returnedState = queryItems.first(where: { $0.name == "state" })?.value
                guard returnedState == expectedState else {
                    self.errorMessage = "OAuth state mismatch. Please try signing in again."
                    return
                }

                guard let code = queryItems.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
                    let errDesc = queryItems.first(where: { $0.name == "error" })?.value ?? "Missing authorization code"
                    self.errorMessage = "Google sign-in failed: \(errDesc)"
                    return
                }

                await self.exchangeCodeForTokens(code: code, verifier: verifier, redirectURI: redirectURI, clientId: clientId)
            }
        }

        authSession?.presentationContextProvider = self
        authSession?.prefersEphemeralWebBrowserSession = ephemeral
        authSession?.start()
    }

    // MARK: - External Browser OAuth 2.0 PKCE Sign In (iOS 16.0 WebKit Workaround)
    /// Opens full Safari / default browser outside ASWebAuthenticationSession and completes via AppVaultApp.onOpenURL.
    public func signInWithExternalBrowser() {
        guard let built = buildOAuthRequest() else { return }
        pendingExternalVerifier = built.verifier
        pendingExternalState = built.state
        pendingExternalRedirectURI = built.redirectURI
        pendingExternalClientId = built.clientId
        isAuthenticating = true
        errorMessage = nil

        DebugLogger.shared.log("OAuth", "Opening external browser for Google OAuth (scheme=\(built.callbackScheme))")
        UIApplication.shared.open(built.authURL, options: [:]) { [weak self] success in
            if !success {
                Task { @MainActor in
                    self?.isAuthenticating = false
                    self?.errorMessage = "Could not open external browser for Google Sign-In."
                }
            }
        }
    }

    /// Handles the OAuth callback URL returned from External Safari / Chrome into AppVaultApp.onOpenURL.
    public func handleIncomingOAuthURL(_ url: URL) {
        DebugLogger.shared.log("OAuth", "Received callback URL scheme=\(url.scheme ?? "nil") host=\(url.host ?? "nil")")
        guard let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return
        }
        // Only handle callbacks that look like an OAuth redirect for our pending external session
        guard let verifier = pendingExternalVerifier,
              let expectedState = pendingExternalState,
              let redirectURI = pendingExternalRedirectURI,
              let clientId = pendingExternalClientId else {
            return
        }

        pendingExternalVerifier = nil
        pendingExternalState = nil
        pendingExternalRedirectURI = nil
        pendingExternalClientId = nil
        isAuthenticating = false

        let returnedState = queryItems.first(where: { $0.name == "state" })?.value
        guard returnedState == expectedState else {
            errorMessage = "OAuth state mismatch from external browser. Please try signing in again."
            return
        }

        guard let code = queryItems.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            let errDesc = queryItems.first(where: { $0.name == "error" })?.value ?? "Missing authorization code"
            errorMessage = "Google sign-in failed: \(errDesc)"
            return
        }

        Task {
            await self.exchangeCodeForTokens(code: code, verifier: verifier, redirectURI: redirectURI, clientId: clientId)
        }
    }

    private func buildOAuthRequest() -> (authURL: URL, verifier: String, state: String, redirectURI: String, clientId: String, callbackScheme: String)? {
        if isUsingRcloneClientOverride { clearCustomOAuthOverride() }
        let clientId = interactiveSignInClientId
        guard !clientId.isEmpty else {
            errorMessage = "Google OAuth Client ID is not configured yet. Bake in your iOS Client ID or enter one under Advanced OAuth Settings."
            return nil
        }

        let redirectURI: String
        let callbackScheme: String
        if clientId.hasSuffix(".apps.googleusercontent.com") {
            let prefix = clientId.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
            callbackScheme = "com.googleusercontent.apps.\(prefix)"
            redirectURI = "\(callbackScheme):/oauth2redirect"
        } else {
            callbackScheme = "dev.moe.appvault"
            redirectURI = "dev.moe.appvault:/oauth2redirect"
        }

        let scope = "https://www.googleapis.com/auth/drive.file https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile"
        let expectedState = UUID().uuidString

        guard let verifier = generateCodeVerifier(),
              let challenge = generateCodeChallenge(from: verifier) else {
            errorMessage = "Failed to generate PKCE cryptographic material."
            return nil
        }

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: expectedState),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "select_account consent")
        ]

        guard let authURL = components.url else {
            errorMessage = "Invalid OAuth URL."
            return nil
        }
        return (authURL, verifier, expectedState, redirectURI, clientId, callbackScheme)
    }

    // MARK: - Exchange Code for Tokens
    private func exchangeCodeForTokens(code: String, verifier: String, redirectURI: String, clientId: String) async {
        guard let tokenURL = URL(string: "https://oauth2.googleapis.com/token") else { return }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var bodyParams: [String: String] = [
            "client_id": clientId,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI
        ]
        // Only send client_secret if the user explicitly configured a custom override client ID with a secret
        let clientSecret = customClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !customClientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !clientSecret.isEmpty {
            bodyParams["client_secret"] = clientSecret
        }

        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")

        let bodyString = bodyParams.compactMap { key, value in
            guard let encKey = key.addingPercentEncoding(withAllowedCharacters: allowed),
                  let encVal = value.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            return "\(encKey)=\(encVal)"
        }.joined(separator: "&")

        request.httpBody = bodyString.data(using: .utf8)

        do {
            let (data, response) = try await uploadSession.data(for: request)
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

    // MARK: - Refresh Access Token if Expired (Supports Forced Refresh on 401)
    @discardableResult
    public func ensureValidToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh,
           let expiry = tokenExpiry,
           Date() < expiry.addingTimeInterval(-60),
           let token = accessToken,
           !token.isEmpty {
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

        let clientId = effectiveClientId
        guard !clientId.isEmpty else {
            throw NSError(domain: "GoogleDrive", code: 401, userInfo: [NSLocalizedDescriptionKey: "Google OAuth Client ID is missing. Configure your Client ID in Settings or re-import from rclone."])
        }
        var bodyParams = [
            "client_id": clientId,
            "refresh_token": refresh,
            "grant_type": "refresh_token"
        ]
        let clientSecret = customClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clientSecret.isEmpty {
            bodyParams["client_secret"] = clientSecret
        }

        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")

        let bodyString = bodyParams.compactMap { key, value in
            guard let encKey = key.addingPercentEncoding(withAllowedCharacters: allowed),
                  let encVal = value.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            return "\(encKey)=\(encVal)"
        }.joined(separator: "&")

        request.timeoutInterval = 30
        request.httpBody = bodyString.data(using: .utf8)

        DebugLogger.shared.log("OAuth", "Refreshing Google Drive access token (clientId=\(clientId.prefix(16))...)")
        let (data, response) = try await apiSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccess = json["access_token"] as? String else {
            let errorText = String(data: data, encoding: .utf8) ?? "Authentication refresh failed"
            DebugLogger.shared.log("OAuth", "Token refresh failed HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1): \(errorText)", level: .error)
            throw NSError(domain: "GoogleDrive", code: 401, userInfo: [NSLocalizedDescriptionKey: "Failed to refresh Google token: \(errorText)"])
        }

        self.accessToken = newAccess
        if let expiresIn = json["expires_in"] as? Double {
            self.tokenExpiry = Date().addingTimeInterval(expiresIn)
        } else {
            self.tokenExpiry = Date().addingTimeInterval(3500)
        }

        DebugLogger.shared.log("OAuth", "Google Drive access token refreshed successfully.", level: .success)
        return newAccess
    }

    // MARK: - User Profile
    private func fetchUserProfile() async {
        guard let token = try? await ensureValidToken() else { return }
        guard let url = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo") else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        if let (data, _) = try? await apiSession.data(for: request),
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
        _cachedAccessToken = nil
        _cachedRefreshToken = nil
        userEmail = ""
        userName = ""
        isAuthenticated = false
        if isUsingRcloneClientOverride {
            clearCustomOAuthOverride()
        }
        UserDefaults.standard.removeObject(forKey: "gdrive_user_email")
        UserDefaults.standard.removeObject(forKey: "gdrive_user_name")
    }

    public func setDirectTokens(accessToken: String?, refreshToken: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        // Imported rclone/manual tokens may be expired or nil — mark as expired so the next API call refreshes cleanly
        self.tokenExpiry = Date.distantPast
        self.isAuthenticated = true
        Task {
            await self.fetchUserProfile()
        }
    }

    // MARK: - Get or Create Target Folder in Google Drive
    public func getOrCreateAppFolder(using existingToken: String? = nil) async throws -> String {
        let token: String
        if let existing = existingToken, !existing.isEmpty {
            token = existing
        } else {
            token = try await ensureValidToken()
        }
        let cleanPath = targetFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectivePath = cleanPath.isEmpty ? "AppVault Backups" : cleanPath

        let segments = effectivePath.components(separatedBy: "/").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !segments.isEmpty else {
            return try await getOrCreateSingleFolder(named: "AppVault Backups", parentId: nil, token: token)
        }

        var currentParentId: String? = nil
        for segment in segments {
            currentParentId = try await getOrCreateSingleFolder(named: segment, parentId: currentParentId, token: token)
        }
        return currentParentId ?? "root"
    }

    private func getOrCreateSingleFolder(named name: String, parentId: String?, token: String) async throws -> String {
        // Escape backslashes first, then single quotes for Drive API query syntax
        let escapedName = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        var query = "name = '\(escapedName)' and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
        if let parent = parentId {
            query += " and '\(parent)' in parents"
        } else {
            query += " and 'root' in parents"
        }

        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: "files(id,name)"),
            URLQueryItem(name: "spaces", value: "drive")
        ]

        guard let listURL = components.url else {
            throw NSError(domain: "GoogleDrive", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid query URL."])
        }

        var listReq = URLRequest(url: listURL)
        listReq.timeoutInterval = 30
        listReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, listRes) = try await apiSession.data(for: listReq)
        if let listHttp = listRes as? HTTPURLResponse, !(200...299).contains(listHttp.statusCode) {
            let errBody = String(data: data, encoding: .utf8) ?? "HTTP \(listHttp.statusCode)"
            throw NSError(domain: "GoogleDrive", code: listHttp.statusCode, userInfo: [NSLocalizedDescriptionKey: "Google Drive folder lookup failed (HTTP \(listHttp.statusCode)): \(errBody)"])
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let files = json["files"] as? [[String: Any]],
           let first = files.first,
           let folderId = first["id"] as? String {
            return folderId
        }

        guard let createURL = URL(string: "https://www.googleapis.com/drive/v3/files") else {
            throw NSError(domain: "GoogleDrive", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid URL."])
        }

        var createReq = URLRequest(url: createURL)
        createReq.httpMethod = "POST"
        createReq.timeoutInterval = 30
        createReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        createReq.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")

        var metadata: [String: Any] = [
            "name": name,
            "mimeType": "application/vnd.google-apps.folder"
        ]
        if let parent = parentId {
            metadata["parents"] = [parent]
        }

        createReq.httpBody = try JSONSerialization.data(withJSONObject: metadata)

        let (createData, res) = try await apiSession.data(for: createReq)
        guard let http = res as? HTTPURLResponse, (http.statusCode == 200 || http.statusCode == 201),
              let createJson = try? JSONSerialization.jsonObject(with: createData) as? [String: Any],
              let newId = createJson["id"] as? String else {
            let errString = String(data: createData, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "GoogleDrive", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to create folder '\(name)': \(errString)"])
        }

        return newId
    }

    // MARK: - Resumable Upload Session (Initiation)
    public func initiateResumableUpload(
        fileName: String,
        mimeType: String = "application/x-gzip",
        onStatus: ((String) -> Void)? = nil
    ) async throws -> URL {
        DebugLogger.shared.log("GoogleDrive", "Initiating resumable upload for \(fileName) (mime=\(mimeType))")
        onStatus?("Validating Google Drive access token...")
        let token = try await ensureValidToken()

        onStatus?("Locating Google Drive folder '\(targetFolderName)'...")
        DebugLogger.shared.log("GoogleDrive", "Resolving folder path '\(targetFolderName)'...")
        let folderID = try await getOrCreateAppFolder(using: token)
        DebugLogger.shared.log("GoogleDrive", "Resolved folder '\(targetFolderName)' -> id=\(folderID)")

        onStatus?("Opening Google Drive resumable upload session...")
        guard let uploadURL = URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable") else {
            throw NSError(domain: "GoogleDrive", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid upload URL."])
        }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(mimeType, forHTTPHeaderField: "X-Upload-Content-Type")

        let metadata: [String: Any] = [
            "name": fileName,
            "parents": [folderID]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: metadata)

        let (data, response) = try await apiSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "GoogleDrive", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response from Google Drive."])
        }
        guard (200...299).contains(http.statusCode),
              let locationString = http.value(forHTTPHeaderField: "Location"),
              let sessionURL = URL(string: locationString) else {
            let errBody = String(data: data, encoding: .utf8) ?? "No error details"
            DebugLogger.shared.log("GoogleDrive", "initiateResumableUpload failed HTTP \(http.statusCode): \(errBody)", level: .error)
            throw NSError(domain: "GoogleDrive", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Google Drive upload session failed (HTTP \(http.statusCode)): \(errBody)"])
        }

        DebugLogger.shared.log("GoogleDrive", "Resumable upload session opened successfully.", level: .success)
        return sessionURL
    }

    // MARK: - Check Resumable Upload Status (Error Recovery)
    public func checkUploadStatus(sessionURL: URL, totalFileSize: Int64?) async throws -> (isComplete: Bool, nextOffset: Int64, fileID: String?) {
        let token = try await ensureValidToken()
        var request = URLRequest(url: sessionURL)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let totalStr = totalFileSize != nil ? "\(totalFileSize!)" : "*"
        request.setValue("bytes */\(totalStr)", forHTTPHeaderField: "Content-Range")
        request.setValue("0", forHTTPHeaderField: "Content-Length")

        let (data, response) = try await uploadSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "GoogleDrive", code: 500, userInfo: [NSLocalizedDescriptionKey: "No response from Google Drive status check."])
        }

        if http.statusCode == 200 || http.statusCode == 201 {
            let fileID = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String
            return (true, 0, fileID)
        } else if http.statusCode == 308 {
            if let rangeHeader = http.allHeaderFields["Range"] as? String ?? http.allHeaderFields["range"] as? String,
               let lastByteStr = rangeHeader.components(separatedBy: "-").last,
               let lastByte = Int64(lastByteStr) {
                return (false, lastByte + 1, nil)
            }
            return (false, 0, nil)
        } else {
            throw NSError(domain: "GoogleDrive", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Upload status check failed with HTTP \(http.statusCode)"])
        }
    }

    // MARK: - Upload Chunk with Valid Content-Range, Auth Header & Forced 401 Refresh
    public func uploadChunk(
        sessionURL: URL,
        chunkData: Data,
        startOffset: Int64,
        isFinal: Bool,
        totalFileSize: Int64?
    ) async throws -> (isComplete: Bool, fileID: String?) {
        var attempts = 0
        let maxAttempts = 3
        var currentToken = try await ensureValidToken()

        while attempts < maxAttempts {
            attempts += 1

            var request = URLRequest(url: sessionURL)
            request.httpMethod = "PUT"
            request.timeoutInterval = 60
            request.setValue("Bearer \(currentToken)", forHTTPHeaderField: "Authorization")

            let (data, response): (Data, URLResponse)
            do {
                if chunkData.isEmpty {
                    let totalStr = totalFileSize.map { "\($0)" } ?? "\(startOffset)"
                    request.setValue("bytes */\(totalStr)", forHTTPHeaderField: "Content-Range")
                    (data, response) = try await uploadSession.data(for: request)
                } else {
                    let endOffset = startOffset + Int64(chunkData.count) - 1
                    let totalStr: String
                    if let total = totalFileSize {
                        totalStr = "\(total)"
                    } else if isFinal {
                        totalStr = "\(endOffset + 1)"
                    } else {
                        totalStr = "*"
                    }
                    request.setValue("bytes \(startOffset)-\(endOffset)/\(totalStr)", forHTTPHeaderField: "Content-Range")
                    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                    (data, response) = try await uploadSession.upload(for: request, from: chunkData)
                }
            } catch {
                if attempts >= maxAttempts || Task.isCancelled {
                    throw error
                }
                try await Task.sleep(nanoseconds: UInt64(attempts) * 1_000_000_000)
                continue
            }

            guard let http = response as? HTTPURLResponse else {
                throw NSError(domain: "GoogleDrive", code: 500, userInfo: [NSLocalizedDescriptionKey: "No response from Google Drive."])
            }

            DebugLogger.shared.log("GoogleDrive", "uploadChunk offset=\(startOffset) bytes=\(chunkData.count) final=\(isFinal) -> HTTP \(http.statusCode)", level: (http.statusCode == 200 || http.statusCode == 201 || http.statusCode == 308) ? .info : .warning)
            if http.statusCode == 200 || http.statusCode == 201 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let fileID = json["id"] as? String {
                    return (true, fileID)
                }
                return (true, nil)
            } else if http.statusCode == 308 {
                return (false, nil)
            } else if http.statusCode == 401 {
                currentToken = try await self.ensureValidToken(forceRefresh: true)
                continue
            } else if http.statusCode >= 500 {
                if attempts >= maxAttempts {
                    let msg = String(data: data, encoding: .utf8) ?? "Server error \(http.statusCode)"
                    throw NSError(domain: "GoogleDrive", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Google Drive server error (HTTP \(http.statusCode)): \(msg)"])
                }
                try await Task.sleep(nanoseconds: UInt64(attempts) * 1_000_000_000)
                let status = try? await self.checkUploadStatus(sessionURL: sessionURL, totalFileSize: totalFileSize)
                if status?.isComplete == true {
                    return (true, status?.fileID)
                }
                continue
            } else {
                // Non-retryable 4xx client error: fail immediately with full Google JSON reason
                let msg = String(data: data, encoding: .utf8) ?? "Upload chunk error \(http.statusCode)"
                DebugLogger.shared.log("GoogleDrive", "Chunk rejected HTTP \(http.statusCode): \(msg)", level: .error)
                throw NSError(domain: "GoogleDrive", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Google Drive rejected upload chunk (HTTP \(http.statusCode)): \(msg)"])
            }
        }

        throw NSError(domain: "GoogleDrive", code: 500, userInfo: [NSLocalizedDescriptionKey: "Max chunk upload retries exceeded."])
    }

    // MARK: - List Cloud Backups
    public func fetchCloudBackups() async throws -> [GoogleDriveFile] {
        let token = try await ensureValidToken()
        let folderID = try await getOrCreateAppFolder()

        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "'\(folderID)' in parents and trashed = false"),
            URLQueryItem(name: "fields", value: "files(id,name,size,modifiedTime,mimeType)"),
            URLQueryItem(name: "orderBy", value: "modifiedTime desc")
        ]

        guard let listURL = components.url else { return [] }

        var request = URLRequest(url: listURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await uploadSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "GoogleDrive", code: 500, userInfo: [NSLocalizedDescriptionKey: "No response from Google Drive."])
        }
        guard http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fileList = json["files"] as? [[String: Any]] else {
            let errText = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "GoogleDrive", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Failed to list cloud backups: \(errText)"])
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

    // MARK: - Download Cloud Backup to File with Progress (Proper Session Invalidation)
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

        let delegate = DownloadProgressDelegate(onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let downloadedTempURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            delegate.setContinuation(continuation)
            let task = session.downloadTask(with: request)
            task.resume()
        }

        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: downloadedTempURL, to: destinationURL)
        PosixHelper.shared.fixPermissions(at: destinationURL.path)
    }

    // MARK: - Delete Cloud Backup (Validates HTTP Response)
    public func deleteCloudBackup(fileID: String) async throws {
        let token = try await ensureValidToken()
        guard let deleteURL = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)") else {
            throw NSError(domain: "GoogleDrive", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid file ID."])
        }

        var request = URLRequest(url: deleteURL)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await uploadSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 500
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(code)"
            throw NSError(domain: "GoogleDrive", code: code, userInfo: [NSLocalizedDescriptionKey: "Failed to delete file from Google Drive: \(msg)"])
        }
    }

    // MARK: - PKCE Utilities (RFC 7636 Section 4)
    private func generateCodeVerifier() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { return nil }

        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateCodeChallenge(from verifier: String) -> String? {
        guard let data = verifier.data(using: .ascii), !data.isEmpty else { return nil }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))

        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            _ = CC_SHA256(baseAddress, CC_LONG(data.count), &digest)
        }

        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - 2-Second Upload Diagnostic Test
    public func testDriveConnection() async throws -> String {
        let testName = "AppVault_ConnectionTest_\(Int(Date().timeIntervalSince1970)).tmp"
        let sessionURL = try await initiateResumableUpload(fileName: testName, mimeType: "text/plain")
        let payload = Data("AppVault-OK".utf8)
        let (_, fileID) = try await uploadChunk(
            sessionURL: sessionURL,
            chunkData: payload,
            startOffset: 0,
            isFinal: true,
            totalFileSize: Int64(payload.count)
        )
        if let id = fileID {
            try? await deleteCloudBackup(fileID: id)
        }
        return "Google Drive token, folder '\(targetFolderName)', and resumable upload are working!"
    }

    // MARK: - WebKit-Free OAuth 2.0 Device Flow (Works 100% on Jailbroken iOS 16 via Any PC/Phone Browser)
    public func startDeviceFlow(deviceClientId: String, deviceClientSecret: String) {
        let cid = deviceClientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let csec = deviceClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cid.isEmpty, !csec.isEmpty else {
            errorMessage = "Device Flow requires a Google 'TVs and Limited Input devices' Client ID and Client Secret."
            return
        }

        cancelDeviceFlow()
        errorMessage = nil
        isAuthenticating = true
        isPollingDeviceFlow = true

        deviceFlowTask = Task {
            do {
                guard let url = URL(string: "https://oauth2.googleapis.com/device/code") else { return }
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

                var allowed = CharacterSet.alphanumerics
                allowed.insert(charactersIn: "-._~")
                let scope = "https://www.googleapis.com/auth/drive.file"
                let params = ["client_id": cid, "scope": scope]
                req.httpBody = params.compactMap { k, v in
                    guard let ek = k.addingPercentEncoding(withAllowedCharacters: allowed),
                          let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
                    return "\(ek)=\(ev)"
                }.joined(separator: "&").data(using: .utf8)

                let (data, res) = try await apiSession.data(for: req)
                guard let http = res as? HTTPURLResponse, http.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let deviceCode = json["device_code"] as? String,
                      let userCode = json["user_code"] as? String,
                      let verifyURL = json["verification_url"] as? String else {
                    let err = String(data: data, encoding: .utf8) ?? "Device flow initiation failed"
                    self.errorMessage = "Device login error: \(err)"
                    self.cancelDeviceFlow()
                    return
                }

                self.deviceUserCode = userCode
                self.deviceVerificationURL = verifyURL
                let interval = max(5, (json["interval"] as? Int) ?? 5)
                let expiresIn = (json["expires_in"] as? Int) ?? 600
                let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))

                while !Task.isCancelled && Date() < deadline {
                    try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                    guard let tokenURL = URL(string: "https://oauth2.googleapis.com/token") else { break }
                    var pollReq = URLRequest(url: tokenURL)
                    pollReq.httpMethod = "POST"
                    pollReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

                    let pollParams = [
                        "client_id": cid,
                        "client_secret": csec,
                        "device_code": deviceCode,
                        "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
                    ]
                    pollReq.httpBody = pollParams.compactMap { k, v in
                        guard let ek = k.addingPercentEncoding(withAllowedCharacters: allowed),
                              let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
                        return "\(ek)=\(ev)"
                    }.joined(separator: "&").data(using: .utf8)

                    let (pData, pRes) = try await apiSession.data(for: pollReq)
                    if let pHttp = pRes as? HTTPURLResponse, pHttp.statusCode == 200,
                       let pJson = try? JSONSerialization.jsonObject(with: pData) as? [String: Any],
                       let access = pJson["access_token"] as? String {
                        self.customClientId = cid
                        self.customClientSecret = csec
                        self.accessToken = access
                        if let refresh = pJson["refresh_token"] as? String, !refresh.isEmpty {
                            self.refreshToken = refresh
                        }
                        let exp = (pJson["expires_in"] as? Double) ?? 3500
                        self.tokenExpiry = Date().addingTimeInterval(exp)
                        self.isAuthenticated = true
                        self.userName = "Google Drive (Device Login)"
                        self.cancelDeviceFlow()
                        await self.fetchUserProfile()
                        return
                    } else if let pJson = try? JSONSerialization.jsonObject(with: pData) as? [String: Any],
                              let errCode = pJson["error"] as? String {
                        if errCode == "authorization_pending" || errCode == "slow_down" {
                            continue
                        }
                        self.errorMessage = "Device login stopped: \(errCode)"
                        self.cancelDeviceFlow()
                        return
                    }
                }

                self.errorMessage = "Device login code expired. Tap to generate a new code."
                self.cancelDeviceFlow()
            } catch {
                if !Task.isCancelled {
                    self.errorMessage = error.localizedDescription
                }
                self.cancelDeviceFlow()
            }
        }
    }

    public func cancelDeviceFlow() {
        deviceFlowTask?.cancel()
        deviceFlowTask = nil
        deviceUserCode = nil
        deviceVerificationURL = nil
        isPollingDeviceFlow = false
        isAuthenticating = false
    }
}
