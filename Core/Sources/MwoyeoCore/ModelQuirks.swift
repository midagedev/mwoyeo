import Foundation

/// A request field value the quirk table can carry across concurrency domains.
public indirect enum QuirkValue: Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case object([String: QuirkValue])

    var json: Any {
        switch self {
        case .string(let s): s
        case .bool(let b): b
        case .object(let o): o.mapValues(\.json)
        }
    }
}

/// The one table of per-host and per-model request rules. `ChatTranslation` and `AnthropicTranslation` both read it.
/// An unknown host or model gets today's default: `temperature: 0` and nothing extra. A server that still rejects a
/// field is handled by `ChatTranslation.withoutRejectedField`.
public struct ModelQuirks: Equatable, Sendable {
    public var sendsTemperature: Bool
    /// Fields that ask the model not to reason (sent when `thinking == .off`).
    public var thinkingOff: [String: QuirkValue]
    /// The server takes a JSON schema for the reply (Anthropic's `output_config.format`), so the reply cannot be anything else.
    public var structuredReply: Bool = false

    static let plain = ModelQuirks(sendsTemperature: true, thinkingOff: [:])

    public static func lookup(host: String, port: Int?, model: String, kind: EngineKind) -> ModelQuirks {
        if case .anthropic = kind { return anthropic(model.lowercased()) }
        let host = host.lowercased()
        var id = model.lowercased()
        if id.hasPrefix("models/") { id.removeFirst("models/".count) }

        if host == "generativelanguage.googleapis.com" { return gemini(id) }
        if host == "api.openai.com" { return openAI(id) }
        if host == "openrouter.ai" { return with(["reasoning": .object(["enabled": .bool(false)])]) }
        if host == "api.deepseek.com" { return with(["thinking": .object(["type": .string("disabled")])]) }
        if (host.hasPrefix("dashscope") && host.hasSuffix(".aliyuncs.com")) || host.hasSuffix("maas.aliyuncs.com") {
            return with(["enable_thinking": .bool(false)])
        }
        // Ollama: "none" requests no thinking; its `think` field is documented only for the Responses API
        // (https://docs.ollama.com/api/openai-compatibility; qwen3.5 accepted "none", bench 2026-10-17).
        if host == "ollama.com" || (ChatTranslation.isOnThisMac(host: host) && port == 11434) {
            return with(["reasoning_effort": .string("none")])
        }
        return .plain
    }

    /// Claude 5.x answers `temperature` with HTTP 400 ("`temperature` is deprecated for this model", 2026-10-17), so none is sent.
    /// Claude 5 models think when `thinking` is left out (haiku-5-5 measured 2026-10-21: a thinking block and ~500 output tokens per
    /// call, past the deadline), and each says differently how to stop it (claude-api skill, cached 2026-10-06):
    /// - Haiku 5.5, Sonnet 5, Opus 5: `{type: disabled}` (Haiku and Opus 5 only at effort high or below; their defaults are medium and
    ///   high, and no request here sets another);
    /// - Sonnet 5.5: `disabled` is a 400, `{type: between_tools}` (no other field) is the off switch;
    /// - Opus 5.5, Fable 5 / 5.1 (and the Mythos counterparts): thinking cannot be disabled (400), so `thinking` is left out and
    ///   `output_config.effort` is `low`.
    /// Opus 4.8 / 4.7 / 4.6, Sonnet 4.6 and Haiku 4.5 do not think unless asked, and an id this table does not know is treated the same:
    /// nothing is sent (the API default, today's behaviour). `structuredReply` holds for the rows above, probed 2026-10-21.
    private static func anthropic(_ id: String) -> ModelQuirks {
        func off(_ thinking: [String: QuirkValue]) -> ModelQuirks {
            ModelQuirks(sendsTemperature: false, thinkingOff: thinking, structuredReply: true)
        }
        let disabled = ["thinking": QuirkValue.object(["type": .string("disabled")])]
        switch id.replacing(/-\d{8}$/, with: "") {
        case "claude-haiku-5-5", "claude-sonnet-5", "claude-opus-5": return off(disabled)
        case "claude-sonnet-5-5": return off(["thinking": .object(["type": .string("between_tools")])])
        case "claude-opus-5-5", "claude-fable-5", "claude-fable-5-1", "claude-mythos-5", "claude-mythos-5-1":
            return off(["output_config": .object(["effort": .string("low")])])
        default: return ModelQuirks(sendsTemperature: false, thinkingOff: [:])
        }
    }

    private static func with(_ fields: [String: QuirkValue]) -> ModelQuirks {
        ModelQuirks(sendsTemperature: true, thinkingOff: fields)
    }

    private static func effort(_ level: String, temperature: Bool = true) -> ModelQuirks {
        ModelQuirks(sendsTemperature: temperature, thinkingOff: ["reasoning_effort": .string(level)])
    }

    /// Gemini's OpenAI endpoint, https://ai.google.dev/gemini-api/docs/openai, and live probes 2026-10-17: an invalid
    /// level answers "Valid values are: high, low, medium, minimal, none"; 3.1-flash-lite and 3.5-flash-lite
    /// accepted "minimal" (bench MODELS.md); gemini-3.8-flash's lowest level is "low".
    private static func gemini(_ id: String) -> ModelQuirks {
        if id.hasPrefix("gemini-2.5") { return effort("none") }
        if id.hasPrefix("gemini-3") || id.hasPrefix("gemini-flash") {
            return effort(id.contains("flash-lite") ? "minimal" : "low")
        }
        return .plain
    }

    /// OpenAI chat completions, bench 2026-10-17 and live probes: gpt-5-nano answered `temperature: 0` with 400
    /// "'temperature' does not support 0 with this model"; gpt-5.4-mini and gpt-5.6-luna took `reasoning_effort:
    /// "none"` and are benched without temperature; gpt-5 / -mini / -nano take "minimal"; o-series reason at least "low".
    private static func openAI(_ id: String) -> ModelQuirks {
        if id.wholeMatch(of: /gpt-5(-mini|-nano)?(-\d{4}-\d{2}-\d{2})?/) != nil { return effort("minimal", temperature: false) }
        if id.wholeMatch(of: /gpt-5\.[1-9]\d*.*/) != nil || id.wholeMatch(of: /gpt-[\d.]+-(luna|sol|astra).*/) != nil {
            return effort("none", temperature: false)
        }
        if id.wholeMatch(of: /o[134](-.*)?/) != nil { return effort("low", temperature: false) }
        return .plain
    }
}
