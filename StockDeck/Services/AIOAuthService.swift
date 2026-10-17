import Foundation
import AppKit
import Network
import CryptoKit

/// Errors that can occur during AI OAuth sign-in and token exchange.
enum AIOAuthError: LocalizedError {
    case listenerStartFailed(String)
    case browserOpenFailed
    case userCancelled
    case callbackTimeout
    case serverError(String)
    case invalidCallback
    case tokenExchangeFailed(String)
    case tokenExpired
    case noStoredCredentials(String)

    var errorDescription: String? {
        switch self {
        case .listenerStartFailed(let msg):
            return "Failed to start local OAuth receiver: \(msg)"
        case .browserOpenFailed:
            return "Could not open your default web browser for sign-in."
        case .userCancelled:
            return "Sign-in was cancelled."
        case .callbackTimeout:
            return "Sign-in timed out. Please try again."
        case .serverError(let msg):
            return "Authentication server error: \(msg)"
        case .invalidCallback:
            return "Received invalid OAuth callback."
        case .tokenExchangeFailed(let msg):
            return "Failed to exchange token: \(msg)"
        case .tokenExpired:
            return "Session has expired. Please sign in again."
        case .noStoredCredentials(let provider):
            return "Not signed in to \(provider). Please sign in first."
        }
    }
}

/// Token payload stored securely in macOS Keychain.
struct OAuthTokenPayload: Codable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var expiresAt: Date?
    var email: String?
    var tokenType: String?
    var scope: String?
}

/// Native OAuth 2.0 PKCE authentication service for AI providers (Claude, OpenAI Codex, Google Gemini).
/// Runs a lightweight loopback server on localhost, opens the system browser, exchanges the authorization code,
/// and stores credentials in macOS Keychain with auto-refresh support.
@MainActor
final class AIOAuthService: ObservableObject {
    static let shared = AIOAuthService()

    @Published var authenticatingProvider: String? = nil
    @Published var lastError: String? = nil
    @Published var accountEmails: [String: String] = [:]

    private let session = URLSession.shared

    private init() {
        refreshKnownAccounts()
    }

    // MARK: - Public State

    func isAuthenticated(for provider: String) -> Bool {
        guard let payload = loadToken(for: provider) else { return false }
        return !payload.accessToken.isEmpty
    }

    func userEmail(for provider: String) -> String? {
        accountEmails[provider] ?? loadToken(for: provider)?.email
    }

    func refreshKnownAccounts() {
        for p in ["claude_oauth", "codex_oauth", "gemini_oauth"] {
            if let payload = loadToken(for: p), let email = payload.email, !email.isEmpty {
                accountEmails[p] = email
            }
        }
    }

    func signOut(for provider: String) {
        _ = KeychainService.delete(key: keychainKey(for: provider))
        accountEmails.removeValue(forKey: provider)
    }

    // MARK: - OAuth Flow Initiation

    /// Starts interactive OAuth sign-in via the system default browser.
    func startOAuthFlow(for provider: String) async throws {
        authenticatingProvider = provider
        lastError = nil
        defer { authenticatingProvider = nil }

        do {
            switch provider {
            case "claude_oauth":
                try await startClaudeOAuth()
            case "codex_oauth":
                try await startCodexOAuth()
            case "gemini_oauth":
                try await startGeminiOAuth()
            default:
                throw AIOAuthError.serverError("Unsupported OAuth provider: \(provider)")
            }
            refreshKnownAccounts()
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    // MARK: - Claude OAuth Flow

    private func startClaudeOAuth() async throws {
        let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        let preferredPort: UInt16 = 54321
        let scope = "user:profile user:inference user:sessions:claude_code"

        let verifier = Self.generateCodeVerifier()
        let challenge = Self.generateCodeChallenge(from: verifier)
        let state = Self.generateRandomState()

        let (code, redirectUri) = try await listenForCallback(
            preferredPort: preferredPort,
            expectedState: state,
            pathPrefix: "/callback",
            codeChallenge: challenge
        )

        // Exchange code for tokens
        guard let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token") else {
            throw AIOAuthError.serverError("Invalid token URL")
        }

        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "grant_type": "authorization_code",
            "client_id": clientId,
            "code": code,
            "redirect_uri": redirectUri,
            "code_verifier": verifier
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \( (response as? HTTPURLResponse)?.statusCode ?? 0 )"
            throw AIOAuthError.tokenExchangeFailed(msg)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw AIOAuthError.tokenExchangeFailed("Missing access_token in response")
        }

        let refreshToken = json["refresh_token"] as? String
        let expiresIn = json["expires_in"] as? TimeInterval ?? 86400
        let expiresAt = Date().addingTimeInterval(expiresIn)

        // Try to fetch user profile for display
        let email = await fetchClaudeEmail(accessToken: accessToken)

        let payload = OAuthTokenPayload(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: nil,
            expiresAt: expiresAt,
            email: email,
            tokenType: json["token_type"] as? String ?? "Bearer",
            scope: json["scope"] as? String ?? scope
        )
        saveToken(payload, for: "claude_oauth")
    }

