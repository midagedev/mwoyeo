import Foundation
import Testing
@testable import MwoyeoCore

@Suite struct ChatTranslationTests {
    private func envelope(_ content: String) -> Data {
        let obj: [String: Any] = ["choices": [["message": ["role": "assistant", "content": content]]]]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    private func body(glossary: [(String, String)] = []) -> [String: Any] {
        let d = ChatTranslation.requestBody(lines: ["Hello \"you\"", "안녕"], source: "en", target: "ko",
                                            glossary: glossary, model: "m1")
        return try! JSONSerialization.jsonObject(with: d) as! [String: Any]
    }

    @Test func requestBodyShape() {
        let b = body()
        #expect(b["model"] as? String == "m1")
        #expect(b["temperature"] as? Int == 0)
        #expect(b["stream"] as? Bool == false)
        let m = b["messages"] as! [[String: String]]
        #expect(m.count == 2)
        #expect(m[0]["role"] == "system" && m[1]["role"] == "user")
        #expect(m[0]["content"]!.contains("Korean"))
        #expect(m[0]["content"]!.contains("English"))
    }

    @Test func glossaryIsListedOnlyWhenGiven() {
        let with = (body(glossary: [("Mwoyeo", "뭐여")])["messages"] as! [[String: String]])[0]["content"]!
        #expect(with.contains("Mwoyeo → 뭐여"))
        let without = (body()["messages"] as! [[String: String]])[0]["content"]!
        #expect(!without.contains("→") && !without.lowercased().contains("glossary"))
    }

    @Test func linesRoundTripThroughTheUserMessage() throws {
        let user = (body()["messages"] as! [[String: String]])[1]["content"]!
        let o = try JSONSerialization.jsonObject(with: Data(user.utf8)) as! [String: Any]
        #expect(o["lines"] as? [String] == ["Hello \"you\"", "안녕"])
    }

    @Test func parsesPlainJSON() throws {
        let r = try ChatTranslation.parseTranslations(envelope(#"{"translations": ["a", "b"]}"#), count: 2)
        #expect(r == ["a", "b"])
    }

    @Test func parsesFencedJSON() throws {
        let r = try ChatTranslation.parseTranslations(envelope("```json\n{\"translations\": [\"a\"]}\n```"), count: 1)
        #expect(r == ["a"])
        let r2 = try ChatTranslation.parseTranslations(envelope("```\n{\"translations\": [\"x\"]}\n```"), count: 1)
        #expect(r2 == ["x"])
    }

    @Test func parsesJSONSurroundedByProse() throws {
        let r = try ChatTranslation.parseTranslations(envelope("Sure! {\"translations\": [\"a\", \"b\"]} Hope it helps."), count: 2)
        #expect(r == ["a", "b"])
    }

    @Test func parsesABareArray() throws {
        let r = try ChatTranslation.parseTranslations(envelope(#"["a", "b", "c"]"#), count: 3)
        #expect(r == ["a", "b", "c"])
    }

    @Test func countMismatchThrows() {
        #expect(throws: ChatTranslationError.countMismatch(expected: 3, got: 2)) {
            try ChatTranslation.parseTranslations(envelope(#"{"translations": ["a", "b"]}"#), count: 3)
        }
    }

    @Test func errorBodyThrowsServer() {
        let d = Data(#"{"error": {"message": "Incorrect API key", "type": "invalid_request_error"}}"#.utf8)
        #expect(throws: ChatTranslationError.server("Incorrect API key")) {
            try ChatTranslation.parseTranslations(d, count: 1)
        }
    }

    @Test func garbageThrowsMalformed() {
        #expect(throws: ChatTranslationError.self) {
            try ChatTranslation.parseTranslations(envelope("sure! here you go"), count: 1)
        }
        do { _ = try ChatTranslation.parseTranslations(Data("not json".utf8), count: 1); Issue.record("expected a throw") }
        catch { guard case .malformed = error else { Issue.record("expected .malformed, got \(error)"); return } }
        do { _ = try ChatTranslation.parseTranslations(envelope("sure! here you go"), count: 1); Issue.record("expected a throw") }
        catch { guard case .malformed = error else { Issue.record("expected .malformed, got \(error)"); return } }
    }

    @Test func onThisMac() {
        for s in ["http://localhost:11434/v1", "http://127.0.0.1:1234/v1", "http://[::1]:8080/v1"] {
            #expect(ChatTranslation.isOnThisMac(URL(string: s)!), "\(s)")
        }
        for s in ["https://api.openai.com/v1", "http://studio.local:1234/v1"] {
            #expect(!ChatTranslation.isOnThisMac(URL(string: s)!), "\(s)")
        }
    }

    @Test func modelIDsAreSorted() throws {
        let d = Data(#"{"object":"list","data":[{"id":"qwen3"},{"id":"gemma3"},{"id":"llama3"}]}"#.utf8)
        #expect(try ChatTranslation.modelIDs(d) == ["gemma3", "llama3", "qwen3"])
    }
}
