import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    var usage: GrokUsage?
    var lastError: String?
    var isRefreshing = false
    var launchAtLoginEnabled: Bool = LaunchAtLogin.isEnabled

    /// Compact menubar title, e.g. "87%" or "—"
    var titleText: String {
        if let usage {
            return "\(Int(usage.usedPercent.rounded()))%"
        }
        if lastError != nil {
            return "!"
        }
        return "…"
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
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            usage = try await client.fetchUsage()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            // keep last good usage visible if we have one
        }
        StatusItemController.shared.updateAppearance()
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
