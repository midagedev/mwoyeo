import Foundation
import Testing
@testable import MwoyeoCore

@Suite struct HTTPTemplateTests {
    private let nasty = "say \"hi\" & bye\nline2 😀 a=b?c"

    private func template(url: String = "http://h/t", headers: [String: String] = [:], body: String = "",
                          path: String = "r", batching: HTTPTemplate.Batching = .perLine) -> HTTPTemplate {
        HTTPTemplate(url: url, headers: headers, body: body, resultPath: path, batching: batching)
    }

    private func one(_ t: HTTPTemplate, lines: [String]? = nil) throws -> HTTPTemplate.Request {
        try HTTPTemplate.requests(t, lines: lines ?? [nasty], source: "en", target: "ko", key: "SECRET").first!
    }

    @Test func textInAJSONBodyIsEscapedWithOrWithoutQuotes() throws {
        for body in [#"{"q": {{text}}}"#, #"{"q": "{{text}}"}"#] {
            let r = try one(template(body: body))
            let o = try JSONSerialization.jsonObject(with: r.body!) as! [String: Any]
            #expect(o["q"] as? String == nasty)
        }
    }

    @Test func textInTheURLIsPercentEncoded() throws {
        let r = try one(template(url: "http://h/t?q={{text}}&k={{key}}"))
        #expect(r.url == "http://h/t?q=say%20%22hi%22%20%26%20bye%0Aline2%20%F0%9F%98%80%20a%3Db%3Fc&k=SECRET")
        #expect(URL(string: r.url) != nil)
    }

    @Test func textInAFormBodyIsPercentEncoded() throws {
        let r = try one(template(body: "q={{text}}&target={{target_upper}}"))
        #expect(String(decoding: r.body!, as: UTF8.self) == "q=say%20%22hi%22%20%26%20bye%0Aline2%20%F0%9F%98%80%20a%3Db%3Fc&target=KO")
    }

    @Test func headersTakeKeyAndLanguagesWithoutNewlines() throws {
        let r = try one(template(headers: ["Authorization": "Bearer {{key}}", "X-T": "{{text}} {{source_upper}}>{{target}}"],
                                 body: "{{text}}"))
        #expect(r.headers["Authorization"] == "Bearer SECRET")
        #expect(r.headers["X-T"] == "say \"hi\" & bye line2 😀 a=b?c EN>ko")
    }

