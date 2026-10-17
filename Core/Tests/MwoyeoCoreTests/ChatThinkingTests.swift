import Foundation
import Testing
@testable import MwoyeoCore

@Suite struct ChatThinkingTests {
    private func body(_ base: String?, _ thinking: Thinking = .off, model: String = "m") -> [String: Any] {
        let d = ChatTranslation.requestBody(lines: ["a"], source: nil, target: "ko", glossary: [], model: model,
                                            baseURL: base.flatMap(URL.init(string:)), thinking: thinking)
        return try! JSONSerialization.jsonObject(with: d) as! [String: Any]
    }

    @Test func geminiGetsAnEffortLevelByModel() {
        let base = "https://generativelanguage.googleapis.com/v1beta/openai/"
        #expect(body(base, model: "gemini-2.5-flash")["reasoning_effort"] as? String == "none")
        #expect(body(base, model: "gemini-3.1-flash-lite")["reasoning_effort"] as? String == "minimal")
    }

    @Test func openRouterGetsReasoningDisabled() {
        let r = body("https://openrouter.ai/api/v1")["reasoning"] as? [String: Bool]
        #expect(r == ["enabled": false])
    }

    @Test func ollamaGetsReasoningEffortNoneNotThink() {
        for base in ["http://localhost:11434/v1", "http://127.0.0.1:11434/v1", "https://ollama.com/v1"] {
            let b = body(base)
            #expect(b["reasoning_effort"] as? String == "none")
            #expect(b["think"] == nil)
        }
        #expect(body("http://localhost:1234/v1")["reasoning_effort"] == nil)
    }

    @Test func deepSeekAndQwenFields() {
        #expect((body("https://api.deepseek.com")["thinking"] as? [String: String]) == ["type": "disabled"])
        #expect(body("https://dashscope-intl.aliyuncs.com/compatible-mode/v1")["enable_thinking"] as? Bool == false)
    }

    @Test func unknownHostsAndProviderModeGetNothingExtra() {
        let plain = Set(body(nil).keys)
        #expect(plain == ["model", "temperature", "stream", "messages"])
        for base in ["https://api.openai.com/v1", "https://api.groq.com/openai/v1", "https://gateway.example.com/v1"] {
            #expect(Set(body(base).keys) == plain)
        }
        #expect(Set(body("https://api.deepseek.com", .provider).keys) == plain)
        #expect(Set(body("https://generativelanguage.googleapis.com/v1beta/openai/", .provider, model: "gemini-3.1-flash-lite").keys) == plain)
    }
}
