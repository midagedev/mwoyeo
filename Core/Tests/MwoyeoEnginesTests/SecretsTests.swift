import Foundation
import Testing
@testable import MwoyeoEngines

@Suite struct SecretsTests {
    @Test func keychainRoundTrip() throws {
        let store = KeychainSecrets(service: "dev.midagedev.mwoyeo.engine.test-\(UUID().uuidString)")
        let id = UUID()
        defer { try? store.setSecret(nil, for: id) }
        #expect(try store.secret(for: id) == nil)
        try store.setSecret("first", for: id)
        #expect(try store.secret(for: id) == "first")
        try store.setSecret("second", for: id)
        #expect(try store.secret(for: id) == "second")
        try store.setSecret(nil, for: id)
        #expect(try store.secret(for: id) == nil)
        try store.setSecret(nil, for: id)  // deleting what is not there is fine
    }

    @Test func memoryStore() throws {
        let m = MemorySecrets()
        let id = UUID()
        try m.setSecret("k", for: id)
        #expect(try m.secret(for: id) == "k")
        try m.setSecret(nil, for: id)
        #expect(try m.secret(for: id) == nil)
    }
}
