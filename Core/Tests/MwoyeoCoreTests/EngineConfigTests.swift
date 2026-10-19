import Foundation
import Testing
@testable import MwoyeoCore

@Suite struct EngineConfigTests {
    private let kinds: [EngineKind] = [
        .openAICompatible(baseURL: URL(string: "https://api.example.com/v1")!, model: "m", thinking: .provider, extraHeaders: ["X-Org": "a"]),
        .anthropic(baseURL: URL(string: "https://api.anthropic.com")!, model: "claude-x", thinking: .off),
        .deepL(baseURL: URL(string: "https://api-free.deepl.com")!, formality: "less"),
        .deepL(baseURL: URL(string: "https://api.deepl.com")!, formality: nil),
        .httpTemplate(HTTPTemplate(url: "http://localhost:5000/translate", body: #"{"q": {{text}}}"#, resultPath: "translatedText")),
        .command(CommandSpec(executable: "/usr/bin/python3", arguments: ["-I", "e.py"])),
    ]

    @Test func everyKindRoundTrips() throws {
        for kind in kinds {
            let c = EngineConfig(name: "E", kind: kind)
            let back = try JSONDecoder().decode(EngineConfig.self, from: JSONEncoder().encode(c))
            #expect(back == c)
            let shared = try EngineShare.decode(EngineShare.encode(c))
            #expect(shared.kind == c.kind && shared.name == c.name)
        }
    }

    @Test func decodeIgnoresUnknownFieldsAndDefaultsMissingOnes() throws {
        let json = #"{"name": "G", "kind": "openAICompatible", "baseURL": "http://localhost:1234/v1", "future": {"a": 1}}"#
        let c = try JSONDecoder().decode(EngineConfig.self, from: Data(json.utf8))
        #expect(c.kind == .openAICompatible(baseURL: URL(string: "http://localhost:1234/v1")!, model: "", thinking: .off, extraHeaders: [:]))
        let a = try JSONDecoder().decode(EngineConfig.self, from: Data(#"{"name": "A", "kind": "anthropic"}"#.utf8))
        #expect(a.kind == .anthropic(baseURL: EngineKind.anthropicDefaultBaseURL, model: "", thinking: .off))
        let t = try JSONDecoder().decode(EngineConfig.self, from: Data(#"{"name": "T", "kind": "httpTemplate", "template": {"url": "http://h/t", "resultPath": "r"}}"#.utf8))
        guard case let .httpTemplate(h) = t.kind else { Issue.record("not a template"); return }
        #expect(h.method == "POST" && h.batching == .perLine && h.headers.isEmpty)
    }

    @Test func unknownKindThrowsATypedError() {
        let json = #"{"name": "X", "kind": "telepathy"}"#
        #expect(throws: EngineConfigError.unknownKind("telepathy")) {
            try JSONDecoder().decode(EngineConfig.self, from: Data(json.utf8))
        }
    }

    @Test func exportHasTheVersionMarkerSortedKeysAndNoID() throws {
        let c = EngineConfig(name: "E", kind: kinds[0])
        let s = EngineShare.encode(c)
        #expect(s.contains("\"mwoyeoEngine\" : 1"))
        #expect(!s.contains(c.id.uuidString))
        let order = ["\"baseURL\"", "\"extraHeaders\"", "\"kind\"", "\"model\"", "\"name\"", "\"thinking\""].map { s.range(of: $0)!.lowerBound }
        #expect(order == order.sorted())
        #expect(s.range(of: "\"engine\"")!.lowerBound < s.range(of: "\"mwoyeoEngine\"")!.lowerBound)
        #expect(s == EngineShare.encode(c))
    }

    @Test func importAssignsANewID() throws {
        let c = EngineConfig(name: "E", kind: kinds[1])
        let a = try EngineShare.decode(EngineShare.encode(c))
        let b = try EngineShare.decode(EngineShare.encode(c))
        #expect(a.id != c.id && a.id != b.id)
    }

    @Test func importRejectsSecretFieldsAtAnyDepth() {
        let top = #"{"mwoyeoEngine": 1, "engine": {"name": "E", "kind": "anthropic", "apiKey": "sk-1"}}"#
        #expect(throws: EngineConfigError.secretField("engine.apiKey")) { try EngineShare.decode(top) }
        let nested = #"{"mwoyeoEngine": 1, "engine": {"name": "E", "kind": "httpTemplate", "template": {"url": "http://h", "resultPath": "r", "extra": [{"Token": "t"}]}}}"#
        #expect(throws: EngineConfigError.secretField("engine.template.extra[0].Token")) { try EngineShare.decode(nested) }
        let header = #"{"mwoyeoEngine": 1, "engine": {"name": "E", "kind": "httpTemplate", "template": {"url": "http://h", "resultPath": "r", "headers": {"Authorization": "Bearer sk-1"}}}}"#
        #expect(throws: EngineConfigError.secretField("engine.template.headers.Authorization")) { try EngineShare.decode(header) }
    }

    @Test func aKeyPlaceholderHeaderIsAllowedAndALiteralOneIsScrubbedOnExport() throws {
        let ok = HTTPTemplate(url: "http://h/t", headers: ["Authorization": "Bearer {{key}}"], body: "{{text}}", resultPath: "r")
        let back = try EngineShare.decode(EngineShare.encode(EngineConfig(name: "E", kind: .httpTemplate(ok))))
        #expect(back.kind == .httpTemplate(ok))
        var leaky = ok
        leaky.headers["Authorization"] = "Bearer sk-secret"
        let s = EngineShare.encode(EngineConfig(name: "E", kind: .httpTemplate(leaky)))
        #expect(!s.contains("sk-secret"))
        #expect(throws: Never.self) { try EngineShare.decode(s) }
    }

    @Test func importRejectsFilesThatAreNotEngines() {
        #expect(throws: EngineConfigError.notAnEngineFile) { try EngineShare.decode(#"{"name": "E"}"#) }
        #expect(throws: EngineConfigError.self) { try EngineShare.decode("nope") }
    }

    @Test func pasteRejectsACommandEngineWhenCommandsAreNotAllowed() throws {
        let shared = EngineShare.encode(EngineConfig(name: "C", kind: .command(CommandSpec(executable: "/usr/bin/python3"))))
        #expect(throws: EngineConfigError.commandNotAllowed) { try EngineShare.decode(shared, allowsCommands: false) }
        guard case .command = try EngineShare.decode(shared).kind else { Issue.record("default must still import it"); return }
        let http = EngineShare.encode(EngineConfig(name: "H", kind: .deepL(baseURL: URL(string: "https://api.deepl.com")!, formality: nil)))
        #expect(throws: Never.self) { try EngineShare.decode(http, allowsCommands: false) }
    }
}
