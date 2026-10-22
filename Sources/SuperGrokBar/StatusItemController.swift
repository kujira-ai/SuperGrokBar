import AppKit
import os

@MainActor
final class StatusItemController: NSObject {
    static let shared = StatusItemController()

    private var statusItem: NSStatusItem?
    private let state = AppState()
    private var menu: NSMenu?

    private lazy var percentItem = NSMenuItem(title: "Grok Bot: —", action: nil, keyEquivalent: "")
    private lazy var grokCreditsItem = NSMenuItem(title: "Grok Build: —", action: nil, keyEquivalent: "")
    private lazy var codexPrimaryItem = NSMenuItem(title: "Codex 5h: —", action: nil, keyEquivalent: "")
    private lazy var codexWeeklyItem = NSMenuItem(title: "Codex weekly: —", action: nil, keyEquivalent: "")
    private lazy var planItem = NSMenuItem(title: "Plan: —", action: nil, keyEquivalent: "")
    private lazy var resetItem = NSMenuItem(title: "Resets: —", action: nil, keyEquivalent: "")
    private lazy var accountItem = NSMenuItem(title: "Account: —", action: nil, keyEquivalent: "")
    private lazy var updatedItem = NSMenuItem(title: "Updated: —", action: nil, keyEquivalent: "")
    private lazy var errorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private lazy var launchItem = NSMenuItem(
        title: "Launch at Login",
        action: #selector(toggleLaunchAtLogin(_:)),
        keyEquivalent: ""
    )
    private lazy var refreshItem = NSMenuItem(
        title: "Refresh",
        action: #selector(refresh(_:)),
        keyEquivalent: "r"
    )

    private static let autosaveName = "SuperGrokBar"
    private var watchdog: Timer?
    private var lastVisibilityLog: String?

    nonisolated private static let logger = Logger(subsystem: "com.kujira.SuperGrokBar", category: "statusitem")

    nonisolated static func log(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }

    /// Horizontal padding (total) around the title; smaller than AppKit's variable-length
    /// default so the item is narrow enough to fit beside the notch on crowded menu bars.
    private static let titlePadding: CGFloat = 8

    func install() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        percentItem.isEnabled = false
        grokCreditsItem.isEnabled = false
        planItem.isEnabled = false
        resetItem.isEnabled = false
        accountItem.isEnabled = false
        updatedItem.isEnabled = false
        errorItem.isEnabled = false
        errorItem.isHidden = true

        menu.addItem(percentItem)
        menu.addItem(grokCreditsItem)
        codexPrimaryItem.isEnabled = false
        codexWeeklyItem.isEnabled = false
        menu.addItem(codexPrimaryItem)
        menu.addItem(codexWeeklyItem)
        menu.addItem(planItem)
        menu.addItem(resetItem)
        menu.addItem(accountItem)
        menu.addItem(updatedItem)
        menu.addItem(errorItem)
        menu.addItem(.separator())

        refreshItem.target = self
        menu.addItem(refreshItem)

