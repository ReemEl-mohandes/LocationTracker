import CryptoKit
import Foundation

enum APIError: LocalizedError {
    case badServerURL
    case invalidCredentials
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int, message: String?)
    case missingSessionCookies

    var errorDescription: String? {
        switch self {
        case .badServerURL: return "The server address is not a valid https:// URL."
        case .invalidCredentials: return "Invalid email or password."
        case .unauthorized: return "Your session has ended. Please sign in again."
        case .rateLimited: return "Too many requests. Please wait a moment."
        case .server(let status, let message): return message ?? "Server error (\(status))."
        case .missingSessionCookies: return "The server did not return a session."
        }
    }
}

extension Notification.Name {
    /// Posted when the refresh token is rejected: the session is over and the user must sign in.
    static let sessionExpired = Notification.Name("LocationTrackerClient.sessionExpired")
}

/// Talks to the Location Tracker API.
///
/// The server issues its tokens only as cookies. Rather than lean on URLSession's cookie
/// jar (whose SameSite=Strict handling for non-browser requests is not something to depend
/// on), the client lifts the three values out of Set-Cookie, keeps them in the Keychain, and:
///   * sends the access token as `Authorization: Bearer` — the server accepts either, and a
///     bearer request carries no cookie, so the CSRF check does not apply to it;
///   * sends the refresh token back as a cookie, with the CSRF cookie and matching
///     X-CSRF-Token header, only when refreshing or signing out.
final class APIClient: NSObject, @unchecked Sendable {
    static let shared = APIClient()

    // Assigned once in init and never mutated, which is what makes the unchecked Sendable safe.
    private var session: URLSession!
    private let refresher = SingleFlight()

    private override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = nil
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    private enum Credentials {
        case none
        case bearer
        case sessionCookies(SessionTokens)
    }

    // MARK: - Auth

    func login(email: String, password: String) async throws -> UserProfile {
        let body = try JSON.encoder.encode(LoginRequest(email: email, password: password))
        let (data, response) = try await perform("POST", "/api/auth/login", body: body, credentials: .none)
        if response.statusCode == 401 { throw APIError.invalidCredentials }
        try check(data, response)
        try storeSession(from: response)
        return try profile(from: data)
    }

    func register(email: String, password: String, displayName: String) async throws -> UserProfile {
        let body = try JSON.encoder.encode(RegisterRequest(email: email, password: password, displayName: displayName))
        let (data, response) = try await perform("POST", "/api/auth/register", body: body, credentials: .none)
        try check(data, response)
        try storeSession(from: response)
        return try profile(from: data)
    }

    func me() async throws -> UserProfile {
        let data = try await authorized("GET", "/api/auth/me")
        return try JSON.decoder.decode(UserProfile.self, from: data)
    }

    /// Best effort: the local session is discarded whether or not the server is reachable.
    func logout() async {
        if let tokens = TokenStore.load() {
            _ = try? await perform("POST", "/api/auth/logout", body: nil, credentials: .sessionCookies(tokens))
        }
        TokenStore.clear()
    }

    // MARK: - Locations and trips

    func uploadBatch(_ points: [LocationPoint]) async throws -> BatchIngestResponse {
        let body = try JSON.encoder.encode(LocationBatchRequest(points: points))
        let data = try await authorized("POST", "/api/locations/batch", body: body)
        return try JSON.decoder.decode(BatchIngestResponse.self, from: data)
    }

    func myTrips(pageSize: Int = 20) async throws -> [Trip] {
        let data = try await authorized("GET", "/api/trips/me?pageSize=\(pageSize)")
        return try JSON.decoder.decode(PagedResult<Trip>.self, from: data).items
    }

    func myActiveTrip() async throws -> Trip? {
        let data = try await authorized("GET", "/api/trips/me/active")
        return data.isEmpty ? nil : try JSON.decoder.decode(Trip.self, from: data)
    }

    // MARK: - Plumbing

    /// Sends with the access token; on a 401 refreshes once and retries.
    private func authorized(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        let (data, response) = try await perform(method, path, body: body, credentials: .bearer)
        if response.statusCode != 401 {
            try check(data, response)
            return data
        }

        try await refreshSession()

        let (retryData, retryResponse) = try await perform(method, path, body: body, credentials: .bearer)
        try check(retryData, retryResponse)
        return retryData
    }

