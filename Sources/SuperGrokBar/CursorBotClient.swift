import Foundation

/// Grok Bot weekly included usage from Cursor (`POST /api/dashboard/get-sand-usage-status`).
/// Bot usage is metered on the Cursor account, not grok.com.
struct CursorBotStatus: Equatable, Sendable {
    var usagePercent: Double?
    var resetsAt: Date?
    var periodStart: Date?
    var includedLimitZero: Bool
    var hasNonZeroIncludedLimit: Bool
    var hasAvailableUsage: Bool?
    var grokPlanLabel: String?
    var cursorEmail: String?

    var hasBotAllowance: Bool {
        if hasNonZeroIncludedLimit { return true }
        if includedLimitZero { return false }
        return usagePercent != nil
    }
}

actor CursorBotClient {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func fetchStatus() async throws -> CursorBotStatus {
        // Prefer Grok Bot's SuperGrok-linked session over Cursor.app (often a different free account).
        let token: String
        let email: String?
        if let grokTok = try? GrokBotSession.loadAccessToken() {
            token = grokTok
            email = nil
        } else {
            token = try CursorAppAuth.loadAccessToken()
            email = CursorAppAuth.cachedEmail()
        }
        let cookie = try CursorAppAuth.cookieHeader(for: token)

        let url = URL(string: "https://cursor.com/api/dashboard/get-sand-usage-status")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("SuperGrokBar/1.1.1", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GrokError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw GrokError.network("Invalid response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw GrokError.unauthorized
        }
        guard http.statusCode == 200 else {
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw GrokError.server(http.statusCode, body)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GrokError.parseFailed
        }

        let percent: Double?
        if let n = obj["usagePercent"] as? Double {
            percent = n
        } else if let n = obj["usagePercent"] as? Int {
            percent = Double(n)
        } else if let s = obj["usagePercent"] as? String, let n = Double(s) {
            percent = n
        } else {
            percent = nil
        }

        return CursorBotStatus(
            usagePercent: percent,
            resetsAt: Self.parseISO8601(obj["nextResetTimestampUtc"] as? String),
            periodStart: Self.parseISO8601(obj["currentPeriodStart"] as? String),
            includedLimitZero: obj["includedLimitZero"] as? Bool ?? false,
            hasNonZeroIncludedLimit: obj["hasNonZeroIncludedLimit"] as? Bool ?? false,
            hasAvailableUsage: obj["hasAvailableUsage"] as? Bool,
            grokPlanLabel: (obj["grokPlanLabel"] as? String)
                ?? (obj["includedUsageSuperGrokPlan"] as? String),
            cursorEmail: email
        )
    }

    private static func parseISO8601(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}
