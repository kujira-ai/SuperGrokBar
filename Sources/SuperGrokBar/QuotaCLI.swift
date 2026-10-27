import Foundation
import Security

/// Headless `SuperGrokBar quota [--json]`: query every provider without launching the UI.
///
/// Grok Bot usage needs the "Grok Bot Safe Storage" Keychain key. Headless callers (agents,
/// scripts) are a different process than the menu bar app, so reading the Keychain from here
/// would raise a macOS access prompt per caller/build. By default this command therefore
/// never shows Keychain UI: it uses the value the menu bar app last fetched
/// (`BotStatusCache`), or a silent Keychain read that only succeeds if this binary is
/// already trusted. `--allow-keychain` opts in to an interactive read.
private final class ResultBox: @unchecked Sendable {
    var value: (grok: Result<GrokUsage, Error>, bot: Result<BotOutcome, Error>, codex: Result<CodexUsage, Error>)?
}

struct BotOutcome: Sendable {
    var status: CursorBotStatus
    var source: String
    var cacheAge: TimeInterval?
    var stale: Bool
}

enum QuotaCLI {
    static let schemaVersion = 1

    /// The menu bar app refreshes every 60 s; a cache younger than this is used as-is.
    static let cacheFreshFor: TimeInterval = 180
    /// If the live read fails, an older cache up to this age is still returned (marked stale).
    static let cacheStaleMax: TimeInterval = 30 * 60

    static func run(_ args: [String]) -> Int32 {
        let json = args.contains("--json")
        if args.contains("--help") || args.contains("-h") {
            print("Usage: SuperGrokBar quota [--json] [--refresh-grok] [--allow-keychain]")
            print("  --refresh-grok    force a Grok Build OIDC token refresh before fetching")
            print("  --allow-keychain  read Grok Bot live from the Keychain, allowing a macOS access")
            print("                    prompt (default: use the menu bar app's cached value; never prompt)")
            return 0
        }
        let forceGrokRefresh = args.contains("--refresh-grok")
        let allowKeychain = args.contains("--allow-keychain")
        GrokBotSession.allowKeychainUI = allowKeychain
        if !allowKeychain {
            // Belt and braces for the legacy file keychain: no SecurityAgent dialogs at all.
            SecKeychainSetUserInteractionAllowed(false)
        }
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox()
        Task.detached {
            async let g = capture { try await GrokBillingClient().fetchUsage(forceRefresh: forceGrokRefresh) }
            async let b = capture { try await fetchBot(allowKeychain: allowKeychain) }
            async let c = capture { try await CodexUsageClient().fetchUsage() }
            box.value = (await g, await b, await c)
            sem.signal()
        }
        sem.wait()
        let result = box.value!

        let providers: [[String: Any]] = [grokEntry(result.grok), botEntry(result.bot), codexEntry(result.codex)]
        let okCount = providers.filter { $0["ok"] as? Bool == true }.count

        if json {
            let out: [String: Any] = [
                "schema_version": schemaVersion,
                "generated_at": iso(Date()),
                "providers": providers,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                print(String(decoding: data, as: UTF8.self))
            }
        } else {
            for p in providers { printHuman(p) }
        }
        return okCount == 0 ? 1 : 0
    }

    static func fetchBot(allowKeychain: Bool) async throws -> BotOutcome {
        if !allowKeychain, let entry = BotStatusCache.read(), entry.age <= cacheFreshFor {
            return BotOutcome(status: entry.status, source: "app-cache", cacheAge: entry.age, stale: false)
        }
        do {
            let status = try await CursorBotClient().fetchStatus()
            return BotOutcome(status: status, source: "api", cacheAge: nil, stale: false)
        } catch {
            if let entry = BotStatusCache.read(), entry.age <= cacheStaleMax {
                return BotOutcome(status: entry.status, source: "app-cache", cacheAge: entry.age, stale: true)
            }
            if !allowKeychain, case GrokError.network = error {
                throw GrokError.network("no recent value from the SuperGrok Bar menu bar app and the Keychain needs approval; start the app (`supergrok-bar start`) or run `supergrok-bar quota --allow-keychain` once interactively")
            }
            throw error
        }
    }

