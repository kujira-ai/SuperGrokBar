import Foundation

/// Last Grok Bot usage fetched by a process that is allowed to read the Keychain (normally the
/// menu bar app), shared with headless `quota` callers so they never touch the Keychain.
///
/// `~/Library/Caches/SuperGrokBar/grok-bot-status.json`, mode 0600. Contains only usage numbers
/// and dates — never the safeStorage key or the access token.
enum BotStatusCache {
    struct Entry: Codable, Sendable {
        var writtenAt: Date
        var writerVersion: String
        var writerPID: Int32
        var usagePercent: Double?
        var resetsAt: Date?
        var periodStart: Date?
        var includedLimitZero: Bool
        var hasNonZeroIncludedLimit: Bool
        var hasAvailableUsage: Bool?
        var grokPlanLabel: String?

        var status: CursorBotStatus {
            CursorBotStatus(
                usagePercent: usagePercent,
                resetsAt: resetsAt,
                periodStart: periodStart,
                includedLimitZero: includedLimitZero,
                hasNonZeroIncludedLimit: hasNonZeroIncludedLimit,
                hasAvailableUsage: hasAvailableUsage,
                grokPlanLabel: grokPlanLabel,
                cursorEmail: nil
            )
        }

        var age: TimeInterval { max(0, Date().timeIntervalSince(writtenAt)) }
    }

    static var directoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/SuperGrokBar", isDirectory: true)
    }

    static var fileURL: URL { directoryURL.appendingPathComponent("grok-bot-status.json") }

    static func write(_ status: CursorBotStatus) {
        let entry = Entry(
            writtenAt: Date(),
            writerVersion: AppVersion.current,
            writerPID: ProcessInfo.processInfo.processIdentifier,
            usagePercent: status.usagePercent,
            resetsAt: status.resetsAt,
            periodStart: status.periodStart,
            includedLimitZero: status.includedLimitZero,
            hasNonZeroIncludedLimit: status.hasNonZeroIncludedLimit,
            hasAvailableUsage: status.hasAvailableUsage,
            grokPlanLabel: status.grokPlanLabel
        )
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(entry)
            // Write to a 0600 temp file in the same directory, then rename over the old one.
            let tmp = directoryURL.appendingPathComponent(".grok-bot-status.\(getpid()).tmp")
            guard fm.createFile(atPath: tmp.path, contents: data,
                                attributes: [.posixPermissions: 0o600]) else { return }
            if rename(tmp.path, fileURL.path) != 0 { try? fm.removeItem(at: tmp) }
        } catch {
            // Best effort: the cache is an optimisation for headless callers.
        }
    }

    static func read() -> Entry? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Entry.self, from: data)
    }
}
