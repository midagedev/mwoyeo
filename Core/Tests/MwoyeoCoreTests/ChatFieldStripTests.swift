import Foundation
import Testing
@testable import MwoyeoCore

@Suite struct ChatFieldStripTests {
    private func body(_ fields: Set<String>) -> [String: Any] {
        let d = ChatTranslation.requestBody(lines: ["a"], source: nil, target: "ko", glossary: [], model: "m")
        return try! JSONSerialization.jsonObject(with: ChatTranslation.withoutFields(d, fields)) as! [String: Any]
    }

    @Test func removesOnlyTheNamedFields() {
        #expect(body([])["temperature"] != nil)
        let stripped = body(["temperature", "reasoning_effort"])
        #expect(stripped["temperature"] == nil && stripped["model"] as? String == "m" && stripped["messages"] != nil)
    }

    @Test func aBodyThatIsNotJSONComesBackUnchanged() {
        let junk = Data("not json".utf8)
        #expect(ChatTranslation.withoutFields(junk, ["temperature"]) == junk)
    }
}
