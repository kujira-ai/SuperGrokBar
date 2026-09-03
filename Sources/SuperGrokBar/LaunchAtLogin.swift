import Foundation
import ServiceManagement

/// Launch-at-login via LaunchAgent (reliable for LSUIElement agent apps).
enum LaunchAtLogin {
    static let label = "com.kujira.SuperGrokBar"
    private static let agentName = "\(label).plist"

    private static var launchAgentsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    private static var plistURL: URL {
        launchAgentsDir.appendingPathComponent(agentName, isDirectory: false)
    }

    /// Path to the running binary (inside .app or bare executable).
    static var executableURL: URL {
        Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    }

    static var isEnabled: Bool {
        get { FileManager.default.fileExists(atPath: plistURL.path) }
        set {
            if newValue {
                enable()
            } else {
                disable()
            }
        }
    }

    static func syncFromDisk() {
        // no-op: getter reads disk; kept for call-site clarity
    }

    static func enable() {
        do {
            try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
            let exe = executableURL.path
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [exe],
                "RunAtLoad": true,
                // Restart after a crash, but not after Quit (exit 0).
                "KeepAlive": [
                    "Crashed": true,
                    "SuccessfulExit": false,
                ],
                "ProcessType": "Interactive",
                "ThrottleInterval": 10,
                "AssociatedBundleIdentifiers": ["com.kujira.SuperGrokBar"],
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)

            // Do not bootout — that SIGTERMs this process. Load only if missing.
            let uid = getuid()
            let domain = "gui/\(uid)"
            let service = "\(domain)/\(label)"
            _ = run("/bin/launchctl", ["enable", service])
            if run("/bin/launchctl", ["print", service]) != 0 {
                _ = run("/bin/launchctl", ["bootstrap", domain, plistURL.path])
            }
        } catch {
            NSLog("SuperGrokBar: failed to enable launch at login: \(error)")
        }
    }

    static func disable() {
        // Remove the login item without unloading the running job (bootout kills us).
        try? FileManager.default.removeItem(at: plistURL)
    }

    @discardableResult
    private static func run(_ launchPath: String, _ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
