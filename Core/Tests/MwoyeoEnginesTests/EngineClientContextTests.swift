import Foundation
import Darwin
import Testing
import MwoyeoCore
@testable import MwoyeoEngines

/// A throwaway local server for the context call: it logs each POST (path and body) and answers from a plan.
/// `python3 -I -c <script> <port> <plan.json> <log>`; the pid is the one the test captured and terminates.
final class PlanServer: @unchecked Sendable {
    private static let script = """
    import json, sys
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    port, plan_path, log_path = int(sys.argv[1]), sys.argv[2], sys.argv[3]
    plan = json.load(open(plan_path))
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def reply(self, status, obj):
            data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        def do_POST(self):
            raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            with open(log_path, "ab") as f:
                f.write(json.dumps({"path": self.path, "body": raw.decode("utf-8")}, ensure_ascii=False).encode("utf-8") + b"\\n")
            route = plan.get(self.path.rstrip("/"))
            if route is None:
                return self.reply(404, {"error": {"message": "no route"}})
            body = json.loads(raw or b"{}")
            for field in route.get("reject", []):
                if field in body:
                    return self.reply(400, route["rejectBody"])
            self.reply(200, route["ok"])
    ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
    """

    let port: Int
    private let process = Process()
    private let dir: URL
    private var logURL: URL { dir.appendingPathComponent("log") }

    var base: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var v1: URL { URL(string: "http://127.0.0.1:\(port)/v1")! }

    /// `plan` maps a path to `{"ok": reply object, "reject": [fields that make it answer 400], "rejectBody": object}`.
    init(plan: [String: Any]) throws {
        port = try Self.freePort()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: plan).write(to: dir.appendingPathComponent("plan.json"))
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-I", "-c", Self.script, "\(port)", dir.appendingPathComponent("plan.json").path, logURL.path]
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        for _ in 0..<100 {
            if Self.accepts(port) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        stop()
        throw NSError(domain: "PlanServer", code: 1)
    }

    func stop() {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: dir)
    }

    /// Every POST the server saw: its path and the parsed JSON body.
    var posts: [(path: String, body: [String: Any])] {
        ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { line in
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String],
                  let path = o["path"], let raw = o["body"],
                  let body = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { return nil }
            return (path, body)
        }
    }

    /// The raw body of the nth POST, as the server read it.
    func rawBody(_ n: Int) -> Data? {
        let lines = ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").split(separator: "\n")
        guard n < lines.count, let o = try? JSONSerialization.jsonObject(with: Data(lines[n].utf8)) as? [String: String] else { return nil }
        return o["body"].map { Data($0.utf8) }
    }

    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0,
                               sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard ok == 0 else { throw NSError(domain: "PlanServer", code: 2) }
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &out) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return Int(UInt16(bigEndian: out.sin_port))
    }

    private static func accepts(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                               sin_port: UInt16(port).bigEndian, sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
                               sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }
}

/// The context call end to end against a local server: what is sent, what comes back, and the heal path.
@Suite struct EngineClientContextTests {
    let key = "sk-test-\(UUID().uuidString)"

    /// `ContextOptions()` is Off (design §9), so the context tests switch what they exercise on.
    private static let on = ContextOptions(enabled: true, includeLearned: true, deepLInstructions: true)

