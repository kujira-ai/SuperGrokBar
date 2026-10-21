import Foundation

/// Silent OIDC refresh for the Grok Build login in `~/.grok/auth.json`.
///
/// Mirrors what the `grok` CLI does: discover `token_endpoint` from
/// `{oidc_issuer}/.well-known/openid-configuration`, then POST
/// `grant_type=refresh_token&refresh_token=…&client_id=…` (public client, no secret, no scope).
/// The new `key`, rotated `refresh_token`, and `expires_at` are written back into the same
/// scope entry; every other field is preserved and the file stays mode 0600.
/// Tokens are never logged.
actor GrokTokenRefresher {
    static let shared = GrokTokenRefresher()

    /// Refresh when expired or within this many seconds of expiry.
    static let leeway: TimeInterval = 120
    static let defaultIssuer = "https://auth.x.ai"

    private let session: URLSession
    private var tokenEndpoints: [String: URL] = [:]
    private var lastRejectedRefresh: Date?

    enum ForceReason: Sendable { case requested, rejected }

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Credentials with a usable access token, refreshing first if needed.
    /// - Parameter force: refresh even if the token looks valid (e.g. after a 401).
    func validCredentials(force: Bool = false, reason: ForceReason = .requested) async throws -> GrokCredentials {
        let creds = try GrokAuthStore.loadCredentials()
        if !force && !creds.needsRefresh() { return creds }
        // A 401 on a fresh-looking token: retry-refresh at most every 5 minutes.
        if force, reason == .rejected, !creds.needsRefresh() {
            if let last = lastRejectedRefresh, Date().timeIntervalSince(last) < 300 { return creds }
            lastRejectedRefresh = Date()
        }
        guard creds.canRefresh else {
            if creds.isExpired || force { throw GrokError.unauthorized }
            return creds
        }

        let lock = try? AuthFileLock.acquire(for: GrokAuthStore.authFileURL)
        defer { lock?.release() }

        // Another process (grok CLI, other SuperGrokBar) may have refreshed while we waited.
        let current = try GrokAuthStore.loadCredentials()
        if current.accessToken != creds.accessToken && !current.needsRefresh() {
            return current
        }
        if !force && !current.needsRefresh() { return current }
        guard current.canRefresh, let refreshToken = current.refreshToken,
              let clientID = current.oidcClientID ?? GrokAuthStore.clientID(fromScope: current.scope) else {
            throw GrokError.unauthorized
        }

        let issuer = current.oidcIssuer ?? Self.defaultIssuer
        let endpoint = await tokenEndpoint(issuer: issuer)
        let tokens = try await requestRefresh(endpoint: endpoint, refreshToken: refreshToken, clientID: clientID)
        try Self.writeBack(scope: current.scope, tokens: tokens, to: GrokAuthStore.authFileURL)
        return try GrokAuthStore.loadCredentials()
    }

    // MARK: - Discovery

    private func tokenEndpoint(issuer: String) async -> URL {
        let trimmed = issuer.hasSuffix("/") ? String(issuer.dropLast()) : issuer
        if let cached = tokenEndpoints[trimmed] { return cached }
        let fallback = URL(string: "\(trimmed)/oauth2/token")!
        guard let discovery = URL(string: "\(trimmed)/.well-known/openid-configuration") else { return fallback }
        var request = URLRequest(url: discovery)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AppVersion.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["token_endpoint"] as? String,
              let url = URL(string: raw), url.scheme == "https" else {
            return fallback
        }
        tokenEndpoints[trimmed] = url
        return url
    }

    // MARK: - Token request

    struct Tokens: Sendable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
    }

    private func requestRefresh(endpoint: URL, refreshToken: String, clientID: String) async throws -> Tokens {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AppVersion.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Self.formEncode([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", clientID),
        ])

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GrokError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw GrokError.network("Invalid response") }
        // 400 invalid_grant / 401 invalid_client → the stored login is no longer usable.
        guard http.statusCode == 200 else {
            if (400...499).contains(http.statusCode) { throw GrokError.unauthorized }
            throw GrokError.server(http.statusCode, "token refresh failed")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty else {
            throw GrokError.unauthorized
        }
        var expires: Date?
        if let secs = (json["expires_in"] as? NSNumber)?.doubleValue, secs > 0 {
            expires = Date().addingTimeInterval(secs)
        } else {
            expires = Self.jwtExpiry(access)
        }
        let rotated = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Tokens(accessToken: access, refreshToken: rotated, expiresAt: expires)
    }

    static func formEncode(_ pairs: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = pairs.map { k, v in
            "\(k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = (json["exp"] as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    // MARK: - Write-back

    /// Re-read the file, update only `key` / `refresh_token` / `expires_at` in `scope`,
    /// and atomically replace it with a 0600 file.
    static func writeBack(scope: String, tokens: Tokens, to url: URL) throws {
        let data = try Data(contentsOf: url)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var entry = root[scope] as? [String: Any] else {
            throw GrokError.invalidAuthFile
        }
        entry["key"] = tokens.accessToken
        if let rt = tokens.refreshToken { entry["refresh_token"] = rt }
        if let exp = tokens.expiresAt { entry["expires_at"] = GrokAuthStore.formatDate(exp) }
        root[scope] = entry

        var out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        out.append(0x0A)

        let target = url.resolvingSymlinksInPath()
        let dir = target.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".auth.json.supergrokbar.\(getpid()).\(UInt32.random(in: 0...UInt32.max))")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw GrokError.network("Could not write \(target.path)") }
        var ok = out.withUnsafeBytes { buf -> Bool in
            var offset = 0
            while offset < buf.count {
                let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        ok = ok && fsync(fd) == 0
        close(fd)
        guard ok, rename(tmp.path, target.path) == 0 else {
            unlink(tmp.path)
            throw GrokError.network("Could not write \(target.path)")
        }
        chmod(target.path, 0o600)
    }
}

/// Shares the `grok` CLI's auth lock: an exclusive `flock` on `~/.grok/auth.json.lock`, so
/// SuperGrokBar, the `quota` CLI, and `grok` never refresh (and rotate) the token at the same time.
/// The lock file's contents are never touched; the inode is re-checked after acquiring like grok does.
private final class AuthFileLock {
    private let fd: Int32

    private init(fd: Int32) { self.fd = fd }

    static func acquire(for authFile: URL, timeout: TimeInterval = 25) throws -> AuthFileLock {
        let path = authFile.path + ".lock"
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw GrokError.invalidAuthFile }
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                if Date() > deadline { close(fd); throw GrokError.network("auth.json lock timeout") }
                usleep(100_000)
            }
            var held = stat(), onDisk = stat()
            if fstat(fd, &held) == 0, stat(path, &onDisk) == 0, held.st_ino == onDisk.st_ino, held.st_dev == onDisk.st_dev {
                return AuthFileLock(fd: fd)
            }
            // Lock file was unlinked/recreated while we waited; retry on the new one.
            flock(fd, LOCK_UN)
            close(fd)
            if Date() > deadline { throw GrokError.network("auth.json lock timeout") }
        }
    }

    func release() {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
