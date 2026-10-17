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
}
