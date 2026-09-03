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

    private static var cachedToken: (value: String, readAt: Date)?
    private static let cacheTTL: TimeInterval = 10 * 60

    static func loadAccessToken() throws -> String {
        if let cachedToken, Date().timeIntervalSince(cachedToken.readAt) < cacheTTL {
            return cachedToken.value
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
        cachedToken = (token, Date())
        return token
    }

    private static func keychainPassword() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Grok Bot Safe Storage",
            kSecAttrAccount as String: "Grok Bot Key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, !data.isEmpty else {
            throw GrokError.cursorNotSignedIn
        }
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
