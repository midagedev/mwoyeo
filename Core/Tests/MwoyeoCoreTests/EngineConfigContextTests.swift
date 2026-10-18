import Foundation
import Testing
@testable import MwoyeoCore

/// `EngineConfig.context`: an engine without one is saved, read and shared exactly as before the field existed, and a context
/// that cannot be read never loses the engine.
@Suite struct EngineConfigContextTests {
    private let id = UUID(uuidString: "7B3F1C2E-5A4D-4E8B-9C21-3D6F0A1B2C3D")!

    /// One engine of every kind, each with the bytes `EngineConfig` encoded to on main 7c67d1d, before `context` existed
    /// (recorded from that tree's own encoder, sorted keys). A key may be added to these only by a change that says why.
    private var todays: [(kind: EngineKind, json: String)] {
        [
            (.openAICompatible(baseURL: URL(string: "https://api.example.com/v1")!, model: "m", thinking: .provider, extraHeaders: ["X-Org": "a"]),
             #"{"baseURL":"https://api.example.com/v1","extraHeaders":{"X-Org":"a"},"id":"7B3F1C2E-5A4D-4E8B-9C21-3D6F0A1B2C3D","kind":"openAICompatible","model":"m","name":"E","thinking":"provider"}"#),
            (.anthropic(baseURL: URL(string: "https://api.anthropic.com")!, model: "claude-x", thinking: .off),
             #"{"baseURL":"https://api.anthropic.com","id":"7B3F1C2E-5A4D-4E8B-9C21-3D6F0A1B2C3D","kind":"anthropic","model":"claude-x","name":"E","thinking":"off"}"#),
            (.deepL(baseURL: URL(string: "https://api-free.deepl.com")!, formality: "less"),
             #"{"baseURL":"https://api-free.deepl.com","formality":"less","id":"7B3F1C2E-5A4D-4E8B-9C21-3D6F0A1B2C3D","kind":"deepL","name":"E"}"#),
            (.deepL(baseURL: URL(string: "https://api.deepl.com")!, formality: nil),
             #"{"baseURL":"https://api.deepl.com","id":"7B3F1C2E-5A4D-4E8B-9C21-3D6F0A1B2C3D","kind":"deepL","name":"E"}"#),
            (.httpTemplate(HTTPTemplate(url: "http://localhost:5000/translate", body: #"{"q": {{text}}}"#, resultPath: "translatedText")),
             #"{"id":"7B3F1C2E-5A4D-4E8B-9C21-3D6F0A1B2C3D","kind":"httpTemplate","name":"E","template":{"batching":"perLine","body":"{\"q\": {{text}}}","headers":{},"method":"POST","resultPath":"translatedText","url":"http://localhost:5000/translate"}}"#),
            (.command(CommandSpec(executable: "/usr/bin/python3", arguments: ["-I", "e.py"])),
             #"{"command":{"arguments":["-I","e.py"],"executable":"/usr/bin/python3"},"id":"7B3F1C2E-5A4D-4E8B-9C21-3D6F0A1B2C3D","kind":"command","name":"E"}"#),
        ]
    }

    private func sortedJSON(_ c: EngineConfig) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try enc.encode(c), as: UTF8.self)
    }

    @Test func anEngineWithoutAContextEncodesToTodaysBytesForEveryKind() throws {
        #expect(todays.count == 6)
        for (kind, json) in todays {
            #expect(try sortedJSON(EngineConfig(id: id, name: "E", kind: kind)) == json)
            #expect(try sortedJSON(EngineConfig(id: id, name: "E", kind: kind, context: nil)) == json)
        }
    }

    @Test func todaysBytesDecodeToAnEngineWithoutAContextAndEncodeBackTheSame() throws {
        for (kind, json) in todays {
            let c = try JSONDecoder().decode(EngineConfig.self, from: Data(json.utf8))
            #expect(c.context == nil && c.kind == kind && c.id == id)
            #expect(try sortedJSON(c) == json)
        }
    }

    @Test func theContextKeyIsWrittenOnlyWhenSetAndComesBackForEveryKind() throws {
        let context = EngineContext(enabled: true, previousLines: 5, includeTitle: true, useLearned: true, deepLInstructions: true)
        for (kind, json) in todays {
            let c = EngineConfig(id: id, name: "E", kind: kind, context: context)
            let text = try sortedJSON(c)
            #expect(text != json && text.contains(#""context":{"deepLInstructions":true,"enabled":true,"includeTitle":true,"previousLines":5,"useLearned":true}"#))
            // Without the context key the object is the one of today.
            var object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            object["context"] = nil
            #expect(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) == Data(json.utf8))
            let back = try JSONDecoder().decode(EngineConfig.self, from: Data(text.utf8))
            #expect(back == c && back.context == context)
        }
    }

    /// A context that cannot be read is no context, never a lost engine. A `{}` is readable: every field is optional, so it
    /// is the all-default (Off) context.
    @Test func aContextThatCannotBeReadIsNoContextAndTheEngineStays() throws {
        for bad in [#""context":"on""#, #""context":3"#, #""context":true"#, #""context":[1]"#, #""context":null"#] {
            let c = try JSONDecoder().decode(EngineConfig.self, from: Data(#"{"name":"G","kind":"anthropic","model":"m",\#(bad)}"#.utf8))
            #expect(c.context == nil && c.name == "G" && c.kind == .anthropic(baseURL: EngineKind.anthropicDefaultBaseURL, model: "m", thinking: .off), "\(bad)")
        }
        let empty = try JSONDecoder().decode(EngineConfig.self, from: Data(#"{"name":"G","kind":"anthropic","context":{}}"#.utf8))
        #expect(empty.context == EngineContext() && ContextOptions.from(engine: empty.context) == ContextOptions())
    }

    @Test func anEngineKeepsItsContextWhenOneSwitchIsBad() throws {
        let c = try JSONDecoder().decode(EngineConfig.self, from: Data(#"{"name":"G","kind":"deepL","baseURL":"https://api.deepl.com","context":{"enabled":true,"previousLines":12,"includeTitle":"yes"}}"#.utf8))
        #expect(c.context == EngineContext(enabled: true, previousLines: AppContextOverride.defaultPreviousLines, includeTitle: false))
    }

    /// Design §9: what an engine may be sent (a window title to a cloud service, learned rows, DeepL instructions) is each user's
    /// own opt-in. A shared engine file that carried it would hand the importer someone else's choice, so it never does, in
    /// either direction.
    @Test func exportLeavesTheContextOut() throws {
        let context = EngineContext(enabled: true, previousLines: 8, includeTitle: true, useLearned: true, deepLInstructions: true)
        for (kind, _) in todays {
            let withContext = EngineConfig(id: id, name: "E", kind: kind, context: context)
            let shared = EngineShare.encode(withContext)
            #expect(!shared.contains("context"))
            // The file is the one of the same engine without a context, byte for byte.
            #expect(shared == EngineShare.encode(EngineConfig(id: id, name: "E", kind: kind)))
            #expect(try EngineShare.decode(shared).context == nil)
        }
    }

    @Test func importIgnoresAContextInTheFile() throws {
        let handWritten = #"{"mwoyeoEngine": 1, "engine": {"name": "E", "kind": "anthropic", "context": {"enabled": true, "includeTitle": true, "useLearned": true}}}"#
        let imported = try EngineShare.decode(handWritten)
        #expect(imported.context == nil && imported.name == "E")
        #expect(ContextOptions.from(engine: imported.context) == ContextOptions())
    }
}
