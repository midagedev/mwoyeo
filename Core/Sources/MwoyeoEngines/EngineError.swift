import Foundation

/// Why a translation call did not give lines back. Messages are scrubbed of the key and at most 200 characters.
public enum EngineError: Error, Equatable, Sendable {
    case missingKey
    case unauthorized(String)
    /// `retryAfter` is the `Retry-After` header in seconds, when the server sent one.
    case rateLimited(retryAfter: Double?)
    /// HTTP 400 that `withoutRejectedField` could not heal (or that rejected the retry too).
    case rejected(String)
    case server(String)
    case countMismatch(expected: Int, got: Int)
    case malformed(String)
    case network(String)
    case commandFailed(String)
    /// The engine reached a build that does not run it (`EngineReach`): a command engine, or in the App Store build one off this Mac.
    case notInThisVersion
    /// The engine is off this Mac and the person has not allowed sending the lens's text to `host` (the app keeps that record).
    case needsPermission(host: String)
    case cancelled

    /// A short sentence for the lens or the add-engine sheet.
    public var userMessage: String {
        switch self {
        case .missingKey: "This engine needs an API key."
        case .unauthorized: "The engine did not accept the key."
        case let .rateLimited(after):
            after.map { "Too many requests. Try again in \(Int($0.rounded(.up))) s." } ?? "Too many requests. Try again in a moment."
        case let .rejected(m): "The engine rejected the request: \(m)"
        case let .server(m): "The engine reported an error: \(m)"
        case let .countMismatch(expected, got): "The engine returned \(got) lines for \(expected)."
        case .malformed: "The engine's answer was not in the expected format."
        case let .network(m): "Could not reach the engine: \(m)"
        case let .commandFailed(m): "The command failed: \(m)"
        case .notInThisVersion: "Not available in this version"
        case let .needsPermission(host): "Allow sending to \(host) in Settings"
        case .cancelled: "Cancelled."
        }
    }
}

/// Cleans text that may echo a request before it goes into an `EngineError`: the key (raw and percent-encoded) becomes
/// `***`, whitespace collapses, and the result is cut to 200 characters.
struct Scrubber: Sendable {
    static let maxLength = 200
    var key: String?

    func callAsFunction(_ text: String) -> String {
        var s = text
        if let key, !key.isEmpty {
            s = s.replacingOccurrences(of: key, with: "***")
            if let encoded = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics), encoded != key {
                s = s.replacingOccurrences(of: encoded, with: "***")
            }
        }
        s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return s.count > Self.maxLength ? String(s.prefix(Self.maxLength - 1)) + "…" : s
    }
}
