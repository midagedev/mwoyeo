import Foundation

/// Starting points for the "Add engine" list. An empty `model` means the model list comes from `GET /models`.
/// Base URLs were checked against each provider's own page on 2026-10-17 unless a comment says `verified: false`.
public enum EnginePresets {
    public struct Preset: Equatable, Sendable {
        public var name: String
        public var hint: String
        public var needsKey: Bool
        public var keyURL: URL?
        /// The model the app picks from the live model list when it is there (bench 2026-10-17).
        public var suggestedModel: String? = nil
        /// A template: copy it with `instantiate()` to get a config with its own `id`.
        public var config: EngineConfig

        public func instantiate() -> EngineConfig {
            EngineConfig(name: name, kind: config.kind)
        }
    }

    private static func chat(_ name: String, _ hint: String, _ base: String, key: String?, needsKey: Bool = true,
                             suggested: String? = nil) -> Preset {
        Preset(name: name, hint: hint, needsKey: needsKey, keyURL: key.flatMap(URL.init(string:)), suggestedModel: suggested,
               config: EngineConfig(name: name, kind: .openAICompatible(
                   baseURL: URL(string: base)!, model: "", thinking: .off, extraHeaders: [:])))
    }

    public static let all: [Preset] = [
        // https://ai.google.dev/gemini-api/docs/openai
        chat("Gemini", "Free key at aistudio.google.com", "https://generativelanguage.googleapis.com/v1beta/openai/",
             key: "https://aistudio.google.com/apikey", suggested: "gemini-3.1-flash-lite"),
        // https://api-docs.deepseek.com/
        chat("DeepSeek", "Low price per line", "https://api.deepseek.com", key: "https://platform.deepseek.com/api_keys"),
        // https://api.openai.com/v1/chat/completions answered 200 in the engine bench, 2026-10-17
        chat("OpenAI", "Your OpenAI API key", "https://api.openai.com/v1", key: "https://platform.openai.com/api-keys",
             suggested: "gpt-5.6-luna"),
        // https://openrouter.ai/docs/api-reference/overview
        chat("OpenRouter", "One key for many models", "https://openrouter.ai/api/v1", key: "https://openrouter.ai/keys"),
        // https://console.groq.com/docs/openai
        chat("Groq", "Fast, with a free tier", "https://api.groq.com/openai/v1", key: "https://console.groq.com/keys"),
        // verified: false (the current Alibaba Cloud pages list workspace URLs, https://{WorkspaceId}.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1,
        // and do not mention dashscope-intl.aliyuncs.com; edit the base URL if your key is bound to a workspace)
        chat("Qwen (Alibaba Cloud)", "International endpoint", "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
             key: "https://modelstudio.console.alibabacloud.com/"),
        // https://docs.ollama.com/api/openai-compatibility
        chat("Ollama", "Runs on this Mac, no key", "http://localhost:11434/v1", key: nil, needsKey: false),
        // https://lmstudio.ai/docs/developer/openai-compat
        chat("LM Studio", "Runs on this Mac, no key", "http://localhost:1234/v1", key: nil, needsKey: false),
        // https://api.anthropic.com/v1/messages answered in the engine bench, 2026-10-17 (the key page is verified: false)
        Preset(name: "Claude", hint: "Your Anthropic API key", needsKey: true,
               keyURL: URL(string: "https://console.anthropic.com/settings/keys"), suggestedModel: "claude-haiku-5-5",
               config: EngineConfig(name: "Claude", kind: .anthropic(
                   baseURL: EngineKind.anthropicDefaultBaseURL, model: "", thinking: .off))),
        // https://developers.deepl.com/docs/getting-started/auth
        // The host follows the key (DeepLTranslation.resolvedBaseURL): a key ending in :fx is a Free key.
        Preset(name: "DeepL", hint: "Free or Pro key from deepl.com/pro-api", needsKey: true,
               keyURL: URL(string: "https://www.deepl.com/pro-api"),
               config: EngineConfig(name: "DeepL", kind: .deepL(baseURL: URL(string: "https://api.deepl.com")!, formality: nil))),
        // https://docs.libretranslate.com/guides/api_usage/ (README of github.com/LibreTranslate/LibreTranslate links there)
        Preset(name: "LibreTranslate", hint: "Self-hosted, default http://localhost:5000; the key is optional", needsKey: false,
               keyURL: nil,
               config: EngineConfig(name: "LibreTranslate", kind: .httpTemplate(HTTPTemplate(
                   url: "http://localhost:5000/translate",
                   headers: ["Content-Type": "application/json"],
                   body: #"{"q": {{text}}, "source": "{{source}}", "target": "{{target}}", "api_key": "{{key}}"}"#,
                   resultPath: "translatedText")))),
        // https://github.com/OwO-Network/DeepLX (README: POST /translate, default port 1188, answer in "data")
        Preset(name: "DeepLX", hint: "Self-hosted, default http://localhost:1188", needsKey: false, keyURL: nil,
               config: EngineConfig(name: "DeepLX", kind: .httpTemplate(HTTPTemplate(
                   url: "http://localhost:1188/translate",
                   headers: ["Content-Type": "application/json"],
                   body: #"{"text": {{text}}, "source_lang": "{{source_upper}}", "target_lang": "{{target_upper}}"}"#,
                   resultPath: "data")))),
    ]
}