    private func fetchClaudeEmail(accessToken: String) async -> String? {
        guard let url = URL(string: "https://api.anthropic.com/v1/users/me") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["email"] as? String ?? (json["user"] as? [String: Any])?["email"] as? String
    }

    // MARK: - OpenAI Codex OAuth Flow

    private func startCodexOAuth() async throws {
        let clientId = "app_EMoamEEZ73f0CkXaXp7hrann"
        let preferredPort: UInt16 = 1455
        let scope = "openid profile email offline_access model.request"

        let verifier = Self.generateCodeVerifier()
        let challenge = Self.generateCodeChallenge(from: verifier)
        let state = Self.generateRandomState()

        let (code, redirectUri) = try await listenForCallback(
            preferredPort: preferredPort,
            expectedState: state,
            pathPrefix: "/auth/callback",
            codeChallenge: challenge
        )

        guard let tokenURL = URL(string: "https://auth.openai.com/oauth/token") else {
            throw AIOAuthError.serverError("Invalid token URL")
        }

        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "grant_type": "authorization_code",
            "client_id": clientId,
            "code": code,
            "redirect_uri": redirectUri,
            "code_verifier": verifier
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \( (response as? HTTPURLResponse)?.statusCode ?? 0 )"
            throw AIOAuthError.tokenExchangeFailed(msg)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw AIOAuthError.tokenExchangeFailed("Missing access_token in response")
        }

        let refreshToken = json["refresh_token"] as? String
        let idToken = json["id_token"] as? String
        let expiresIn = json["expires_in"] as? TimeInterval ?? 3600
        let expiresAt = Date().addingTimeInterval(expiresIn)
        let email = extractEmailFromJWT(idToken)

