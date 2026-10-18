import Foundation
import Testing
@testable import MwoyeoCore

@Suite struct DeepLTranslationTests {
    @Test func bodyUsesUpperCaseCodesAndOptionalFields() throws {
        let d = DeepLTranslation.requestBody(lines: ["a", "b"], source: "en", target: "pt-BR", formality: "less")
        let o = try JSONSerialization.jsonObject(with: d) as! [String: Any]
        #expect(o["text"] as? [String] == ["a", "b"] && o["target_lang"] as? String == "PT-BR")
        #expect(o["source_lang"] as? String == "EN" && o["formality"] as? String == "less")
        let o2 = try JSONSerialization.jsonObject(with: DeepLTranslation.requestBody(lines: ["a"], source: nil, target: "zh-Hans", formality: nil)) as! [String: Any]
        #expect(o2["target_lang"] as? String == "ZH" && o2["source_lang"] == nil && o2["formality"] == nil)
    }

    @Test func parsesTheMockServerReplyAndErrors() throws {
        let reply = #"{"translations": [{"detected_source_language": "EN", "text": "⟦KO⟧ a"}, {"detected_source_language": "EN", "text": "⟦KO⟧ b"}]}"#
        #expect(try DeepLTranslation.parseTranslations(Data(reply.utf8), count: 2) == ["⟦KO⟧ a", "⟦KO⟧ b"])
        #expect(throws: ChatTranslationError.server("Authorization failure, check auth_key")) {
            try DeepLTranslation.parseTranslations(Data(#"{"message": "Authorization failure, check auth_key"}"#.utf8), count: 1)
        }
        #expect(throws: ChatTranslationError.countMismatch(expected: 3, got: 2)) {
            try DeepLTranslation.parseTranslations(Data(reply.utf8), count: 3)
        }
    }

    // Engines saved as "DeepL Free" or "DeepL Pro" keep working: only the host and the key matter here.
    private static let pro = URL(string: "https://api.deepl.com")!
    private static let free = URL(string: "https://api-free.deepl.com")!

    @Test func aFxKeyGoesToTheFreeHost() {
        #expect(DeepLTranslation.resolvedBaseURL(Self.pro, key: "abc-123:fx") == Self.free)
        #expect(DeepLTranslation.resolvedBaseURL(Self.free, key: "abc-123:fx") == Self.free)
    }

    @Test func otherKeysGoToTheProHost() {
        #expect(DeepLTranslation.resolvedBaseURL(Self.pro, key: "abc-123") == Self.pro)
        #expect(DeepLTranslation.resolvedBaseURL(Self.free, key: "abc-123") == Self.pro)
        #expect(DeepLTranslation.resolvedBaseURL(Self.free, key: nil) == Self.pro)
    }

    @Test func whitespaceAroundTheKeyIsIgnored() {
        #expect(DeepLTranslation.resolvedBaseURL(Self.pro, key: "  abc:fx\n") == Self.free)
    }

    @Test func aProxyHostIsKept() {
        let proxy = URL(string: "https://deepl.example.com/relay")!
        #expect(DeepLTranslation.resolvedBaseURL(proxy, key: "abc:fx") == proxy)
        #expect(DeepLTranslation.resolvedBaseURL(proxy, key: "abc") == proxy)
    }
}
