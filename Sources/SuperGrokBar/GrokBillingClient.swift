import Foundation

enum UsageSource: String, Sendable {
    case grokBot
    case grokCredits
    case needsLink
}

struct GrokUsage: Equatable, Sendable {
    var usedPercent: Double
    var resetsAt: Date?
    var email: String?
    var loginMethod: String
    var teamID: String?
    var fetchedAt: Date
    var grokPercent: Double?
    var grokResetsAt: Date?
    var botPercent: Double?
    var botResetsAt: Date?
    var needsSuperGrokLink: Bool = false
    var source: UsageSource = .grokCredits

    /// Higher of the two pools — drives the menu-bar color.
    var headlinePercent: Double {
        [botPercent, grokPercent].compactMap { $0 }.max() ?? usedPercent
    }

    var status: UsageStatus {
        if needsSuperGrokLink && grokPercent == nil { return .unknown }
        switch headlinePercent {
        case ..<50: return .healthy
        case ..<80: return .warning
        case ..<95: return .danger
        default: return .critical
        }
    }
}

enum UsageStatus: String, Sendable {
    case healthy, warning, danger, critical, unknown
}

actor GrokBillingClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// - Parameter forceRefresh: refresh the OIDC token first even if it still looks valid.
    func fetchUsage(forceRefresh: Bool = false) async throws -> GrokUsage {
        var creds = try await GrokTokenRefresher.shared.validCredentials(force: forceRefresh)
        if creds.isExpired {
            throw GrokError.unauthorized
        }

        var (data, status) = try await requestBilling(token: creds.accessToken)
        if status == 401 && creds.canRefresh && !forceRefresh {
            // Server rejected a token we thought was valid: refresh once and retry.
            creds = try await GrokTokenRefresher.shared.validCredentials(force: true, reason: .rejected)
            (data, status) = try await requestBilling(token: creds.accessToken)
        }
        if status == 401 || status == 403 {
            throw GrokError.unauthorized
        }
        guard status == 200 else {
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw GrokError.server(status, body)
        }
        if data.isEmpty {
            throw GrokError.emptyResponse
        }

        try GRPCWebParser.validateTrailers(data)
        let snap = try parseBilling(data)

        return GrokUsage(
            usedPercent: snap.percent,
            resetsAt: snap.resetsAt,
            email: creds.email,
            loginMethod: creds.loginMethod,
            teamID: creds.teamID,
            fetchedAt: Date()
        )
    }

    private func requestBilling(token: String) async throws -> (Data, Int) {
        let endpoint = URL(string: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        // Empty protobuf message frame: flags=0, length=0
        request.httpBody = Data([0x00, 0x00, 0x00, 0x00, 0x00])
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        request.setValue("https://grok.com/?_s=usage", forHTTPHeaderField: "Referer")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "x-grpc-web")
        request.setValue("connect-es/2.1.1", forHTTPHeaderField: "x-user-agent")
        request.setValue(AppVersion.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GrokError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw GrokError.network("Invalid response")
        }
        return (data, http.statusCode)
    }

    private struct Parsed {
        var percent: Double
        var resetsAt: Date?
    }

    private func parseBilling(_ data: Data) throws -> Parsed {
        var payloads = GRPCWebParser.frames(from: data)
            .filter { $0.flags & 0x80 == 0 }
            .map(\.payload)
        if payloads.isEmpty {
            payloads = [data]
        }

        var scan = ProtobufScan()
        for payload in payloads {
            scan.merge(ProtobufScanner.scan(payload))
        }

        // Prefer fixed32 at path ending with field 1, range 0...100 (shallowest path wins)
        var best: (value: Float, depth: Int)?
        for hit in scan.fixed32 {
            guard let last = hit.path.last, last == 1 else { continue }
            guard hit.value >= 0, hit.value <= 100 else { continue }
            let depth = hit.path.count
            if best == nil || depth < best!.depth {
                best = (hit.value, depth)
            }
        }

        let now = Date()
        var resets: [(path: [UInt64], date: Date)] = []
        for hit in scan.varints {
            // plausible unix seconds
            guard hit.value > 1_700_000_000, hit.value < 2_100_000_000 else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(hit.value))
            if date > now {
                resets.append((hit.path, date))
            }
        }

        // Prefer exact path [1,5,1] (period end)
        var chosen: Date?
        if let match = resets.first(where: { $0.path == [1, 5, 1] }) {
            chosen = match.date
        } else if let earliest = resets.map(\.date).min() {
            chosen = earliest
        }

        guard let best else {
            // no usage yet but we saw a future reset
            if chosen != nil {
                return Parsed(percent: 0, resetsAt: chosen)
            }
            throw GrokError.parseFailed
        }

        return Parsed(percent: Double(best.value), resetsAt: chosen)
    }
}