        let openBotPlan = NSMenuItem(title: "Open Grok Bot Plan…", action: #selector(openBotPlan(_:)), keyEquivalent: "p")
        openBotPlan.target = self
        menu.addItem(openBotPlan)

        let openSpending = NSMenuItem(title: "Open Cursor Spending…", action: #selector(openSpending(_:)), keyEquivalent: "")
        openSpending.target = self
        menu.addItem(openSpending)

        let openUsage = NSMenuItem(title: "Open grok.com Usage…", action: #selector(openUsage(_:)), keyEquivalent: "o")
        openUsage.target = self
        menu.addItem(openUsage)

        let linkSuperGrok = NSMenuItem(title: "Link SuperGrok…", action: #selector(linkSuperGrok(_:)), keyEquivalent: "")
        linkSuperGrok.target = self
        linkSuperGrok.tag = 710
        menu.addItem(linkSuperGrok)

        let openGrok = NSMenuItem(title: "Open grok.com…", action: #selector(openGrok(_:)), keyEquivalent: "")
        openGrok.target = self
        menu.addItem(openGrok)

        menu.addItem(.separator())

        launchItem.target = self
        menu.addItem(launchItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit SuperGrok Bar", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        self.menu = menu
        pinStatusItem(recreate: true)
        state.start()
        updateAppearance()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuWillOpen),
            name: NSMenu.didBeginTrackingNotification,
            object: menu
        )
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(ensureOnBar), name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(ensureOnBar), name: NSWorkspace.screensDidWakeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ensureOnBar),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        let timer = Timer(timeInterval: 10, target: self, selector: #selector(ensureOnBar), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    func updateAppearance() {
        ensureOnBar()
        applyButtonAppearance()
        rebuildMenuLabels()
    }

    /// Recreate only when the extra has actually left the menu bar.
    /// `button` can stay non-nil after macOS drops the item; `window == nil` is the real signal.
    @objc func ensureOnBar() {
        UserDefaults.standard.set(true, forKey: "NSStatusItem Visible \(Self.autosaveName)")
        let missing = statusItem == nil
            || statusItem?.button == nil
            || statusItem?.button?.window == nil
            || statusItem?.isVisible == false
        if missing {
            Self.log("status item missing from menu bar; recreating")
            pinStatusItem(recreate: true)
        } else {
            statusItem?.isVisible = true
        }
        logVisibility()
    }

    /// macOS silently hides status items that don't fit in the menu bar (or would sit under
    /// the notch). That can't be overridden by the app, but it can be detected and logged.
    private func logVisibility() {
        guard let window = statusItem?.button?.window else { return }
        let frame = window.frame
        let onScreen = window.occlusionState.contains(.visible)
        var note = onScreen ? "visible" : "HIDDEN (menu bar full / behind notch)"
        if let screen = window.screen ?? NSScreen.main,
           let right = screen.auxiliaryTopRightArea,
           frame.minX < screen.frame.minX + right.minX,
           frame.maxX > screen.frame.minX + (screen.auxiliaryTopLeftArea?.maxX ?? 0) {
            note += ", overlaps notch"
        }
        let line = "status item \(note) x=\(Int(frame.minX)) w=\(Int(frame.width)) title=\(state.barTitle)"
        if line != lastVisibilityLog {
            lastVisibilityLog = line
            Self.log(line)
        }
    }

    /// Named, non-removable extra. macOS otherwise stashes unnamed items as
    /// Control Center `Item-N` (often hidden) or drops them after sleep.
    private func pinStatusItem(recreate: Bool) {
        UserDefaults.standard.set(true, forKey: "NSStatusItem Visible \(Self.autosaveName)")
        if recreate || statusItem == nil || statusItem?.button == nil {
            if let old = statusItem {
                NSStatusBar.system.removeStatusItem(old)
            }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.behavior = []
            item.autosaveName = NSStatusItem.AutosaveName(Self.autosaveName)
            item.menu = menu
            statusItem = item
            applyButtonAppearance()
        }
        statusItem?.isVisible = true
    }

    private func applyButtonAppearance() {
        guard let button = statusItem?.button else { return }
        let title = Self.attributedTitle(state.barTitle)
        if button.attributedTitle != title {
            button.attributedTitle = title
        }
        // Fixed, tight width (text + small padding) instead of variableLength's wide insets.
        let length = ceil(title.size().width) + Self.titlePadding
        if let item = statusItem, abs(item.length - length) > 0.5 {
            item.length = length
        }
        // Text only: no xAI / template image.
        if button.image != nil {
            button.image = nil
        }
        if button.imagePosition != .noImage {
            button.imagePosition = .noImage
        }
        let tip = tooltipText()
        if button.toolTip != tip {
            button.toolTip = tip
        }
    }

    /// Plain labeled remaining-% numbers (e.g. "Bu88 Bo8 Co48 Cw69") in small monospaced digits.
    static func attributedTitle(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
        ])
    }

    private func tooltipText() -> String {
        if let usage = state.usage {
            var parts: [String] = []
            if usage.needsSuperGrokLink {
                parts.append("Grok Bot: SuperGrok not linked")
            } else if let bot = usage.botPercent {
                var botPart = "Grok Bot (Bo) \(AppState.percentLabel(max(0, 100 - bot))) left"
                if let resets = usage.botResetsAt {
                    botPart += " (resets \(AppState.formatReset(resets)))"
                }
                parts.append(botPart)
            }
            if let grok = usage.grokPercent {
                var grokPart = "Grok Build (Bu) \(AppState.percentLabel(max(0, 100 - grok))) left"
                if let resets = usage.grokResetsAt {
                    grokPart += " (resets \(AppState.formatReset(resets)))"
                }
                parts.append(grokPart)
            } else {
                parts.append("Grok Build unavailable")
            }
            if let c = state.codex {
                parts.append("Codex weekly (Co) \(AppState.percentLabel(c.secondary?.remainingPercent ?? .nan)) left / 5h window (Cw) \(AppState.percentLabel(c.primary?.remainingPercent ?? .nan)) left")
            } else if AppState.codexHasError(nil, error: state.codexError) {
                parts.append("Codex unavailable")
            }
            parts.append("Bar: " + AppState.barLegend)
            return parts.joined(separator: "\n")
        }
        if let err = state.lastError {
            return "SuperGrok Bar: \(err)"
        }
        return "Grok Bot and Grok Build usage"
    }

    private func rebuildMenuLabels() {
        if let usage = state.usage {
            if usage.needsSuperGrokLink {
                percentItem.title = AppState.formatPercentLine(
                    name: "Grok Bot",
                    percent: nil,
                    resetsAt: nil,
                    placeholder: "not linked"
                )
            } else {
                percentItem.title = AppState.formatPercentLine(
                    name: "Grok Bot",
                    percent: usage.botPercent,
                    resetsAt: usage.botResetsAt
                )
            }
            grokCreditsItem.title = AppState.formatPercentLine(
                name: "Grok Build",
                percent: usage.grokPercent,
                resetsAt: usage.grokResetsAt
            )
            grokCreditsItem.isHidden = false
            planItem.title = "Plan: \(usage.loginMethod)"
            // Per-source reset times live on the Bot / Build lines.
            resetItem.isHidden = true
            if let email = usage.email, !email.isEmpty {
                accountItem.title = "Account: \(email)"
                accountItem.isHidden = false
            } else {
                accountItem.isHidden = true
            }
            updatedItem.title = "Updated: \(AppState.formatFetched(usage.fetchedAt))"
        } else {
            percentItem.title = "Grok Bot: —"
            grokCreditsItem.title = "Grok Build: —"
            grokCreditsItem.isHidden = false
            planItem.title = "Plan: —"
            resetItem.isHidden = true
            accountItem.title = "Account: —"
            updatedItem.title = "Updated: —"
        }

        rebuildCodexLabels()

        if let err = state.lastError {
            errorItem.title = "Error: \(err)"
            errorItem.isHidden = false
        } else {
            errorItem.isHidden = true
        }

        if let link = menu?.items.first(where: { $0.tag == 710 }) {
            link.isHidden = !(state.usage?.needsSuperGrokLink ?? false)
        }

        launchItem.state = state.launchAtLoginEnabled ? .on : .off
        refreshItem.isEnabled = !state.isRefreshing
        refreshItem.title = state.isRefreshing ? "Refreshing…" : "Refresh"
    }

    /// Codex lines show remaining % (like the upstream /status), hidden when Codex isn't set up.
    private func rebuildCodexLabels() {
        func line(_ name: String, _ w: CodexWindow?) -> String {
            guard let w else { return "\(name): —" }
            var t = "\(name): \(AppState.percentLabel(w.remainingPercent)) left"
            if let r = w.resetsAt { t += " · resets \(AppState.formatReset(r))" }
            return t
        }
        if let codex = state.codex {
            codexPrimaryItem.title = line("Codex 5h", codex.primary)
            codexWeeklyItem.title = line("Codex weekly", codex.secondary)
            codexPrimaryItem.isHidden = false
            codexWeeklyItem.isHidden = false
        } else if let err = state.codexError, !(err.contains("not logged in")) {
            codexPrimaryItem.title = "Codex: unavailable"
            codexPrimaryItem.toolTip = err
            codexPrimaryItem.isHidden = false
            codexWeeklyItem.isHidden = true
        } else {
            codexPrimaryItem.isHidden = true
            codexWeeklyItem.isHidden = true
        }
    }

    // MARK: - Actions

    @objc private func menuWillOpen() {
        rebuildMenuLabels()
    }

    @objc private func refresh(_ sender: Any?) {
        Task { await state.refresh() }
    }

    @objc private func openUsage(_ sender: Any?) {
        state.openGrokUsage()
    }

    @objc private func openSpending(_ sender: Any?) {
        state.openBotSpending()
    }

    @objc private func openBotPlan(_ sender: Any?) {
        state.openGrokBotPlan()
    }

    @objc private func linkSuperGrok(_ sender: Any?) {
        state.openLinkSuperGrok()
    }

    @objc private func openGrok(_ sender: Any?) {
        state.openGrokHome()
    }

    @objc private func toggleLaunchAtLogin(_ sender: Any?) {
        state.setLaunchAtLogin(!state.launchAtLoginEnabled)
        rebuildMenuLabels()
    }

    @objc private func quit(_ sender: Any?) {
        state.stop()
        NSApp.terminate(nil)
    }
}
