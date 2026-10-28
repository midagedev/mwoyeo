import Foundation
import MwoyeoCore
import MwoyeoEngines

/// Core's engine sentences in the user's language. Core keeps English (it has no catalog); the keys below are entered
/// by hand in Localizable.xcstrings, so a new sentence in Core needs a new entry there too.
extension EngineError {
    /// `userMessage`, localized; what the engine itself said (`m`) stays as it said it.
    var localizedMessage: String {
        switch self {
        case .missingKey: String(localized: "This engine needs an API key.")
        case .unauthorized: String(localized: "The engine did not accept the key.")
        case let .rateLimited(after):
            after.map { String(localized: "Too many requests. Try again in \(Int($0.rounded(.up))) s.") }
                ?? String(localized: "Too many requests. Try again in a moment.")
        case let .rejected(m): String(localized: "The engine rejected the request: \(m)")
        case let .server(m): String(localized: "The engine reported an error: \(m)")
        case let .countMismatch(expected, got): String(localized: "The engine returned \(got) lines for \(expected).")
        case .malformed: String(localized: "The engine's answer was not in the expected format.")
        case let .network(m): String(localized: "Could not reach the engine: \(m)")
        case let .commandFailed(m): String(localized: "The command failed: \(m)")
        case .notInThisVersion: String(localized: "Not available in this version")
        case let .needsPermission(host): String(localized: "Allow sending to \(host) in Settings")
        case .cancelled: String(localized: "Cancelled.")
        }
    }
}

extension EnginePresets.Preset {
    /// The hint looked up by its English text (the catalog marks these keys manual).
    var localizedHint: String { Bundle.main.localizedString(forKey: hint, value: hint, table: nil) }
}
