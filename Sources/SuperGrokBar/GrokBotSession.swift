import Foundation
import Security
import CommonCrypto

/// Grok Bot stores a Cursor access token in sand-secrets.json, encrypted with
/// Electron safeStorage (Keychain "Grok Bot Safe Storage", Chromium v10 AES).
enum GrokBotSession {
    static var secretsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Grok Bot/sand-secrets.json")
    }

    private static let cacheTTL: TimeInterval = 10 * 60

    static func loadAccessToken() throws -> String {
        if let cached = KeychainCache.shared.token, Date().timeIntervalSince(cached.readAt) < cacheTTL {
            return cached.value
        }
        let url = secretsURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GrokError.cursorNotSignedIn
        }
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GrokError.parseFailed
        }
        let accountsRaw = root["cursor-accounts"]
        let accountsObj: Any?
        if let s = accountsRaw as? String {
            accountsObj = try JSONSerialization.jsonObject(with: Data(s.utf8))
        } else {
            accountsObj = accountsRaw
        }
        guard let accountsRoot = accountsObj as? [String: Any],
              let active = accountsRoot["active"] as? String,
              let accounts = accountsRoot["accounts"] as? [String: Any],
              let entry = accounts[active] as? [String: Any],
              let blob = entry["cursor-access-token"] as? String,
              !blob.isEmpty
        else {
            throw GrokError.cursorNotSignedIn
        }
        let token = try decryptElectronV10(blob)
        KeychainCache.shared.token = (token, Date())
        return token
    }

    /// Upper bound on a single Keychain read. If macOS shows an access prompt, the read
    /// blocks until the user answers; we give up after this and fall back (Cursor.app session
    /// or the last known value) instead of stalling the refresh.
    static let keychainTimeout: TimeInterval = 5

    private static func keychainPassword() throws -> Data {
        if let cached = KeychainCache.shared.value { return cached }
        // Don't stack reads behind a prompt that is still waiting for the user.
        guard KeychainCache.shared.beginRead() else {
            throw GrokError.network("Keychain access for Grok Bot Safe Storage is waiting for approval")
        }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "Grok Bot Safe Storage",
                kSecAttrAccount as String: "Grok Bot Key",
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess, let data = item as? Data, !data.isEmpty {
                KeychainCache.shared.finishRead(data)
            } else {
                KeychainCache.shared.finishRead(nil)
            }
            done.signal()
        }
        if done.wait(timeout: .now() + keychainTimeout) == .timedOut {
            throw GrokError.network("Keychain read timed out (approve the Keychain prompt with Always Allow)")
        }
        guard let data = KeychainCache.shared.value else { throw GrokError.cursorNotSignedIn }
        return data
    }

    private static func decryptElectronV10(_ b64: String) throws -> String {
        guard let wrapped = Data(base64Encoded: b64), wrapped.count > 3 else {
            throw GrokError.parseFailed
        }
        let prefix = wrapped.prefix(3)
        guard prefix == Data("v10".utf8) else { throw GrokError.parseFailed }
        let ciphertext = wrapped.dropFirst(3)
        let password = try keychainPassword()
        var key = [UInt8](repeating: 0, count: 16)
        let passBytes = [UInt8](password)
        let salt = Array("saltysalt".utf8)
        let derive = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            passBytes,
            passBytes.count,
            salt,
            salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
            1003,
            &key,
            key.count
        )
        guard derive == kCCSuccess else { throw GrokError.parseFailed }

        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var out = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var outLen: size_t = 0
        let crypt = CCCrypt(
            CCOperation(kCCDecrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionPKCS7Padding),
            key,
            key.count,
            iv,
            Array(ciphertext),
            ciphertext.count,
            &out,
            out.count,
            &outLen
        )
        guard crypt == kCCSuccess else { throw GrokError.parseFailed }
        let plain = Data(out.prefix(Int(outLen)))
        guard let token = String(data: plain, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { throw GrokError.parseFailed }
        return token
    }
}

/// In-memory cache of the safeStorage key (read from the Keychain once per launch) and of
/// the decrypted access token.
private final class KeychainCache: @unchecked Sendable {
    static let shared = KeychainCache()
    private let lock = NSLock()
    private var cached: Data?
    private var reading = false
    private var cachedToken: (value: String, readAt: Date)?

    var token: (value: String, readAt: Date)? {
        get { lock.lock(); defer { lock.unlock() }; return cachedToken }
        set { lock.lock(); defer { lock.unlock() }; cachedToken = newValue }
    }

    var value: Data? {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    func beginRead() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if reading { return false }
        reading = true
        return true
    }

    func finishRead(_ data: Data?) {
        lock.lock(); defer { lock.unlock() }
        if let data { cached = data }
        reading = false
    }
}
