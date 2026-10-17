import Foundation
import Testing
@testable import MwoyeoCore

@Suite struct AnthropicTranslationTests {
    private func body(lines: [String] = ["Hello"], thinking: Thinking = .off) -> [String: Any] {
        let d = AnthropicTranslation.requestBody(lines: lines, source: "en", target: "ko", glossary: [], model: "claude-x", thinking: thinking)
        return try! JSONSerialization.jsonObject(with: d) as! [String: Any]
    }

    @Test func bodyShape() throws {
        let b = body()
        #expect(b["model"] as? String == "claude-x")
        #expect(b["temperature"] == nil)
        #expect((b["system"] as? String)?.contains("Korean") == true)
        let m = b["messages"] as! [[String: String]]
        #expect(m.count == 1 && m[0]["role"] == "user")
        let o = try JSONSerialization.jsonObject(with: Data(m[0]["content"]!.utf8)) as! [String: Any]
        #expect(o["lines"] as? [String] == ["Hello"])
        #expect(b["thinking"] == nil)
        #expect(body(thinking: .provider)["thinking"] == nil)
        #expect(b["stream"] == nil)
    }

    @Test func headersCarryTheVersionButNoKey() {
        let h = AnthropicTranslation.headers()
        #expect(h["anthropic-version"] == "2023-06-01" && h["content-type"] == "application/json")
        #expect(h.keys.allSatisfy { $0 != "x-api-key" })
    }

    @Test func maxTokensScalesWithInputAndIsCapped() {
        #expect(body(lines: ["abcd", "ef"])["max_tokens"] as? Int == 256 + 4 * 6)
        #expect(body(lines: [String(repeating: "x", count: 5000)])["max_tokens"] as? Int == 8192)
    }

    private func message(_ blocks: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["type": "message", "content": blocks])
    }

    @Test func parsesTextBlocksJoined() throws {
        let r = try AnthropicTranslation.parseTranslations(
            message([["type": "text", "text": #"{"translations": ["a", "#], ["type": "text", "text": #""b"]}"#]]), count: 2)
        #expect(r == ["a", "b"])
        let fenced = try AnthropicTranslation.parseTranslations(
            message([["type": "text", "text": "```json\n{\"translations\": [\"x\"]}\n```"]]), count: 1)
        #expect(fenced == ["x"])
    }

    @Test func parsesTheMockServerReply() throws {
        let reply = #"{"id": "msg_mock", "type": "message", "role": "assistant", "content": [{"type": "text", "text": "{\"translations\": [\"⟦anthropic⟧ a\", \"⟦anthropic⟧ b\"]}"}], "stop_reason": "end_turn"}"#
        #expect(try AnthropicTranslation.parseTranslations(Data(reply.utf8), count: 2) == ["⟦anthropic⟧ a", "⟦anthropic⟧ b"])
    }

    @Test func errorBodyIsAServerError() {
        let e = #"{"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}}"#
        #expect(throws: ChatTranslationError.server("invalid x-api-key")) { try AnthropicTranslation.parseTranslations(Data(e.utf8), count: 1) }
    }

    @Test func garbageAndCountMismatchAreTyped() {
        #expect(throws: ChatTranslationError.malformed("content has no JSON")) {
            try AnthropicTranslation.parseTranslations(message([["type": "text", "text": "sure! here you go"]]), count: 1)
        }
        #expect(throws: ChatTranslationError.countMismatch(expected: 2, got: 1)) {
            try AnthropicTranslation.parseTranslations(message([["type": "text", "text": #"{"translations": ["a"]}"#]]), count: 2)
        }
    }
}