    /// Refresh tokens rotate on every use and the server treats reuse of a spent one as theft,
    /// revoking the whole chain. Concurrent 401s must therefore share one refresh, not race.
    private func refreshSession() async throws {
        try await refresher.run { [self] in
            guard let tokens = TokenStore.load() else { throw APIError.unauthorized }

            let (data, response) = try await perform("POST", "/api/auth/refresh", body: nil,
                                                     credentials: .sessionCookies(tokens))
            if response.statusCode == 401 {
                TokenStore.clear()
                NotificationCenter.default.post(name: .sessionExpired, object: nil)
                throw APIError.unauthorized
            }
            // Anything else (offline, 429, 5xx) leaves the session intact to try again later.
            try check(data, response)
            try storeSession(from: response)
        }
    }

    private func perform(_ method: String, _ path: String, body: Data?,
                         credentials: Credentials) async throws -> (Data, HTTPURLResponse) {
        guard let base = URL(string: ServerSettings.serverURL), base.scheme == "https",
              let url = URL(string: path, relativeTo: base) else {
            throw APIError.badServerURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        switch credentials {
        case .none:
            break
        case .bearer:
            if let tokens = TokenStore.load() {
                request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
            }
        case .sessionCookies(let tokens):
            request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("refresh_token=\(tokens.refreshToken); csrf_token=\(tokens.csrfToken)",
                             forHTTPHeaderField: "Cookie")
            request.setValue(tokens.csrfToken.removingPercentEncoding ?? tokens.csrfToken,
                             forHTTPHeaderField: "X-CSRF-Token")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.server(status: -1, message: "Unexpected response.")
        }
        return (data, http)
    }

    private func check(_ data: Data, _ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            throw APIError.unauthorized
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) }
            throw APIError.rateLimited(retryAfter: retryAfter)
        default:
            let body = try? JSON.decoder.decode(ServerErrorBody.self, from: data)
            let details = body?.errors?.values.flatMap { $0 }.joined(separator: " ")
            let message = [body?.message, details].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            throw APIError.server(status: response.statusCode, message: message.isEmpty ? nil : message)
        }
    }

    private func storeSession(from response: HTTPURLResponse) throws {
        guard let url = response.url,
              let headers = response.allHeaderFields as? [String: String] else {
            throw APIError.missingSessionCookies
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        func value(_ name: String) -> String? { cookies.first { $0.name == name }?.value }

        guard let access = value("access_token"),
              let refresh = value("refresh_token"),
              let csrf = value("csrf_token") else {
            throw APIError.missingSessionCookies
        }
        TokenStore.save(SessionTokens(accessToken: access, refreshToken: refresh, csrfToken: csrf))
    }

    private func profile(from data: Data) throws -> UserProfile {
        let auth = try JSON.decoder.decode(AuthResponse.self, from: data)
        return UserProfile(id: auth.id, email: auth.email, displayName: auth.displayName, roles: auth.roles)
    }
}

// MARK: - TLS

extension APIClient: URLSessionDelegate {
    /// The development server uses a self-signed certificate that names only "localhost",
    /// while the phone reaches it by LAN IP, so ordinary validation fails on both counts.
    /// Instead of disabling validation, accept exactly one certificate: the one whose
    /// SHA-256 fingerprint is pinned in AppConfig. Anything else is refused.
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }

        if SecTrustEvaluateWithError(trust, nil) {
            return (.performDefaultHandling, nil)
        }

        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            return (.cancelAuthenticationChallenge, nil)
        }

        let fingerprint = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
            .map { String(format: "%02X", $0) }
            .joined(separator: ":")

        guard fingerprint == AppConfig.pinnedCertificateSHA256.uppercased() else {
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}

/// Runs at most one operation at a time; callers arriving while it is in flight await the
/// same result instead of starting their own.
private actor SingleFlight {
    private var current: Task<Void, Error>?

    func run(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        if let current {
            return try await current.value
        }
        let task = Task { try await operation() }
        current = task
        defer { current = nil }
        try await task.value
    }
}
