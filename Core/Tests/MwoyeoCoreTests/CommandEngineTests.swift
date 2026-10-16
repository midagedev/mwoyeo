import Foundation
import Testing
@testable import MwoyeoCore

@Suite struct CommandEngineTests {
    @Test func encodesOneJSONLine() throws {
        let d = CommandEngine.encodeRequest(lines: ["a", "b\n\"c\""], source: "ja", target: "ko")
        let s = String(decoding: d, as: UTF8.self)
        #expect(s.hasSuffix("\n") && s.dropLast().filter { $0 == "\n" }.isEmpty)
        let o = try JSONSerialization.jsonObject(with: d) as! [String: Any]
        #expect(o["source"] as? String == "ja" && o["target"] as? String == "ko")
        #expect(o["lines"] as? [String] == ["a", "b\n\"c\""])
        let unknown = try JSONSerialization.jsonObject(with: CommandEngine.encodeRequest(lines: [], source: nil, target: "ko")) as! [String: Any]
        #expect(unknown["source"] is NSNull)
    }

    @Test func decodesWithLeadingLogLines() throws {
        let out = "loading model...\n{\"progress\": 1}\n{\"translations\": [\"x\", \"y\"]}\n"
        #expect(try CommandEngine.decodeResponse(Data(out.utf8), count: 2) == ["x", "y"])
    }

    @Test func errorLineIsAServerError() {
        #expect(throws: ChatTranslationError.server("no GPU")) {
            try CommandEngine.decodeResponse(Data("warn\n{\"error\": \"no GPU\"}\n".utf8), count: 1)
        }
    }

    @Test func wrongCountAndNoJSONAreTyped() {
        #expect(throws: ChatTranslationError.countMismatch(expected: 3, got: 1)) {
            try CommandEngine.decodeResponse(Data(#"{"translations": ["a"]}"#.utf8), count: 3)
        }
        #expect(throws: ChatTranslationError.malformed("no JSON line on stdout")) {
            try CommandEngine.decodeResponse(Data("just text\n".utf8), count: 1)
        }
    }

    @Test func decodesTheEchoExampleOutput() throws {
        // stdout of: echo '{"source":"ja","target":"ko","lines":["a","b"]}' | python3 -I tools/engine-examples/echo-engine.py
        #expect(try CommandEngine.decodeResponse(Data("{\"translations\": [\"[ko] a\", \"[ko] b\"]}\n".utf8), count: 2) == ["[ko] a", "[ko] b"])
    }
}
