import AppKit

@MainActor
final class StatusItemController: NSObject {
    static let shared = StatusItemController()

    private var statusItem: NSStatusItem?
    private let state = AppState()
    private var menu: NSMenu?

    private lazy var percentItem = NSMenuItem(title: "Grok Bot: —", action: nil, keyEquivalent: "")
    private lazy var grokCreditsItem = NSMenuItem(title: "Grok Build: —", action: nil, keyEquivalent: "")
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

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            button.image = Self.menuBarImage()
            button.imagePosition = .imageLeading
            button.title = "…"
            button.toolTip = "Grok Bot and Grok Build usage"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        }

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

        item.menu = menu
        self.menu = menu

        state.start()
        updateAppearance()

        // Rebuild dynamic labels when menu opens
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuWillOpen),
            name: NSMenu.didBeginTrackingNotification,
            object: menu
        )
    }

    func updateAppearance() {
        guard let button = statusItem?.button else { return }
        button.title = " \(state.titleText)"
        button.image = Self.menuBarImage()
        button.toolTip = tooltipText()
        rebuildMenuLabels()
    }

    private func tooltipText() -> String {
        if let usage = state.usage {
            var parts: [String] = []
            if usage.needsSuperGrokLink {
                parts.append("Grok Bot: SuperGrok not linked")
            } else if let bot = usage.botPercent {
                var botPart = "Grok Bot \(Int(bot.rounded()))% used"
                if let resets = usage.botResetsAt {
                    botPart += " (resets \(AppState.formatReset(resets)))"
                }
                parts.append(botPart)
            }
            if let grok = usage.grokPercent {
                var grokPart = "Grok Build \(Int(grok.rounded()))% used"
                if let resets = usage.grokResetsAt {
                    grokPart += " (resets \(AppState.formatReset(resets)))"
                }
                parts.append(grokPart)
            } else {
                parts.append("Grok Build unavailable")
            }
            return parts.joined(separator: " · ")
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

    private static func menuBarImage() -> NSImage {
        // Prefer bundled template X icon (xAI-style, not Claude asterisk).
        // Installed .app: Contents/Resources; `swift run`: Bundle.module.
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "icon_template", withExtension: "png"),
            Bundle.main.resourceURL?.appendingPathComponent("icon_template.png"),
            Bundle.module.url(forResource: "icon_template", withExtension: "png"),
        ]
        for case let url? in candidates {
            if let img = NSImage(contentsOf: url) {
                img.isTemplate = true
                img.size = NSSize(width: 16, height: 16)
                return img
            }
        }
        // Fallback: SF Symbol that is not the Claude mark
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        if let img = NSImage(systemSymbolName: "xmark", accessibilityDescription: "SuperGrok")?
            .withSymbolConfiguration(config) {
            img.isTemplate = true
            return img
        }
        return NSImage(size: NSSize(width: 16, height: 16))
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
