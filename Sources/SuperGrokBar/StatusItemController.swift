import AppKit

@MainActor
final class StatusItemController: NSObject {
    static let shared = StatusItemController()

    private var statusItem: NSStatusItem?
    private let state = AppState()
    private var menu: NSMenu?

    private lazy var percentItem = NSMenuItem(title: "Usage: —", action: nil, keyEquivalent: "")
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
            button.toolTip = "SuperGrok usage"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        percentItem.isEnabled = false
        planItem.isEnabled = false
        resetItem.isEnabled = false
        accountItem.isEnabled = false
        updatedItem.isEnabled = false
        errorItem.isEnabled = false
        errorItem.isHidden = true

        menu.addItem(percentItem)
        menu.addItem(planItem)
        menu.addItem(resetItem)
        menu.addItem(accountItem)
        menu.addItem(updatedItem)
        menu.addItem(errorItem)
        menu.addItem(.separator())

        refreshItem.target = self
        menu.addItem(refreshItem)

        let openUsage = NSMenuItem(title: "Open Grok Usage…", action: #selector(openUsage(_:)), keyEquivalent: "o")
        openUsage.target = self
        menu.addItem(openUsage)

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
            var parts = ["SuperGrok \(Int(usage.usedPercent.rounded()))% used"]
            if let resets = usage.resetsAt {
                parts.append("resets \(AppState.formatReset(resets))")
            }
            return parts.joined(separator: " · ")
        }
        if let err = state.lastError {
            return "SuperGrok Bar: \(err)"
        }
        return "SuperGrok usage"
    }

    private func rebuildMenuLabels() {
        if let usage = state.usage {
            let pct = Int(usage.usedPercent.rounded())
            percentItem.title = "Usage: \(pct)%  (\(usage.status.rawValue))"
            planItem.title = "Plan: \(usage.loginMethod)"
            resetItem.title = "Resets: \(AppState.formatReset(usage.resetsAt))"
            if let email = usage.email, !email.isEmpty {
                accountItem.title = "Account: \(email)"
                accountItem.isHidden = false
            } else {
                accountItem.isHidden = true
            }
            updatedItem.title = "Updated: \(AppState.formatFetched(usage.fetchedAt))"
        } else {
            percentItem.title = "Usage: —"
            planItem.title = "Plan: —"
            resetItem.title = "Resets: —"
            accountItem.title = "Account: —"
            updatedItem.title = "Updated: —"
        }

        if let err = state.lastError {
            errorItem.title = "Error: \(err)"
            errorItem.isHidden = false
        } else {
            errorItem.isHidden = true
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
