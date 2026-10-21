import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    var usage: GrokUsage?
    /// ChatGPT/Codex plan quota (independent of Grok usage).
    var codex: CodexUsage?
    var codexError: String?
    var lastError: String?
    var isRefreshing = false
    var launchAtLoginEnabled: Bool = LaunchAtLogin.isEnabled

    /// Which quota drives the compact menu-bar title.
    enum BarSource: String, Sendable {
        case bot = "", build = "B", codex = "C"
    }

    struct BarTitle: Equatable, Sendable {
        /// Short number like "42%", or a tiny status ("!", "link"); empty = icon only.
        var value: String
        /// Tiny tag after the number: "B" (Grok Build), "C" (Codex), "" (Grok Bot).
        var tag: String
    }

    /// Ultra-compact menu-bar title: only the most-constrained quota (highest used %)
    /// across Grok Bot, Grok Build, and Codex (5h / weekly), e.g. "42%", "64%" + B, "78%" + C.
    /// Unavailable sources are skipped; the full breakdown lives in the dropdown and tooltip.
    var barTitle: BarTitle {
        Self.formatBarTitle(usage: usage, codex: codex, hasError: lastError != nil)
    }

    /// Plain-text form of `barTitle` (e.g. "42%", "64%B", "78%C").
    var titleText: String {
        let t = barTitle
        return t.value + t.tag
    }

    static func formatBarTitle(usage: GrokUsage?, codex: CodexUsage?, hasError: Bool) -> BarTitle {
        var candidates: [(BarSource, Double)] = []
        if let usage {
            if !usage.needsSuperGrokLink, let bot = usage.botPercent, bot.isFinite { candidates.append((.bot, bot)) }
            if let build = usage.grokPercent, build.isFinite { candidates.append((.build, build)) }
            if candidates.isEmpty, !usage.needsSuperGrokLink, usage.usedPercent.isFinite {
                candidates.append((.build, usage.usedPercent))
            }
        }
        if let codex {
            let worst = [codex.primary?.usedPercent, codex.secondary?.usedPercent]
                .compactMap { $0 }.filter(\.isFinite).max()
            if let worst { candidates.append((.codex, worst)) }
        }
        // Highest used % wins; ties keep the earlier source (Bot, then Build, then Codex).
        var best: (BarSource, Double)?
        for c in candidates where best == nil || c.1.rounded() > best!.1.rounded() {
            best = c
        }
        if let best {
            return BarTitle(value: percentLabel(best.1), tag: best.0.rawValue)
        }
        if usage?.needsSuperGrokLink == true { return BarTitle(value: "link", tag: "") }
        if hasError { return BarTitle(value: "!", tag: "") }
        return BarTitle(value: "", tag: "")
    }

    /// Codex unavailable for a reason worth surfacing (not just "not set up").
    static func codexHasError(_ codex: CodexUsage?, error: String?) -> Bool {
        if let codex, codex.primary != nil || codex.secondary != nil { return false }
        guard let error else { return false }
        return !(error.contains("not logged in") || error.contains("API key"))
    }

    static func percentLabel(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return "\(Int(value.rounded()))%"
    }

    static func formatPercentLine(name: String, percent: Double?, resetsAt: Date?, placeholder: String? = nil) -> String {
        let pct: String
        if let percent {
            pct = percentLabel(percent)
        } else if let placeholder {
            pct = placeholder
        } else {
            pct = "—"
        }
        var title = "\(name): \(pct)"
        if let resetsAt, percent != nil {
            title += " · resets \(formatReset(resetsAt))"
        }
        return title
    }

    var statusSymbolColor: NSColor {
        guard let usage else {
            return lastError == nil ? .secondaryLabelColor : .systemRed
        }
        switch usage.status {
        case .healthy: return .systemGreen
        case .warning: return .systemYellow
        case .danger: return .systemOrange
        case .critical: return .systemRed
        case .unknown: return .secondaryLabelColor
        }
    }

    private let client = GrokBillingClient()
    private let botClient = CursorBotClient()
    private let codexClient = CodexUsageClient()
    private var refreshTask: Task<Void, Never>?
    private let refreshInterval: Duration = .seconds(60)

    func start() {
        LaunchAtLogin.syncFromDisk()
        launchAtLoginEnabled = LaunchAtLogin.isEnabled
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.refreshInterval ?? .seconds(60))
                await self?.refresh()
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() async {
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let previous = usage
        async let grokUsage = try? client.fetchUsage()
        async let botStatus = try? botClient.fetchStatus()
        let fetchedGrok = await grokUsage
        let fetchedBot = await botStatus
        do {
            codex = try await codexClient.fetchUsage()
            codexError = nil
        } catch {
            codexError = error.localizedDescription
            if case CodexError.notLoggedIn = error { codex = nil }
        }
        let grok = fetchedGrok ?? Self.preservedGrok(from: previous)
        let bot = fetchedBot ?? Self.preservedBot(from: previous)
        usage = Self.combine(grok: grok, bot: bot)

        if grok == nil && bot == nil {
            lastError = "Could not fetch Grok or Grok Bot usage."
        } else if fetchedGrok == nil && grok == nil {
            lastError = "Could not fetch Grok Build usage."
        } else if fetchedBot == nil && bot == nil {
            lastError = "Could not fetch Grok Bot usage."
        } else {
            lastError = nil
        }
        StatusItemController.shared.updateAppearance()
    }

    private static func preservedGrok(from usage: GrokUsage?) -> GrokUsage? {
        guard let usage, let pct = usage.grokPercent else { return nil }
        return GrokUsage(
            usedPercent: pct,
            resetsAt: usage.grokResetsAt ?? usage.resetsAt,
            email: usage.email,
            loginMethod: usage.loginMethod,
            teamID: usage.teamID,
            fetchedAt: usage.fetchedAt,
            grokPercent: pct,
            grokResetsAt: usage.grokResetsAt ?? usage.resetsAt
        )
    }

    private static func preservedBot(from usage: GrokUsage?) -> CursorBotStatus? {
        guard let usage else { return nil }
        if usage.needsSuperGrokLink {
            return CursorBotStatus(
                usagePercent: nil,
                resetsAt: usage.botResetsAt,
                periodStart: nil,
                includedLimitZero: true,
                hasNonZeroIncludedLimit: false,
                hasAvailableUsage: false,
                grokPlanLabel: usage.loginMethod,
                cursorEmail: usage.email
            )
        }
        guard let pct = usage.botPercent else { return nil }
        return CursorBotStatus(
            usagePercent: pct,
            resetsAt: usage.botResetsAt,
            periodStart: nil,
            includedLimitZero: false,
            hasNonZeroIncludedLimit: true,
            hasAvailableUsage: true,
            grokPlanLabel: usage.loginMethod,
            cursorEmail: usage.email
        )
    }

    private static func combine(
        grok grokUsage: GrokUsage?,
        bot botStatus: CursorBotStatus?
    ) -> GrokUsage? {

        if let botStatus, botStatus.hasBotAllowance, let pct = botStatus.usagePercent {
            var u = grokUsage ?? GrokUsage(
                usedPercent: pct,
                resetsAt: botStatus.resetsAt,
                email: botStatus.cursorEmail,
                loginMethod: botStatus.grokPlanLabel ?? "Grok Bot",
                teamID: nil,
                fetchedAt: Date()
            )
            u.botPercent = pct
            u.botResetsAt = botStatus.resetsAt
            u.grokPercent = grokUsage?.usedPercent ?? grokUsage?.grokPercent
            u.grokResetsAt = grokUsage?.grokResetsAt ?? grokUsage?.resetsAt
            u.usedPercent = [u.botPercent, u.grokPercent].compactMap { $0 }.max() ?? pct
            u.resetsAt = u.botResetsAt ?? u.grokResetsAt ?? u.resetsAt
            u.needsSuperGrokLink = false
            u.source = .grokBot
            u.loginMethod = botStatus.grokPlanLabel ?? grokUsage?.loginMethod ?? "Grok Bot"
            if let email = botStatus.cursorEmail, u.email == nil { u.email = email }
            u.fetchedAt = Date()
            return u
        }

        if let botStatus, botStatus.includedLimitZero || !botStatus.hasBotAllowance {
            var u = grokUsage ?? GrokUsage(
                usedPercent: grokUsage?.usedPercent ?? 0,
                resetsAt: grokUsage?.resetsAt ?? botStatus.resetsAt,
                email: botStatus.cursorEmail ?? grokUsage?.email,
                loginMethod: "Link SuperGrok",
                teamID: grokUsage?.teamID,
                fetchedAt: Date()
            )
            u.grokPercent = grokUsage?.usedPercent ?? grokUsage?.grokPercent
            u.grokResetsAt = grokUsage?.grokResetsAt ?? grokUsage?.resetsAt
            u.botPercent = nil
            u.botResetsAt = botStatus.resetsAt
            u.needsSuperGrokLink = true
            u.source = .needsLink
            u.loginMethod = "Link SuperGrok"
            if let email = botStatus.cursorEmail { u.email = email }
            u.fetchedAt = Date()
            return u
        }

        if var u = grokUsage {
            u.grokPercent = u.usedPercent
            u.grokResetsAt = u.resetsAt
            u.source = .grokCredits
            return u
        }
        return nil
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        LaunchAtLogin.isEnabled = enabled
        launchAtLoginEnabled = LaunchAtLogin.isEnabled
    }

    func openGrokUsage() {
        if let url = URL(string: "https://grok.com/?_s=usage") {
            NSWorkspace.shared.open(url)
        }
    }

    func openBotSpending() {
        if let url = URL(string: "https://cursor.com/dashboard/spending") {
            NSWorkspace.shared.open(url)
        }
    }

    func openLinkSuperGrok() {
        if let url = URL(string: "https://cursor.com/promos/super-grok") {
            NSWorkspace.shared.open(url)
        }
    }

    func openGrokBotPlan() {
        if let url = URL(string: "grokbot://app/v1/settings?id=plan") {
            NSWorkspace.shared.open(url)
        }
    }

    func openGrokHome() {
        if let url = URL(string: "https://grok.com") {
            NSWorkspace.shared.open(url)
        }
    }

    static func formatReset(_ date: Date?) -> String {
        guard let date else { return "Unknown" }
        let remaining = date.timeIntervalSinceNow
        if remaining <= 0 { return "Soon" }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func formatFetched(_ date: Date?) -> String {
        guard let date else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