    private static func fixtureJSON(_ name: String) throws -> Any {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/usage/\(name).json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: root))
    }

    private func request(target: String = "ko", source: String? = "ja") -> ContextRequest {
        ContextRequest(items: ["アリスは来た", "田中も来た"],
                       before: [ContextLine(source: "前の行")], after: ["次の行"],
                       memory: [MemoryEntry(src: "アリス", dst: "앨리스", kind: .person, gender: .f,
                                            addressing: [Addressing(to: "田中", register: .casual)]),
                                MemoryEntry(src: "田中", dst: "다나카", kind: .person)],
                       card: DocumentCard(appName: "Messages", domain: "social", title: "Alice Smith"),
                       note: "Close friends.", referents: [Referent(pronoun: "he", refersTo: "田中")],
                       source: source, target: target, glossary: [("Mwoyeo", "뭐여")],
                       threadKey: "mwoyeo-0123456789abcdef")
    }

    @Test func openAICompatibleContextCallReturnsLinesTermsAndUsage() async throws {
        let server = try PlanServer(plan: ["/v1/chat/completions": ["ok": try Self.fixtureJSON("openai-chat-cached")]])
        defer { server.stop() }
        let engine = EngineConfig(name: "local", kind: .openAICompatible(baseURL: server.v1, model: "m", thinking: .off, extraHeaders: [:]))
        let client = EngineClient(secrets: MemorySecrets())
        let reply = try await client.translate(request(), options: Self.on, engine: engine)
        #expect(reply.lines == ["안녕하세요", "앨리스가 왔다"])
        #expect(reply.terms == [TermHint(src: "アリス", dst: "앨리스", kind: .person, gender: .f)])
        #expect(reply.usage == TokenUsage(prompt: 1190, completion: 57, cached: 1024, cacheWrite: 0))
        let post = try #require(server.posts.first)
        #expect(server.posts.count == 1 && post.path == "/v1/chat/completions")
        // A server on this Mac: no OpenAI-only fields, and the title goes (on device).
        #expect(post.body["prompt_cache_key"] == nil && post.body["store"] == nil)
        let messages = try #require(post.body["messages"] as? [[String: String]])
        #expect(messages[0]["content"]?.contains("Document: Messages (social), window \"Alice Smith\".") == true)
        let last = try #require(try JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as? [String: Any])
        #expect((last["translate"] as? [[String: Any]])?.count == 2 && (last["memory"] as? [String])?.count == 2)
    }

    @Test func theOldApiSendsTodaysBody() async throws {
        let server = try PlanServer(plan: ["/v1/chat/completions": ["ok": ["choices": [["message": ["role": "assistant", "content": #"{"translations":["a","b"]}"#]]]]]])
        defer { server.stop() }
        let engine = EngineConfig(name: "local", kind: .openAICompatible(baseURL: server.v1, model: "m", thinking: .off, extraHeaders: [:]))
        let lines = try await EngineClient(secrets: MemorySecrets()).translate(["Hello", "World"], source: "en", target: "ko",
                                                                              glossary: [("Mwoyeo", "뭐여")], engine: engine)
        #expect(lines == ["a", "b"])
        let sent = try #require(server.rawBody(0))
        let today = ChatTranslation.requestBody(lines: ["Hello", "World"], source: "en", target: "ko", glossary: [("Mwoyeo", "뭐여")],
                                                model: "m", baseURL: server.v1, thinking: .off)
        #expect(sent == today, "\(String(decoding: sent, as: UTF8.self)) != \(String(decoding: today, as: UTF8.self))")
    }

    @Test func anthropicContextCallSendsTwoMarkersAndReadsCacheUsage() async throws {
        let server = try PlanServer(plan: ["/v1/messages": ["ok": try Self.fixtureJSON("anthropic-cache-read")]])
        defer { server.stop() }
        let engine = EngineConfig(name: "claude", kind: .anthropic(baseURL: server.base, model: "claude-haiku-5-5", thinking: .off))
        let client = EngineClient(secrets: MemorySecrets([engine.id: key]))
        let reply = try await client.translate(request(), options: Self.on, engine: engine)
        #expect(reply.lines.count == 2 && reply.usage == TokenUsage(prompt: 75 + 1536, completion: 57, cached: 1536, cacheWrite: 0))
        let body = try #require(server.posts.first?.body)
        let system = try #require(body["system"] as? [[String: Any]])
        #expect(system.count == 2 && system.allSatisfy { ($0["cache_control"] as? [String: String]) == ["type": "ephemeral"] })
        // The cloud engine got the app name and the category, not the window title.
        #expect((system[1]["text"] as? String)?.contains("Document: Messages (social).") == true)
        #expect(!String(decoding: server.rawBody(0) ?? Data(), as: UTF8.self).contains("Alice Smith"))
    }

    @Test func deepLHealsARejectedContextFieldOnceAndRemembersIt() async throws {
        let msg = ["message": "Parameter 'custom_instructions' is not supported for this language pair."]
        let server = try PlanServer(plan: ["/v2/translate": ["ok": ["translations": [["text": "a"], ["text": "b"]]],
                                                              "reject": ["custom_instructions"], "rejectBody": msg]])
        defer { server.stop() }
        let engine = EngineConfig(name: "deepl", kind: .deepL(baseURL: server.base, formality: nil))
        let client = EngineClient(secrets: MemorySecrets([engine.id: key]))
        let first = try await client.translate(request(target: "ja", source: "en"), options: Self.on, engine: engine)
        #expect(first.lines == ["a", "b"] && first.usage == .zero && first.terms.isEmpty)
        #expect(server.posts.count == 2)                                                     // the 400, then the retry
        #expect(server.posts[0].body["custom_instructions"] != nil && server.posts[0].body["context"] != nil)
        #expect(server.posts[1].body["custom_instructions"] == nil && server.posts[1].body["context"] != nil)
        #expect(await client.learnedRejections(for: engine.id) == ["custom_instructions"])
        // The next call does not send it at all.
        _ = try await client.translate(request(target: "ja", source: "en"), options: Self.on, engine: engine)
        #expect(server.posts.count == 3 && server.posts[2].body["custom_instructions"] == nil)
    }

    @Test func offThroughTheContextCallEqualsTheOldCall() async throws {
        let server = try PlanServer(plan: ["/v1/chat/completions": ["ok": ["choices": [["message": ["role": "assistant", "content": #"{"translations":["a","b"]}"#]]]]]])
        defer { server.stop() }
        let engine = EngineConfig(name: "local", kind: .openAICompatible(baseURL: server.v1, model: "m", thinking: .off, extraHeaders: [:]))
        let client = EngineClient(secrets: MemorySecrets())
        _ = try await client.translate(["x", "y"], source: nil, target: "ko", glossary: [], engine: engine)
        _ = try await client.translate(ContextRequest(items: ["x", "y"], target: "ko"), options: .off, engine: engine)
        #expect(server.rawBody(0) != nil && server.rawBody(0) == server.rawBody(1))
    }

    /// The default options are Off: the context call with a request full of memory sends the old call's bytes.
    @Test func theDefaultOptionsSendTodaysBodyThroughTheContextCall() async throws {
        let server = try PlanServer(plan: ["/v1/chat/completions": ["ok": ["choices": [["message": ["role": "assistant", "content": #"{"translations":["a","b"]}"#]]]]]])
        defer { server.stop() }
        let engine = EngineConfig(name: "local", kind: .openAICompatible(baseURL: server.v1, model: "m", thinking: .off, extraHeaders: [:]))
        let client = EngineClient(secrets: MemorySecrets())
        let rich = request()
        _ = try await client.translate(rich.items, source: rich.source, target: rich.target, glossary: rich.glossary, engine: engine)
        let reply = try await client.translate(rich, options: ContextOptions(), engine: engine)
        #expect(reply.lines == ["a", "b"])
        #expect(server.rawBody(0) != nil && server.rawBody(0) == server.rawBody(1))
    }

    @Test func aWrongIdTakesTheCountMismatchErrorPath() async throws {
        let content = #"{"t":[{"id":0,"text":"a"},{"id":0,"text":"b"}]}"#
        let server = try PlanServer(plan: ["/v1/chat/completions": ["ok": ["choices": [["message": ["role": "assistant", "content": content]]]]]])
        defer { server.stop() }
        let engine = EngineConfig(name: "local", kind: .openAICompatible(baseURL: server.v1, model: "m", thinking: .off, extraHeaders: [:]))
        do throws(EngineError) {
            _ = try await EngineClient(secrets: MemorySecrets()).translate(request(), options: Self.on, engine: engine)
            Issue.record("expected a count mismatch")
        } catch {
            #expect(error == .countMismatch(expected: 2, got: 1))
        }
    }
}
