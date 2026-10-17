import Foundation
import Security

/// Where an engine's API key lives. Core never sees a store: the client reads the key per request and passes it on.
public protocol SecretStore: Sendable {
    func secret(for engine: UUID) throws -> String?
    /// `nil` deletes the key.
    func setSecret(_ secret: String?, for engine: UUID) throws
}

public struct KeychainError: Error, Equatable, Sendable, CustomStringConvertible {
    public let status: OSStatus
    public var description: String {
        "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
    }
}

/// One generic-password item per engine: service `dev.midagedev.mwoyeo.engine`, account the engine's uuid string.
/// Readable after the first unlock (a lens translating at login works), never synced to iCloud.
public struct KeychainSecrets: SecretStore {
    public static let defaultService = "dev.midagedev.mwoyeo.engine"
    public let service: String

    public init(service: String = KeychainSecrets.defaultService) {
        self.service = service
    }

    private func query(_ engine: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: engine.uuidString,
         kSecAttrSynchronizable as String: false]
    }

    public func secret(for engine: UUID) throws -> String? {
        var q = query(engine)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return (out as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func setSecret(_ secret: String?, for engine: UUID) throws {
        guard let secret else {
            let status = SecItemDelete(query(engine) as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound { throw KeychainError(status: status) }
            return
        }
        let data = Data(secret.utf8)
        var add = query(engine)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(query(engine) as CFDictionary,
                                       [kSecValueData as String: data,
                                        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock] as CFDictionary)
            if update != errSecSuccess { throw KeychainError(status: update) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }
}

/// For tests and previews: keys live in memory only.
public final class MemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: String] = [:]

    public init(_ values: [UUID: String] = [:]) {
        self.values = values
    }

    public func secret(for engine: UUID) throws -> String? {
        lock.withLock { values[engine] }
    }

    public func setSecret(_ secret: String?, for engine: UUID) throws {
        lock.withLock { values[engine] = secret }
    }
}
