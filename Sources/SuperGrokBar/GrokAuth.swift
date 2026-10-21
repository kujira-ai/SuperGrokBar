import Foundation

/// Credentials loaded from `~/.grok/auth.json` (or `$GROK_HOME/auth.json`).
struct GrokCredentials: Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var scope: String
    var authMode: String
    var userID: String?
    var email: String?
    var firstName: String?
    var lastName: String?
    var teamID: String?
    var expiresAt: Date?
    var sourcePath: String
    var oidcIssuer: String? = nil
    var oidcClientID: String? = nil

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }

    /// Expired, or expiring within `leeway` seconds.
    func needsRefresh(leeway: TimeInterval = GrokTokenRefresher.leeway) -> Bool {
        guard let expiresAt else { return false }
        return Date().addingTimeInterval(leeway) >= expiresAt
    }

    var canRefresh: Bool {
        guard let refreshToken, !refreshToken.isEmpty else { return false }
        return (oidcClientID ?? GrokAuthStore.clientID(fromScope: scope)) != nil
    }

    /// Friendly plan label: SuperGrok for OIDC, else raw mode / session.
    var loginMethod: String {
        switch authMode.lowercased() {
        case "oidc": return "SuperGrok"
        case "session": return "Session"
        case "": return scope.isEmpty ? "Unknown" : "Session"
        default: return authMode
        }
    }

    var displayName: String {
        let parts = [firstName, lastName].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }
}

enum GrokAuthStore {
    static let oidcPrefix = "https://auth.x.ai::"
    private static let legacyScope = "https://accounts.x.ai/sign-in"

    static var grokHome: URL {
        if let custom = ProcessInfo.processInfo.environment["GROK_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok", isDirectory: true)
    }

    static var authFileURL: URL {
        grokHome.appendingPathComponent("auth.json", isDirectory: false)
    }

    /// Prefer OIDC SuperGrok entry; fall back to legacy session scope.
    static func loadCredentials() throws -> GrokCredentials {
        let path = authFileURL
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw GrokError.notLoggedIn(path.path)
        }
        let data = try Data(contentsOf: path)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GrokError.invalidAuthFile
        }

        var oidc: GrokCredentials?
        var legacy: GrokCredentials?
        var any: GrokCredentials?

        for (scope, value) in root {
            guard let entry = value as? [String: Any],
                  let key = entry["key"] as? String,
                  !key.isEmpty else { continue }

            let creds = parseEntry(scope: scope, entry: entry, sourcePath: path.path)
            if scope.hasPrefix(oidcPrefix) {
                oidc = creds
            } else if scope == legacyScope {
                legacy = creds
            } else if any == nil {
                any = creds
            }
        }

        if let oidc { return oidc }
        if let legacy { return legacy }
        if let any { return any }
        throw GrokError.notLoggedIn(path.path)
    }

    /// `https://auth.x.ai::<client_id>` → client id.
    static func clientID(fromScope scope: String) -> String? {
        guard let range = scope.range(of: "::") else { return nil }
        let id = String(scope[range.upperBound...])
        return id.isEmpty ? nil : id
    }

    static func parseDate(_ raw: String) -> Date? {
        if let d = ISO8601DateFormatter.grok.date(from: raw) ?? ISO8601DateFormatter.grokFractional.date(from: raw) {
            return d
        }
        // Grok writes microseconds (`…:29.263832Z`); trim to millis for Foundation.
        if let dot = raw.firstIndex(of: "."), let z = raw.lastIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }), z > dot {
            let frac = raw[raw.index(after: dot)..<z].prefix(3)
            let trimmed = String(raw[..<dot]) + "." + frac + String(raw[z...])
            return ISO8601DateFormatter.grokFractional.date(from: trimmed)
        }
        return nil
    }

    /// Same shape Grok writes: UTC, 6 fractional digits, `Z`.
    static func formatDate(_ date: Date) -> String {
        let secs = floor(date.timeIntervalSince1970)
        let micros = Int(((date.timeIntervalSince1970 - secs) * 1_000_000).rounded()) % 1_000_000
        let base = ISO8601DateFormatter.grokUTC.string(from: Date(timeIntervalSince1970: secs))
        // base ends with "Z"
        return String(base.dropLast()) + String(format: ".%06dZ", micros)
    }

    private static func parseEntry(scope: String, entry: [String: Any], sourcePath: String) -> GrokCredentials {
        var expires: Date?
        if let raw = entry["expires_at"] as? String {
            expires = parseDate(raw)
        } else if let n = entry["expires_at"] as? Double {
            expires = Date(timeIntervalSince1970: n > 10_000_000_000 ? n / 1000 : n)
        }
        return GrokCredentials(
            accessToken: entry["key"] as? String ?? "",
            refreshToken: entry["refresh_token"] as? String,
            scope: scope,
            authMode: entry["auth_mode"] as? String ?? "",
            userID: entry["user_id"] as? String,
            email: entry["email"] as? String,
            firstName: entry["first_name"] as? String,
            lastName: entry["last_name"] as? String,
            teamID: entry["team_id"] as? String,
            expiresAt: expires,
            sourcePath: sourcePath,
            oidcIssuer: entry["oidc_issuer"] as? String,
            oidcClientID: entry["oidc_client_id"] as? String
        )
    }
}

private extension ISO8601DateFormatter {
    nonisolated(unsafe) static let grokUTC: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    nonisolated(unsafe) static let grok: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    nonisolated(unsafe) static let grokFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
