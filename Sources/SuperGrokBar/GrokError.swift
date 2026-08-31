import Foundation

enum GrokError: LocalizedError {
    case notLoggedIn(String)
    case invalidAuthFile
    case unauthorized
    case network(String)
    case server(Int, String)
    case parseFailed
    case emptyResponse
    case cursorNotSignedIn

    var errorDescription: String? {
        switch self {
        case .notLoggedIn(let path):
            return "Not logged in. Run `grok login` (missing \(path))."
        case .invalidAuthFile:
            return "Could not parse ~/.grok/auth.json."
        case .unauthorized:
            return "Auth expired or rejected. Sign in to Cursor / Grok again."
        case .network(let message):
            return "Network error: \(message)"
        case .server(let code, let body):
            return "Server error (\(code)): \(body)"
        case .parseFailed:
            return "Could not parse usage response."
        case .emptyResponse:
            return "Empty usage response from Grok."
        case .cursorNotSignedIn:
            return "No Cursor.app session. Sign in to Cursor or Grok Bot."
        }
    }
}
