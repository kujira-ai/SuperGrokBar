import Foundation

/// One Codex rate-limit window (e.g. 5-hour primary, weekly secondary).
struct CodexWindow: Equatable, Sendable {
    var usedPercent: Double
    var windowMinutes: Int?
    var resetsAt: Date?

    var remainingPercent: Double { max(0, 100 - usedPercent) }
}

struct CodexUsage: Equatable, Sendable {
    enum Source: String, Sendable { case api, sessionLog = "session_log" }
    var primary: CodexWindow?
    var secondary: CodexWindow?
    var planType: String?
    var limitReached: Bool?
    var source: Source
    var fetchedAt: Date
}

enum CodexError: LocalizedError {
    case notLoggedIn(String)
    case apiKeyMode
    case noData

    var errorDescription: String? {
        switch self {
        case .notLoggedIn(let path): return "Codex not logged in. Run `codex login` (missing \(path))."
        case .apiKeyMode: return "Codex uses an API key, not a ChatGPT login; no plan quota."
        case .noData: return "No Codex rate-limit data found."
        }
    }
}

/// ChatGPT/Codex plan quota. Uses the same endpoint the Codex CLI calls for `/status`
/// (`GET https://chatgpt.com/backend-api/wham/usage`, Bearer access token + `chatgpt-account-id`).
/// Falls back to the newest `rate_limits` event in `~/.codex/sessions/**/*.jsonl`.
/// Never refreshes or rewrites `~/.codex/auth.json`.
actor CodexUsageClient {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    static var codexHome: URL {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    func fetchUsage() async throws -> CodexUsage {
        do {
            return try await fetchFromAPI()
        } catch let apiError {
            if case CodexError.notLoggedIn = apiError { throw apiError }
            if case CodexError.apiKeyMode = apiError { throw apiError }
            if let fallback = Self.latestFromSessions() { return fallback }
            throw apiError
        }
    }

    private func fetchFromAPI() async throws -> CodexUsage {
        let authURL = Self.codexHome.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CodexError.notLoggedIn(authURL.path) }
        guard let tokens = root["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty
        else {
            if let key = root["OPENAI_API_KEY"] as? String, !key.isEmpty { throw CodexError.apiKeyMode }
            throw CodexError.notLoggedIn(authURL.path)
        }

        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.timeoutInterval = 10
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        if let account = tokens["account_id"] as? String, !account.isEmpty {
            request.setValue(account, forHTTPHeaderField: "chatgpt-account-id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SuperGrokBar/1.2.2", forHTTPHeaderField: "User-Agent")

        let (body, response): (Data, URLResponse)
        do {
            (body, response) = try await session.data(for: request)
        } catch {
            throw GrokError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw GrokError.network("Invalid response") }
        if http.statusCode == 401 || http.statusCode == 403 { throw GrokError.unauthorized }
        guard http.statusCode == 200 else {
            throw GrokError.server(http.statusCode, String(data: body.prefix(200), encoding: .utf8) ?? "")
        }
        guard let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw GrokError.parseFailed
        }
        let rl = obj["rate_limit"] as? [String: Any]
        let primary = Self.apiWindow(rl?["primary_window"])
        let secondary = Self.apiWindow(rl?["secondary_window"])
        if primary == nil && secondary == nil { throw CodexError.noData }
        return CodexUsage(
            primary: primary,
            secondary: secondary,
            planType: obj["plan_type"] as? String,
            limitReached: rl?["limit_reached"] as? Bool,
            source: .api,
            fetchedAt: Date()
        )
    }

    private static func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    private static func apiWindow(_ raw: Any?) -> CodexWindow? {
        guard let w = raw as? [String: Any], let used = num(w["used_percent"]) else { return nil }
        let reset: Date?
        if let at = num(w["reset_at"]) {
            reset = Date(timeIntervalSince1970: at)
        } else if let after = num(w["reset_after_seconds"]) {
            reset = Date().addingTimeInterval(after)
        } else {
            reset = nil
        }
        let minutes = num(w["limit_window_seconds"]).map { Int($0 / 60) }
        return CodexWindow(usedPercent: used, windowMinutes: minutes, resetsAt: reset)
    }

    private static func sessionWindow(_ raw: Any?) -> CodexWindow? {
        guard let w = raw as? [String: Any], let used = num(w["used_percent"]) else { return nil }
        let reset = num(w["resets_at"]).map { Date(timeIntervalSince1970: $0) }
        return CodexWindow(usedPercent: used, windowMinutes: num(w["window_minutes"]).map { Int($0) }, resetsAt: reset)
    }

    /// Newest `rate_limits` payload from Codex session logs (token_count events).
    static func latestFromSessions() -> CodexUsage? {
        let dir = codexHome.appendingPathComponent("sessions")
        let fm = FileManager.default
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var files: [(URL, Date)] = []
        for case let url as URL in e where url.pathExtension == "jsonl" {
            let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            files.append((url, d))
        }
        for (url, mtime) in files.sorted(by: { $0.1 > $1.1 }).prefix(10) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let rl = findRateLimits(obj)
                else { continue }
                let p = sessionWindow(rl["primary"]), s = sessionWindow(rl["secondary"])
                if p == nil && s == nil { continue }
                return CodexUsage(primary: p, secondary: s, planType: rl["plan_type"] as? String,
                                  limitReached: nil, source: .sessionLog, fetchedAt: mtime)
            }
        }
        return nil
    }

    private static func findRateLimits(_ obj: Any) -> [String: Any]? {
        if let d = obj as? [String: Any] {
            if let rl = d["rate_limits"] as? [String: Any] { return rl }
            for v in d.values { if let r = findRateLimits(v) { return r } }
        } else if let a = obj as? [Any] {
            for v in a { if let r = findRateLimits(v) { return r } }
        }
        return nil
    }
}
