import Foundation

enum GrokError: LocalizedError {
    case notLoggedIn(String)
    case invalidAuthFile
    case unauthorized
    case network(String)
    case server(Int, String)
    case parseFailed
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .notLoggedIn(let path):
            return "Not logged in. Run `grok login` (missing \(path))."
        case .invalidAuthFile:
            return "Could not parse ~/.grok/auth.json."
        case .unauthorized:
            return "Auth expired or rejected. Run `grok login` again."
        case .network(let message):
            return "Network error: \(message)"
        case .server(let code, let body):
            return "Server error (\(code)): \(body)"
        case .parseFailed:
            return "Could not parse SuperGrok usage response."
        case .emptyResponse:
            return "Empty usage response from Grok."
        }
    }
}
