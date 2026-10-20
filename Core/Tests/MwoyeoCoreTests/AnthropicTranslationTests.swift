import Foundation
import Testing
@testable import MwoyeoCore

@Suite struct AnthropicTranslationTests {
    private func body(lines: [String] = ["Hello"], thinking: Thinking = .off) -> [String: Any] {
        let d = AnthropicTranslation.requestBody(lines: lines, source: "en", target: "ko", glossary: [], model: "claude-x", thinking: thinking)
        return try! JSONSerialization.jsonObject(with: d) as! [String: Any]
    }

    /// `claude-x` is an id the quirks table does not know: nothing beyond the base fields is sent (2026-10-21, trust1: the Claude 5 rows
    /// send their own thinking-off switch and the reply schema, see `claude5BodiesCarryTheirOffSwitchAndTheSchema`).
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

    // MARK: thinking off and the reply schema (trust1, 2026-10-21)

    private func json(_ d: Data) -> [String: Any] { try! JSONSerialization.jsonObject(with: d) as! [String: Any] }

    private func plain(_ model: String, thinking: Thinking = .off) -> [String: Any] {
        json(AnthropicTranslation.requestBody(lines: ["a"], source: "ja", target: "ko", glossary: [], model: model, thinking: thinking))
    }

    private func context(_ model: String, learned: Bool) -> [String: Any] {
        var request = CtxFix.rich(items: ["a", "b"], target: "ko", source: "ja", glossary: [])
        request.threadKey = "k"
        let kind = LayoutKind.engine(.anthropic(baseURL: EngineKind.anthropicDefaultBaseURL, model: model, thinking: .off))
        return json(RequestLayout.body(kind: kind, request: request, options: ContextOptions(enabled: true, transcriptCount: 1, includeLearned: learned)))
    }

    private func schema(_ body: [String: Any]) -> [String: Any]? {
        (((body["output_config"] as? [String: Any])?["format"]) as? [String: Any])?["schema"] as? [String: Any]
    }

    /// Each Claude 5 row's body, as the API took it (200, probed 2026-10-21 with these shapes). FAIL-first: before the rows, the
    /// haiku body had no `thinking` and no `output_config` (the lines below failed on the unfixed table).
    @Test func claude5BodiesCarryTheirOffSwitchAndTheSchema() {
        let haiku = plain("claude-haiku-5-5")
        #expect((haiku["thinking"] as? [String: String]) == ["type": "disabled"] && haiku["temperature"] == nil)
        #expect((plain("claude-sonnet-5-5")["thinking"] as? [String: String]) == ["type": "between_tools"])
        for id in ["claude-opus-5-5", "claude-fable-5-1"] {
            let b = plain(id)
            #expect(b["thinking"] == nil, "\(id): thinking cannot be disabled")
            let config = b["output_config"] as! [String: Any]
            #expect(config["effort"] as? String == "low" && config["format"] != nil, "\(id): effort and format share one output_config")
        }
        for id in ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"] {
            let format = (plain(id)["output_config"] as! [String: Any])["format"] as! [String: Any]
            #expect(format["type"] as? String == "json_schema", "\(id)")
        }
    }

    @Test func providerSendsNoThinkingFieldButStillTheSchema() {
        let b = plain("claude-haiku-5-5", thinking: .provider)
        #expect(b["thinking"] == nil && schema(b) != nil)
        let opus = plain("claude-opus-5-5", thinking: .provider)
        #expect((opus["output_config"] as! [String: Any])["effort"] == nil && schema(opus) != nil)
    }

    @Test func anIdTheTableDoesNotKnowIsSentAsItWas() {
        for id in ["claude-x", "claude-opus-4-8", "claude-haiku-4-5"] {
            let b = plain(id)
            #expect(b["thinking"] == nil && b["output_config"] == nil && b["temperature"] == nil, "\(id)")
        }
    }

    @Test func theContextSchemaListsTermsOnlyWhenTheRequestAsksForThem() {
        func properties(_ s: [String: Any]?) -> Set<String> { Set(((s?["properties"]) as? [String: Any] ?? [:]).keys) }
        #expect(properties(schema(context("claude-haiku-5-5", learned: true))) == ["t", "terms"])
        #expect(properties(schema(context("claude-haiku-5-5", learned: false))) == ["t"])
        #expect(properties(schema(plain("claude-haiku-5-5"))) == ["translations"])
        #expect(context("claude-opus-4-8", learned: true)["output_config"] == nil)
    }

    /// Anthropic refuses a schema whose objects are open. Every object of both schemas is closed.
    @Test func everyObjectOfTheSchemasIsClosed() {
        func closed(_ v: Any) -> Bool {
            if let o = v as? [String: Any] {
                if o["type"] as? String == "object", o["additionalProperties"] as? Bool != false { return false }
                return o.values.allSatisfy(closed)
            }
            if let a = v as? [Any] { return a.allSatisfy(closed) }
            return true
        }
        #expect(closed(AnthropicTranslation.translationsSchema) && closed(AnthropicTranslation.contextSchema(wantsTerms: true)))
    }

    /// The five replies Haiku gave in the film-2 trial run (tapped 2026-10-21, /tmp/film2/live/haiku/tap): the shapes the schema now forces.
    @Test func theTrialRunRepliesParse() throws {
        func reply(_ text: String) -> Data {
            try! JSONSerialization.data(withJSONObject: ["type": "message", "content": [["type": "text", "text": text]],
                                                         "usage": ["input_tokens": 417, "output_tokens": 23]])
        }
        #expect(try AnthropicTranslation.parseTranslations(reply(#"{"t": [{"id": 0, "text": "구"}]}"#), count: 1) == ["구"])
        #expect(try AnthropicTranslation.parseTranslations(
            reply(#"{"t": [{"id": 0, "text": "츠쿠모, 여기가 츠키카게의 사당이에요."}, {"id": 1, "text": "틀림없어요"}]}"#), count: 2)
                == ["츠쿠모, 여기가 츠키카게의 사당이에요.", "틀림없어요"])
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
