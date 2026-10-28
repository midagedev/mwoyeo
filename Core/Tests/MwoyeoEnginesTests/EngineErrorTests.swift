import Testing
@testable import MwoyeoEngines

@Suite struct EngineErrorTests {
    /// A new case, not a reused one: the app tells "the person has not allowed this host" from "this build cannot run it".
    @Test func needsPermissionNamesTheHost() {
        let e = EngineError.needsPermission(host: "api.example.com")
        #expect(e.userMessage == "Allow sending to api.example.com in Settings")
        #expect(e == .needsPermission(host: "api.example.com"))
        #expect(e != .needsPermission(host: "other.example.com"))
        #expect(e != .notInThisVersion)
    }
}
