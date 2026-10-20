import Foundation
import Testing
@testable import MwoyeoCore

@Suite struct ModelQuirksTests {
    private func chat(_ host: String, _ model: String, port: Int? = nil) -> ModelQuirks {
        let url = URL(string: "https://\(host)")!
        return ModelQuirks.lookup(host: host, port: port, model: model,
                                  kind: .openAICompatible(baseURL: url, model: model, thinking: .off, extraHeaders: [:]))
    }

    private func effort(_ q: ModelQuirks) -> String? {
        if case .string(let s) = q.thinkingOff["reasoning_effort"] { return s }
        return nil
    }

    @Test func geminiRows() {
        let h = "generativelanguage.googleapis.com"
        #expect(effort(chat(h, "gemini-2.5-flash")) == "none")
        #expect(effort(chat(h, "models/gemini-3.1-flash-lite")) == "minimal")
        #expect(effort(chat(h, "gemini-3.5-flash-lite")) == "minimal")
        #expect(effort(chat(h, "gemini-3.8-flash")) == "low")
        #expect(effort(chat(h, "gemini-3-flash-preview")) == "low")
        #expect(chat(h, "gemini-3.8-flash").sendsTemperature)
        #expect(chat(h, "gemma-3-27b-it") == .plain)
    }

    @Test func openAIRows() {
        let h = "api.openai.com"
        for id in ["gpt-5", "gpt-5-mini", "gpt-5-nano", "gpt-5-nano-2025-08-07", "gpt-5-2025-08-07"] {
            #expect(effort(chat(h, id)) == "minimal" && !chat(h, id).sendsTemperature, "\(id)")
        }
        for id in ["gpt-5.4-mini", "gpt-5.6-luna", "gpt-5.1", "gpt-6.0-sol", "gpt-6.2-astra"] {
            #expect(effort(chat(h, id)) == "none" && !chat(h, id).sendsTemperature, "\(id)")
        }
        for id in ["o1", "o3-mini", "o4-mini"] {
            #expect(effort(chat(h, id)) == "low" && !chat(h, id).sendsTemperature, "\(id)")
        }
        for id in ["gpt-4o-mini", "gpt-4.1", "gpt-5-chat-latest", "gpt-5-pro", "something-new"] {
            #expect(chat(h, id) == .plain, "\(id)")
        }
    }

    @Test func providerHostRowsAreKept() {
        #expect(chat("openrouter.ai", "x").thinkingOff == ["reasoning": .object(["enabled": .bool(false)])])
        #expect(chat("api.deepseek.com", "x").thinkingOff == ["thinking": .object(["type": .string("disabled")])])
        #expect(chat("dashscope-intl.aliyuncs.com", "x").thinkingOff == ["enable_thinking": .bool(false)])
        #expect(effort(chat("ollama.com", "x")) == "none")
        #expect(effort(chat("localhost", "x", port: 11434)) == "none")
        #expect(chat("localhost", "x", port: 1234) == .plain)
    }

    private func claude(_ model: String) -> ModelQuirks {
        ModelQuirks.lookup(host: "api.anthropic.com", port: nil, model: model,
                           kind: .anthropic(baseURL: EngineKind.anthropicDefaultBaseURL, model: model, thinking: .off))
    }

    /// 2026-10-21 (trust1). Was `anthropicNeverSendsTemperatureOrThinking`, which pinned `thinkingOff == [:]` for every Claude: wrong for
    /// Claude 5, which thinks when `thinking` is left out (claude-api skill, cached 2026-10-06; haiku-5-5 measured in film 2). Each row is the
    /// model's own off switch. FAIL-first: /tmp/trust1/failfirst-1.log (the old line failed on the new table).
    @Test func anthropicRowsAreEachModelsOwnOffSwitch() {
        let disabled: [String: QuirkValue] = ["thinking": .object(["type": .string("disabled")])]
        for id in ["claude-haiku-5-5", "claude-sonnet-5", "claude-opus-5", "claude-haiku-5-5-20261001"] {
            #expect(claude(id).thinkingOff == disabled && !claude(id).sendsTemperature && claude(id).structuredReply, "\(id)")
        }
        #expect(claude("claude-sonnet-5-5").thinkingOff == ["thinking": .object(["type": .string("between_tools")])])
        for id in ["claude-opus-5-5", "claude-fable-5", "claude-fable-5-1", "claude-mythos-5-1"] {
            #expect(claude(id).thinkingOff == ["output_config": .object(["effort": .string("low")])] && claude(id).structuredReply, "\(id)")
        }
    }

    /// Opus 4.x, Sonnet 4.6 and Haiku 4.5 do not think unless asked, and an unknown id is left as it was: no thinking field, no schema.
    @Test func anAnthropicIdThatDoesNotThinkByDefaultOrIsUnknownGetsNothingExtra() {
        for id in ["claude-opus-4-8", "claude-opus-4-7", "claude-sonnet-4-6", "claude-haiku-4-5", "claude-x", "claude-haiku-6-0", ""] {
            #expect(claude(id) == ModelQuirks(sendsTemperature: false, thinkingOff: [:]), "\(id)")
        }
    }

    @Test func unknownHostAndModelKeepTemperatureZero() {
        #expect(chat("gateway.example.com", "anything") == .plain)
        #expect(chat("", "") == .plain)
    }