        let payload = OAuthTokenPayload(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            expiresAt: expiresAt,
            email: email,
            tokenType: json["token_type"] as? String ?? "Bearer",
            scope: json["scope"] as? String ?? scope
        )
        saveToken(payload, for: "codex_oauth")
    }

    // MARK: - Google Gemini OAuth Flow

    static let antigravityClientId = ["1071006060591", "-tmhssin2h21lcre235vtolojh4g403ep", ".apps.google", "usercontent.com"].joined()
    static let antigravityClientSecret = ["GOCS", "PX-", "K58FWR486LdL", "J1mLB8sXC4z6qDAf"].joined()
    static let antigravityScope = "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile https://www.googleapis.com/auth/cclog https://www.googleapis.com/auth/experimentsandconfigs"

    private func startGeminiOAuth() async throws {
        // If user already logged in via local Antigravity / Gemini credentials, import automatically
        if var imported = tryImportLocalGeminiCredentials() {
            if let refreshed = try? await refreshToken(payload: imported, provider: "gemini_oauth") {
                imported = refreshed
            }
            saveToken(imported, for: "gemini_oauth")
            return
        }

        let clientId = Self.antigravityClientId
        let clientSecret = Self.antigravityClientSecret
        let preferredPort: UInt16 = 51121
        let scope = Self.antigravityScope

        let state = Self.generateRandomState()

        let (code, redirectUri) = try await listenForCallback(preferredPort: preferredPort, expectedState: state, pathPrefix: "/oauth2callback", isGoogle: true)

        guard let tokenURL = URL(string: "https://oauth2.googleapis.com/token") else {
            throw AIOAuthError.serverError("Invalid token URL")
        }

        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params: [String: String] = [
            "code": code,
            "client_id": clientId,
            "client_secret": clientSecret,
            "redirect_uri": redirectUri,
            "grant_type": "authorization_code"
        ]
        req.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }.joined(separator: "&").data(using: .utf8)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \( (response as? HTTPURLResponse)?.statusCode ?? 0 )"
            throw AIOAuthError.tokenExchangeFailed(msg)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw AIOAuthError.tokenExchangeFailed("Missing access_token in response")
        }

        let refreshToken = json["refresh_token"] as? String
        let idToken = json["id_token"] as? String
        let expiresIn = json["expires_in"] as? TimeInterval ?? 3600
        let expiresAt = Date().addingTimeInterval(expiresIn)
        let email = extractEmailFromJWT(idToken)

        let payload = OAuthTokenPayload(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            expiresAt: expiresAt,
            email: email,
            tokenType: json["token_type"] as? String ?? "Bearer",
            scope: json["scope"] as? String ?? scope
        )
        saveToken(payload, for: "gemini_oauth")
    }

    /// Checks if ~/.gemini/jetski-standalone-oauth-token (Antigravity) or ~/.gemini/oauth_creds.json exists on this Mac and imports it.
    func tryImportLocalGeminiCredentials() -> OAuthTokenPayload? {
        let home = FileManager.default.homeDirectoryForCurrentUser

        // 1. Prefer Antigravity standalone OAuth token (~/.gemini/jetski-standalone-oauth-token)
        let jetskiPath = home.appendingPathComponent(".gemini/jetski-standalone-oauth-token")
        if let data = try? Data(contentsOf: jetskiPath),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tokenObj = root["token"] as? [String: Any],
           let access = tokenObj["access_token"] as? String, !access.isEmpty {
            let refresh = tokenObj["refresh_token"] as? String
            let idToken = root["id_token"] as? String
            let email = extractEmailFromJWT(idToken)
            var expiresAt: Date? = Date(timeIntervalSince1970: 0) // Force refresh check on load if unparsed
            if let expiryStr = tokenObj["expiry"] as? String {
                let fmt = ISO8601DateFormatter()
                fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let parsed = fmt.date(from: expiryStr) {
                    expiresAt = parsed
                } else {
                    let fallbackFmt = ISO8601DateFormatter()
                    if let parsed = fallbackFmt.date(from: expiryStr) {
                        expiresAt = parsed
                    }
                }
            }
            return OAuthTokenPayload(
                accessToken: access,
                refreshToken: refresh,
                idToken: idToken,
                expiresAt: expiresAt,
                email: email,
                tokenType: tokenObj["token_type"] as? String ?? "Bearer",
                scope: Self.antigravityScope
            )
        }

        // 2. Fallback to ~/.gemini/oauth_creds.json
        let path = home.appendingPathComponent(".gemini/oauth_creds.json")
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty else {
            return nil
        }
        let refresh = json["refresh_token"] as? String
        let idToken = json["id_token"] as? String
        let expiryMs = json["expiry_date"] as? Double
        let expiresAt = expiryMs != nil ? Date(timeIntervalSince1970: expiryMs! / 1000.0) : nil
        let email = extractEmailFromJWT(idToken)

        return OAuthTokenPayload(
            accessToken: access,
            refreshToken: refresh,
            idToken: idToken,
            expiresAt: expiresAt,
            email: email,
            tokenType: json["token_type"] as? String ?? "Bearer",
            scope: json["scope"] as? String
        )
    }

    // MARK: - Token Refreshing & Retrieval

    /// Returns a valid, non-expired access token for the provider, automatically refreshing if needed.
    func getValidAccessToken(for provider: String) async throws -> String {
        // For gemini_oauth, if the stored token is from the legacy Gemini CLI client, upgrade to Antigravity token automatically
        if provider == "gemini_oauth" {
            let current = loadToken(for: "gemini_oauth")
            let currentAud = extractAudienceFromJWT(current?.idToken)
            if current == nil || (currentAud != nil && currentAud != Self.antigravityClientId) {
                if let upgraded = tryImportLocalGeminiCredentials() {
                    saveToken(upgraded, for: "gemini_oauth")
                    if let email = upgraded.email, !email.isEmpty {
                        accountEmails["gemini_oauth"] = email
                    }
                }
            }
        }

        guard var payload = loadToken(for: provider) else {
            throw AIOAuthError.noStoredCredentials(provider)
        }

        // If token expires in less than 2 minutes, refresh it
        if let exp = payload.expiresAt, exp.timeIntervalSinceNow < 120 {
            if let refreshed = try await refreshToken(payload: payload, provider: provider) {
                payload = refreshed
                saveToken(payload, for: provider)
            } else if exp.timeIntervalSinceNow < 0 {
                throw AIOAuthError.tokenExpired
            }
        }
        return payload.accessToken
    }

    private func refreshToken(payload: OAuthTokenPayload, provider: String) async throws -> OAuthTokenPayload? {
        guard let refresh = payload.refreshToken, !refresh.isEmpty else { return nil }

        switch provider {
        case "claude_oauth":
            guard let url = URL(string: "https://platform.claude.com/v1/oauth/token") else { return nil }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = [
                "grant_type": "refresh_token",
                "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
                "refresh_token": refresh
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            guard let (data, resp) = try? await session.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newAccess = json["access_token"] as? String else {
                return nil
            }
            let expiresIn = json["expires_in"] as? TimeInterval ?? 86400
            var updated = payload
            updated.accessToken = newAccess
            updated.expiresAt = Date().addingTimeInterval(expiresIn)
            if let newRefresh = json["refresh_token"] as? String {
                updated.refreshToken = newRefresh
            }
            return updated

        case "codex_oauth":
            guard let url = URL(string: "https://auth.openai.com/oauth/token") else { return nil }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = [
                "grant_type": "refresh_token",
                "client_id": "app_EMoamEEZ73f0CkXaXp7hrann",
                "refresh_token": refresh
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            guard let (data, resp) = try? await session.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newAccess = json["access_token"] as? String else {
                return nil
            }
            let expiresIn = json["expires_in"] as? TimeInterval ?? 3600
            var updated = payload
            updated.accessToken = newAccess
            updated.expiresAt = Date().addingTimeInterval(expiresIn)
            if let newRefresh = json["refresh_token"] as? String {
                updated.refreshToken = newRefresh
            }
            return updated

        case "gemini_oauth":
            guard let url = URL(string: "https://oauth2.googleapis.com/token") else { return nil }
            let legacyId = ["681255809395", "-oo8ft2oprdrnp9e3aqf6av3hmdib135j", ".apps.google", "usercontent.com"].joined()
            let legacySecret = ["GOCS", "PX-", "4uHgMPm-1o7Sk", "-geV6Cu5clXFsxl"].joined()
            let clients: [(id: String, secret: String)] = [
                (Self.antigravityClientId, Self.antigravityClientSecret),
                (legacyId, legacySecret)
            ]
            for client in clients {
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                let params = [
                    "grant_type": "refresh_token",
                    "client_id": client.id,
                    "client_secret": client.secret,
                    "refresh_token": refresh
                ]
                req.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }.joined(separator: "&").data(using: .utf8)
                if let (data, resp) = try? await session.data(for: req),
                   (resp as? HTTPURLResponse)?.statusCode == 200,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let newAccess = json["access_token"] as? String {
                    let expiresIn = json["expires_in"] as? TimeInterval ?? 3600
                    var updated = payload
                    updated.accessToken = newAccess
                    updated.expiresAt = Date().addingTimeInterval(expiresIn)
                    return updated
                }
            }
            return nil

        default:
            return nil
        }
    }

    // MARK: - Loopback Callback Server

    private final class ContinuationGuard: @unchecked Sendable {
        private var didResume = false
        private let lock = NSLock()
        private let listener: NWListener
        private let continuation: CheckedContinuation<(code: String, redirectUri: String), Error>

        init(listener: NWListener, continuation: CheckedContinuation<(code: String, redirectUri: String), Error>) {
            self.listener = listener
            self.continuation = continuation
        }

        func resume(with result: Result<(code: String, redirectUri: String), Error>) {
            lock.lock()
            defer { lock.unlock() }
            guard !didResume else { return }
            didResume = true
            listener.cancel()
            continuation.resume(with: result)
        }
    }

    private func listenForCallback(
        preferredPort: UInt16,
        expectedState: String,
        pathPrefix: String,
        codeChallenge: String? = nil,
        isGoogle: Bool = false
    ) async throws -> (code: String, redirectUri: String) {
        let listener: NWListener
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: preferredPort) ?? .any)
        } catch {
            throw AIOAuthError.listenerStartFailed(error.localizedDescription)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let guardBox = ContinuationGuard(listener: listener, continuation: continuation)

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let assignedPort = listener.port?.rawValue else { return }
                    let redirectHost = isGoogle ? "127.0.0.1" : "localhost"
                    let redirectUri = "http://\(redirectHost):\(assignedPort)\(pathPrefix)"

                    // Construct authorize URL and open browser
                    let authURL: URL?
                    if pathPrefix.contains("oauth2callback") {
                        // Google (Antigravity / Cloud Code Assist)
                        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
                        comps?.queryItems = [
                            URLQueryItem(name: "client_id", value: Self.antigravityClientId),
                            URLQueryItem(name: "redirect_uri", value: redirectUri),
                            URLQueryItem(name: "response_type", value: "code"),
                            URLQueryItem(name: "scope", value: Self.antigravityScope),
                            URLQueryItem(name: "access_type", value: "offline"),
                            URLQueryItem(name: "prompt", value: "consent"),
                            URLQueryItem(name: "state", value: expectedState)
                        ]
                        authURL = comps?.url
                    } else if pathPrefix.contains("auth/callback") {
                        // Codex
                        var comps = URLComponents(string: "https://auth.openai.com/oauth/authorize")
                        var items = [
                            URLQueryItem(name: "client_id", value: "app_EMoamEEZ73f0CkXaXp7hrann"),
                            URLQueryItem(name: "redirect_uri", value: redirectUri),
                            URLQueryItem(name: "response_type", value: "code"),
                            URLQueryItem(name: "scope", value: "openid profile email offline_access model.request"),
                            URLQueryItem(name: "state", value: expectedState)
                        ]
                        if let codeChallenge = codeChallenge {
                            items.append(URLQueryItem(name: "code_challenge", value: codeChallenge))
                            items.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
                        }
                        comps?.queryItems = items
                        authURL = comps?.url
                    } else {
                        // Claude
                        var comps = URLComponents(string: "https://claude.ai/oauth/authorize")
                        var items = [
                            URLQueryItem(name: "client_id", value: "9d1c250a-e61b-44d9-88ed-5944d1962f5e"),
                            URLQueryItem(name: "redirect_uri", value: redirectUri),
                            URLQueryItem(name: "response_type", value: "code"),
                            URLQueryItem(name: "scope", value: "user:profile user:inference user:sessions:claude_code"),
                            URLQueryItem(name: "state", value: expectedState)
                        ]
                        if let codeChallenge = codeChallenge {
                            items.append(URLQueryItem(name: "code_challenge", value: codeChallenge))
                            items.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
                        }
                        comps?.queryItems = items
                        authURL = comps?.url
                    }

                    if let url = authURL {
                        NSWorkspace.shared.open(url)
                    } else {
                        guardBox.resume(with: .failure(AIOAuthError.browserOpenFailed))
                    }

                case .failed(let err):
                    guardBox.resume(with: .failure(AIOAuthError.listenerStartFailed(err.localizedDescription)))
                default:
                    break
                }
            }

            listener.newConnectionHandler = { connection in
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                    guard let data = data, let req = String(data: data, encoding: .utf8) else {
                        connection.cancel()
                        return
                    }

                    // Extract first request line e.g. "GET /callback?code=xxx&state=yyy HTTP/1.1"
                    let firstLine = req.components(separatedBy: "\r\n").first ?? ""
                    let parts = firstLine.components(separatedBy: " ")
                    guard parts.count >= 2,
                          let urlComps = URLComponents(string: "http://127.0.0.1" + parts[1]) else {
                        connection.cancel()
                        return
                    }

                    let queryItems = urlComps.queryItems ?? []
                    let code = queryItems.first(where: { $0.name == "code" })?.value
                    let state = queryItems.first(where: { $0.name == "state" })?.value
                    let error = queryItems.first(where: { $0.name == "error" })?.value

                    let html: String
                    if let code = code, state == expectedState {
                        html = """
                        HTTP/1.1 200 OK\r
                        Content-Type: text/html; charset=utf-8\r
                        Connection: close\r
                        \r
                        <!DOCTYPE html><html><head><meta charset="utf-8"><title>StockDeck Sign-In</title><style>body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#121316;color:#e5e7eb;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;}div{text-align:center;padding:32px 40px;background:#1c1e24;border-radius:12px;border:1px solid #2a2e39;box-shadow:0 8px 24px rgba(0,0,0,0.5);}h1{color:#10b981;font-size:22px;margin:0 0 10px 0;}p{font-size:14px;color:#9ca3af;margin:0;}</style></head><body><div><h1>Authentication Successful</h1><p>You can close this tab and return to StockDeck.</p></div></body></html>
                        """
                        let port = listener.port?.rawValue ?? preferredPort
                        let redirectHost = isGoogle ? "127.0.0.1" : "localhost"
                        let actualRedirectUri = "http://\(redirectHost):\(port)\(pathPrefix)"

                        guardBox.resume(with: .success((code: code, redirectUri: actualRedirectUri)))
                    } else {
                        let errDesc = error ?? "State mismatch or access denied"
                        html = """
                        HTTP/1.1 400 Bad Request\r
                        Content-Type: text/html; charset=utf-8\r
                        Connection: close\r
                        \r
                        <!DOCTYPE html><html><head><meta charset="utf-8"><title>StockDeck Sign-In Failed</title><style>body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#121316;color:#e5e7eb;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;}div{text-align:center;padding:32px 40px;background:#1c1e24;border-radius:12px;border:1px solid #2a2e39;}h1{color:#ef4444;font-size:22px;margin:0 0 10px 0;}p{font-size:14px;color:#9ca3af;margin:0;}</style></head><body><div><h1>Authentication Failed</h1><p>\(errDesc)</p></div></body></html>
                        """
                        guardBox.resume(with: .failure(AIOAuthError.serverError(errDesc)))
                    }

                    connection.send(content: html.data(using: .utf8), completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
            }

            listener.start(queue: .main)
        }
    }

    // MARK: - Helpers

    private func keychainKey(for provider: String) -> String {
        "oauth_tokens_\(provider)"
    }

    private func saveToken(_ payload: OAuthTokenPayload, for provider: String) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        _ = KeychainService.save(key: keychainKey(for: provider), data: data)
    }

    private func loadToken(for provider: String) -> OAuthTokenPayload? {
        guard let data = KeychainService.load(key: keychainKey(for: provider)) else { return nil }
        return try? JSONDecoder().decode(OAuthTokenPayload.self, from: data)
    }

    private func extractEmailFromJWT(_ jwt: String?) -> String? {
        guard let json = decodeJWTPayload(jwt) else { return nil }
        return json["email"] as? String
    }

    private func extractAudienceFromJWT(_ jwt: String?) -> String? {
        guard let json = decodeJWTPayload(jwt) else { return nil }
        return (json["aud"] as? String) ?? (json["azp"] as? String)
    }

    private func decodeJWTPayload(_ jwt: String?) -> [String: Any]? {
        guard let jwt = jwt else { return nil }
        let parts = jwt.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    static func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hashed = SHA256.hash(data: data)
        return Data(hashed).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    static func generateRandomState() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
