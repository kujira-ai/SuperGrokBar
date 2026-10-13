import AppKit

// Headless CLI: `SuperGrokBar quota [--json]` prints all quotas and exits (no UI).
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "quota" {
    exit(QuotaCLI.run(Array(CommandLine.arguments.dropFirst(2))))
}

// Agent-style menu bar app: no Dock icon, no main window.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Held for process lifetime so AppKit does not idle-kill this windowless extra.
    private var keepAliveActivity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let process = ProcessInfo.processInfo
        process.disableSuddenTermination()
        process.disableAutomaticTermination("SuperGrok Bar menu extra")
        keepAliveActivity = process.beginActivity(
            options: [
                .suddenTerminationDisabled,
                .automaticTerminationDisabled,
                .userInitiatedAllowingIdleSystemSleep,
            ],
            reason: "SuperGrok Bar menu extra"
        )
        StatusItemController.shared.install()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let keepAliveActivity {
            ProcessInfo.processInfo.endActivity(keepAliveActivity)
            self.keepAliveActivity = nil
        }
        return .terminateNow
    }
}