    private static func capture<T>(_ f: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await f()) } catch { return .failure(error) }
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    private static func window(name: String, used: Double?, resetsAt: Date?, minutes: Int?) -> [String: Any] {
        var w: [String: Any] = ["name": name]
        w["used_percent"] = used.map { NSDecimalNumber(string: String(format: "%.1f", $0)) } ?? NSNull()
        w["remaining_percent"] = used.map { NSDecimalNumber(string: String(format: "%.1f", max(0, 100 - $0))) } ?? NSNull()
        w["resets_at"] = resetsAt.map(iso) ?? NSNull()
        w["window_minutes"] = minutes ?? NSNull()
        return w
    }

    private static func base(_ id: String, _ label: String) -> [String: Any] {
        ["id": id, "label": label, "ok": false, "error": NSNull(), "plan": NSNull(), "source": NSNull(), "windows": [Any]()]
    }

    private static func grokEntry(_ r: Result<GrokUsage, Error>) -> [String: Any] {
        var e = base("grok_build", "Grok Build")
        switch r {
        case .success(let u):
            e["ok"] = true
            e["source"] = "api"
            e["windows"] = [window(name: "credits", used: u.usedPercent, resetsAt: u.resetsAt, minutes: nil)]
        case .failure(let err): e["error"] = err.localizedDescription
        }
        return e
    }

    private static func botEntry(_ r: Result<BotOutcome, Error>) -> [String: Any] {
        var e = base("grok_bot", "Grok Bot")
        switch r {
        case .success(let o):
            let s = o.status
            e["plan"] = s.grokPlanLabel ?? NSNull()
            e["source"] = o.source
            if let age = o.cacheAge {
                e["cache_age_seconds"] = Int(age.rounded())
                e["stale"] = o.stale
            }
            if s.hasBotAllowance, let pct = s.usagePercent {
                e["ok"] = true
                e["windows"] = [window(name: "weekly", used: pct, resetsAt: s.resetsAt, minutes: 10080)]
            } else {
                e["error"] = "SuperGrok not linked (no Grok Bot allowance)."
            }
        case .failure(let err): e["error"] = err.localizedDescription
        }
        return e
    }

    private static func codexEntry(_ r: Result<CodexUsage, Error>) -> [String: Any] {
        var e = base("codex", "ChatGPT / Codex")
        switch r {
        case .success(let u):
            e["ok"] = true
            e["plan"] = u.planType ?? NSNull()
            e["source"] = u.source.rawValue
            e["limit_reached"] = u.limitReached ?? NSNull()
            var ws: [[String: Any]] = []
            if let p = u.primary { ws.append(window(name: "5h", used: p.usedPercent, resetsAt: p.resetsAt, minutes: p.windowMinutes)) }
            if let s = u.secondary { ws.append(window(name: "weekly", used: s.usedPercent, resetsAt: s.resetsAt, minutes: s.windowMinutes)) }
            e["windows"] = ws
        case .failure(let err): e["error"] = err.localizedDescription
        }
        return e
    }

    private static func printHuman(_ p: [String: Any]) {
        let label = p["label"] as? String ?? "?"
        guard p["ok"] as? Bool == true else {
            print("\(label): error: \(p["error"] as? String ?? "unknown")")
            return
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm zzz"
        let isoF = ISO8601DateFormatter()
        for w in p["windows"] as? [[String: Any]] ?? [] {
            let used = (w["used_percent"] as? Double).map { "\(Int($0.rounded()))%" } ?? "—"
            let rem = (w["remaining_percent"] as? Double).map { "\(Int($0.rounded()))%" } ?? "—"
            var line = "\(label) [\(w["name"] as? String ?? "")]: \(used) used, \(rem) remaining"
            if let r = w["resets_at"] as? String, let d = isoF.date(from: r) { line += " · resets \(df.string(from: d))" }
            print(line)
        }
    }
}
