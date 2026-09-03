import Foundation
import SQLite3

/// Cursor.app local session from `state.vscdb` (same source CodexBar uses).
enum CursorAppAuth {
    static var dbPath: String {
        NSHomeDirectory() + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    }

    static func loadAccessToken() throws -> String {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw GrokError.cursorNotSignedIn
        }
        if let token = try readItem(key: "cursorAuth/accessToken", immutable: false),
           !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return token
        }
        // Idle WAL-mode DB with no sidecars: retry immutable so we don't recreate files.
        if walSidecarsMissing,
           let token = try? readItem(key: "cursorAuth/accessToken", immutable: true),
           !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return token
        }
        throw GrokError.cursorNotSignedIn
    }

    static func cookieHeader(for accessToken: String) throws -> String {
        let userID = try userID(fromJWT: accessToken)
        return "WorkosCursorSessionToken=\(userID)%3A%3A\(accessToken)"
    }

    static func cachedEmail() -> String? {
        (try? readItem(key: "cursorAuth/cachedEmail", immutable: false))
            ?? (try? readItem(key: "cursorAuth/cachedEmail", immutable: true))
    }

    private static var walSidecarsMissing: Bool {
        !FileManager.default.fileExists(atPath: dbPath + "-wal")
            && !FileManager.default.fileExists(atPath: dbPath + "-shm")
    }

    private static func readItem(key: String, immutable: Bool) throws -> String? {
        var db: OpaquePointer?
        let filename: String
        let flags: Int32
        if immutable {
            let url = URL(fileURLWithPath: dbPath).absoluteURL.absoluteString
            filename = "\(url)?immutable=1"
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        } else {
            // Still URI-open read-only so we never create WAL sidecars next to Cursor's DB.
            let url = URL(fileURLWithPath: dbPath).absoluteURL.absoluteString
            filename = "\(url)?mode=ro"
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        }
        let open = sqlite3_open_v2(filename, &db, flags, nil)
        guard open == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw GrokError.network("SQLite error reading Cursor auth: \(msg)")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw GrokError.network("SQLite prepare failed for Cursor auth")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let step = sqlite3_step(stmt)
        guard step == SQLITE_ROW else { return nil }

        switch sqlite3_column_type(stmt, 0) {
        case SQLITE_TEXT:
            guard let c = sqlite3_column_text(stmt, 0) else { return nil }
            return String(cString: c)
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(stmt, 0) else { return nil }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))
            return String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16LittleEndian)
        default:
            return nil
        }
    }

    private static func userID(fromJWT jwt: String) throws -> String {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { throw GrokError.parseFailed }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = json["sub"] as? String
        else { throw GrokError.parseFailed }
        let userID = sub.split(separator: "|").last.map(String.init) ?? sub
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard !userID.isEmpty, userID.unicodeScalars.allSatisfy(allowed.contains) else {
            throw GrokError.parseFailed
        }
        return userID
    }
}
