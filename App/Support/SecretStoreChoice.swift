import Foundation
import MwoyeoEngines

/// Where added engines keep their API keys, written once for the app (`AppModel`) and the MCP server (`MCPWorld.live`): the Keychain.
/// In the Mac App Store build always. In the DMG build `MWOYEO_MEMORY_SECRETS` keeps the keys in memory instead, for captures, film takes
/// and check runs, and `MWOYEO_ENGINE_KEY` is then the key of every engine nobody stored one for (the way `--render` takes it): a
/// capture and film path, never the Keychain's and never a setting.
enum SecretStoreChoice {
    static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> any SecretStore {
        #if MAS
        return KeychainSecrets()
        #else
        guard environment["MWOYEO_MEMORY_SECRETS"] != nil else { return KeychainSecrets() }
        return ScratchSecrets(fallback: environment["MWOYEO_ENGINE_KEY"])
        #endif
    }
}

#if !MAS
/// Memory-only keys. An engine with no key stored answers `fallback`; storing a key for it (the engine sheet) wins, and clearing one
/// goes back to `fallback`.
final class ScratchSecrets: SecretStore, @unchecked Sendable {
    private let memory = MemorySecrets()
    private let fallback: String?

    init(fallback: String?) { self.fallback = fallback.flatMap { $0.isEmpty ? nil : $0 } }

    func secret(for engine: UUID) throws -> String? { try memory.secret(for: engine) ?? fallback }

    func setSecret(_ secret: String?, for engine: UUID) throws { try memory.setSecret(secret, for: engine) }
}
#endif