    @Test func languagePlaceholdersAndUpperCase() throws {
        let r = try one(template(body: #"{"s": "{{source}}", "t": "{{target}}", "S": "{{source_upper}}", "T": "{{target_upper}}", "x": "{{text}}"}"#))
        let o = try JSONSerialization.jsonObject(with: r.body!) as! [String: String]
        #expect(o["s"] == "en" && o["t"] == "ko" && o["S"] == "EN" && o["T"] == "KO")
        let zh = try HTTPTemplate.requests(template(body: #"{"T": "{{target_upper}}", "x": {{text}}}"#), lines: ["a"], source: nil, target: "zh-Hans", key: nil)
        #expect(String(decoding: zh[0].body!, as: UTF8.self).contains("\"ZH\""))
    }

    @Test func perLineMakesOneRequestPerLineAndJSONArrayOne() throws {
        let per = try HTTPTemplate.requests(template(body: "{{text}}"), lines: ["a", "b", "c"], source: nil, target: "ko", key: nil)
        #expect(per.count == 3)
        let arr = template(body: #"{"q": {{lines}}}"#, batching: .jsonArray)
        let r = try HTTPTemplate.requests(arr, lines: ["a", nasty], source: nil, target: "ko", key: nil)
        #expect(r.count == 1)
        let o = try JSONSerialization.jsonObject(with: r[0].body!) as! [String: Any]
        #expect(o["q"] as? [String] == ["a", nasty])
    }

    @Test func unknownPlaceholderNamesItself() {
        let p = HTTPTemplate.validate(template(body: "{{text}} {{secret_sauce}}"))
        #expect(p.contains { $0.contains("{{secret_sauce}}") })
        #expect(throws: HTTPTemplateError.self) { try HTTPTemplate.requests(template(body: "{{text}} {{nope}}"), lines: ["a"], source: nil, target: "ko", key: nil) }
    }

    @Test func linesNeedsJSONArrayAndTheBody() {
        #expect(HTTPTemplate.validate(template(body: "{{lines}}")).contains { $0.contains("{{lines}}") })
        #expect(HTTPTemplate.validate(template(url: "http://h/{{lines}}", body: "{{lines}}", batching: .jsonArray)).contains { $0.contains("only in the body") })
        #expect(HTTPTemplate.validate(template(body: #"{"q": {{lines}}}"#, batching: .jsonArray)).isEmpty)
        #expect(HTTPTemplate.validate(template(body: "{{text}}", batching: .jsonArray)).contains { $0.contains("{{text}}") })
    }

    @Test func otherProblemsAreReported() {
        #expect(!HTTPTemplate.validate(template(url: "ftp://h", body: "{{text}}")).isEmpty)
        #expect(!HTTPTemplate.validate(template(body: #"{"q": {{text}}"#)).isEmpty)
        #expect(HTTPTemplate.validate(HTTPTemplate(method: "FETCH", url: "http://h", body: "{{text}}", resultPath: "r")).contains { $0.contains("FETCH") })
        #expect(HTTPTemplate.validate(template(body: "{{text}}", path: "a[b]")).contains { $0.contains("resultPath") })
        #expect(HTTPTemplate.validate(template(body: "{{text}}", path: "")).contains { $0.contains("resultPath") })
        #expect(HTTPTemplate.validate(template(body: #"{"q": 1}"#)).contains { $0.contains("{{text}}") })
    }

    private func parse(_ path: String, _ json: String, count: Int) throws -> [String] {
        try HTTPTemplate.parseResponse(template(path: path), data: Data(json.utf8), count: count)
    }

    @Test func resultPaths() throws {
        #expect(try parse("translatedText", #"{"translatedText": "x"}"#, count: 1) == ["x"])
        #expect(try parse("data.translations[0].translatedText", #"{"data": {"translations": [{"translatedText": "x"}]}}"#, count: 1) == ["x"])
        #expect(try parse("translations[*].text", #"{"translations": [{"text": "a"}, {"text": "b"}]}"#, count: 2) == ["a", "b"])
        #expect(try parse("result", #"{"result": ["a", "b"]}"#, count: 2) == ["a", "b"])
        #expect(try parse("[0]", #"["a"]"#, count: 1) == ["a"])
    }

    @Test func resultPathFailuresNameTheSegment() {
        #expect(throws: HTTPTemplateError.countMismatch(expected: 2, got: 1)) { try parse("translatedText", #"{"translatedText": "x"}"#, count: 2) }
        #expect(throws: HTTPTemplateError.path(segment: "translatedText", reason: "not a string")) { try parse("translatedText", #"{"translatedText": 5}"#, count: 1) }
        #expect(throws: HTTPTemplateError.path(segment: "text", reason: "not a string")) { try parse("t[*].text", #"{"t": [{"text": "a"}, {"text": 2}]}"#, count: 2) }
        #expect(throws: HTTPTemplateError.path(segment: "missing", reason: "missing key")) { try parse("data.missing", #"{"data": {}}"#, count: 1) }
        #expect(throws: HTTPTemplateError.path(segment: "[3]", reason: "index out of range (1 items)")) { try parse("a[3]", #"{"a": ["x"]}"#, count: 1) }
        #expect(throws: HTTPTemplateError.path(segment: "[*]", reason: "not an array")) { try parse("a[*]", #"{"a": "x"}"#, count: 1) }
        #expect(throws: HTTPTemplateError.self) { try parse("a", "not json", count: 1) }
    }

    @Test func libreTranslatePresetAgainstItsDocsFixtures() throws {
        let t = try template(of: "LibreTranslate")
        #expect(HTTPTemplate.validate(t).isEmpty)
        let r = try HTTPTemplate.requests(t, lines: ["<p class=\"green\">Hello!</p>"], source: "en", target: "es", key: "xxxxxx")[0]
        #expect(r.method == "POST" && r.url == "http://localhost:5000/translate")
        let o = try JSONSerialization.jsonObject(with: r.body!) as! [String: String]
        #expect(o == ["q": "<p class=\"green\">Hello!</p>", "source": "en", "target": "es", "api_key": "xxxxxx"])
        // the response shown in https://docs.libretranslate.com/guides/api_usage/
        let reply = #"{"translatedText": "<p class=\"green\">¡Hola!</p>"}"#
        #expect(try HTTPTemplate.parseResponse(t, data: Data(reply.utf8), count: 1) == ["<p class=\"green\">¡Hola!</p>"])
    }

    @Test func deepLXPresetAgainstItsREADMEFixtures() throws {
        let t = try template(of: "DeepLX")
        #expect(HTTPTemplate.validate(t).isEmpty)
        let r = try HTTPTemplate.requests(t, lines: ["Hello, world!"], source: "en", target: "zh", key: nil)[0]
        #expect(r.url == "http://localhost:1188/translate")
        let o = try JSONSerialization.jsonObject(with: r.body!) as! [String: String]
        #expect(o == ["text": "Hello, world!", "source_lang": "EN", "target_lang": "ZH"])
        // the response shown in the DeepLX README
        let reply = #"{"alternatives":null,"code":200,"data":"你好，世界！","id":123,"method":"Free","source_lang":"EN","target_lang":"ZH"}"#
        #expect(try HTTPTemplate.parseResponse(t, data: Data(reply.utf8), count: 1) == ["你好，世界！"])
    }

    private func template(of name: String) throws -> HTTPTemplate {
        let p = try #require(EnginePresets.all.first { $0.name == name })
        guard case let .httpTemplate(t) = p.config.kind else { throw EngineConfigError.malformed("not a template") }
        return t
    }
}