    // MARK: request bodies

    private func body(_ base: String, _ model: String, _ thinking: Thinking = .off) -> [String: Any] {
        let d = ChatTranslation.requestBody(lines: ["a"], source: nil, target: "ko", glossary: [], model: model,
                                            baseURL: URL(string: base), thinking: thinking)
        return try! JSONSerialization.jsonObject(with: d) as! [String: Any]
    }

    @Test func requestBodiesFollowTheTable() {
        let openAI = "https://api.openai.com/v1", gemini = "https://generativelanguage.googleapis.com/v1beta/openai/"
        let a = body(openAI, "gpt-4o-mini")
        #expect(a["temperature"] as? Int == 0 && a["reasoning_effort"] == nil)
        let b = body(openAI, "gpt-5.6-luna")
        #expect(b["temperature"] == nil && b["reasoning_effort"] as? String == "none")
        let c = body(gemini, "gemini-3.1-flash-lite")
        #expect(c["temperature"] as? Int == 0 && c["reasoning_effort"] as? String == "minimal")
        #expect(body(gemini, "gemini-3.8-flash")["reasoning_effort"] as? String == "low")
        // .provider sends no thinking field, but the temperature rule still applies
        let d = body(openAI, "gpt-5.6-luna", .provider)
        #expect(d["reasoning_effort"] == nil && d["temperature"] == nil)
        let claude = try! JSONSerialization.jsonObject(with: AnthropicTranslation.requestBody(
            lines: ["a"], source: nil, target: "ko", glossary: [], model: "claude-haiku-5-5")) as! [String: Any]
        // 2026-10-21 (trust1): was `claude["thinking"] == nil`; haiku-5-5's `.off` is `{type: disabled}` now (see anthropicRowsAreEachModelsOwnOffSwitch).
        #expect(claude["temperature"] == nil && (claude["thinking"] as? [String: String]) == ["type": "disabled"])
    }

    // MARK: withoutRejectedField, on bodies captured live 2026-10-17

    /// gpt-5-nano, `temperature: 0`.
    private let openAITemperature = #"{"error":{"message":"Unsupported value: 'temperature' does not support 0 with this model. Only the default (1) value is supported.","type":"invalid_request_error","param":"temperature","code":"unsupported_value"}}"#
    /// claude-haiku-5-5, `temperature: 0`.
    private let claudeTemperature = #"{"type":"error","error":{"type":"invalid_request_error","message":"`temperature` is deprecated for this model."},"request_id":"req_x"}"#
    /// gemini-3.1-flash-lite, `reasoning_effort: "bogus"` (gemini-3.8-flash answered 429, free quota out); Gemini wraps the error in an array.
    private let geminiEffort = #"[{"error":{"code":400,"message":"Invalid reasoning_effort: bogus. Valid values are: high, low, medium, minimal, none","status":"INVALID_ARGUMENT"}}]"#
    /// gpt model that does not exist (HTTP 404 live; the body is what matters).
    private let badModel = #"{"error":{"message":"The model `no-such-model` does not exist or you do not have access to it.","type":"invalid_request_error","param":null,"code":"model_not_found"}}"#

    private func healed(_ request: [String: Any], _ error: String) -> (keys: Set<String>, field: String)? {
        let data = try! JSONSerialization.data(withJSONObject: request)
        guard let r = ChatTranslation.withoutRejectedField(data, errorBody: Data(error.utf8)) else { return nil }
        return (Set((try! JSONSerialization.jsonObject(with: r.body) as! [String: Any]).keys), r.field)
    }

    @Test func rejectedFieldIsRemoved() {
        let r1 = healed(["model": "gpt-5-nano", "temperature": 0, "reasoning_effort": "minimal"], openAITemperature)
        #expect(r1?.field == "temperature" && r1?.keys == ["model", "reasoning_effort"])
        let r2 = healed(["model": "claude-haiku-5-5", "temperature": 0, "max_tokens": 9], claudeTemperature)
        #expect(r2?.field == "temperature" && r2?.keys == ["model", "max_tokens"])
        let r3 = healed(["model": "gemini-3.8-flash", "temperature": 0, "reasoning_effort": "none"], geminiEffort)
        #expect(r3?.field == "reasoning_effort" && r3?.keys == ["model", "temperature"])
    }

    /// A gateway in front of Claude that does not know `output_config`: the 400 names it, the retry goes without it. FAIL-first: before
    /// "output_config" was in `rejectableFields` this was nil.
    @Test func anAnthropicGatewayThatRefusesOutputConfigIsHealed() {
        let error = #"{"type":"error","error":{"type":"invalid_request_error","message":"output_config: Extra inputs are not permitted"}}"#
        let r = healed(["model": "claude-haiku-5-5", "max_tokens": 9, "output_config": ["format": ["type": "json_schema"]]], error)
        #expect(r?.field == "output_config" && r?.keys == ["model", "max_tokens"])
    }

    @Test func unrelatedOrAbsentFieldIsNil() {
        #expect(healed(["model": "no-such-model", "temperature": 0], badModel) == nil)
        // the error names a field the body does not carry
        #expect(healed(["model": "m"], openAITemperature) == nil)
        #expect(healed(["model": "m", "temperature": 0], "not json") == nil)
    }
}
