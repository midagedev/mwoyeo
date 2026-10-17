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

    static let plain = ModelQuirks(sendsTemperature: true, thinkingOff: [:])

    public static func lookup(host: String, port: Int?, model: String, kind: EngineKind) -> ModelQuirks {
        // Claude 5.x answers `temperature` with HTTP 400 ("`temperature` is deprecated for this model", 2026-10-17);
        // `.off` is the API default, so no thinking block either.
        if case .anthropic = kind { return ModelQuirks(sendsTemperature: false, thinkingOff: [:]) }
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
