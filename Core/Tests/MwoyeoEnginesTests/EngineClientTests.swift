import Foundation
import Testing
import MwoyeoCore
@testable import MwoyeoEngines

/// Offline: every test starts its own mock server. The key is random per test and must never show up in an error.
@Suite struct EngineClientTests {
    let key = "sk-test-\(UUID().uuidString)"

    private func setup(_ mode: String, kind: (MockServer) -> EngineKind, key: String? = nil) throws
        -> (MockServer, EngineClient, EngineConfig) {
        let server = try MockServer(mode: mode)
        let engine = EngineConfig(name: "mock", kind: kind(server))
        let secrets = MemorySecrets([engine.id: key ?? self.key])
        return (server, EngineClient(secrets: secrets), engine)
    }

    private func openAI(_ s: MockServer) -> EngineKind {
        .openAICompatible(baseURL: s.v1, model: "mock", thinking: .off, extraHeaders: [:])
    }

    private func run(_ client: EngineClient, _ engine: EngineConfig, _ lines: [String] = ["a", "b"]) async throws(EngineError) -> [String] {
        try await client.translate(lines, source: nil, target: "ko", glossary: [], engine: engine)
    }

    private func clean(_ error: EngineError) {
        #expect(!"\(error)".contains(key) && !error.userMessage.contains(key))
    }

    private func fails(_ mode: String, kind: (MockServer) -> EngineKind) async throws -> EngineError {
        let (server, client, engine) = try setup(mode, kind: kind)
        defer { server.stop() }
        do throws(EngineError) { _ = try await run(client, engine) } catch { clean(error); return error }
        Issue.record("expected an error in mode \(mode)")
        return .cancelled
    }

    // MARK: OpenAI-compatible

    @Test func openAIOk() async throws {
        let (server, client, engine) = try setup("ok", kind: openAI)
        defer { server.stop() }
        #expect(try await run(client, engine) == ["⟦Korean⟧ a", "⟦Korean⟧ b"])
        #expect(server.requests == ["POST /v1/chat/completions lines=2 mode=ok auth=present thinking_off=no"])
    }

    @Test func openAIFenced() async throws {
        let (server, client, engine) = try setup("fenced", kind: openAI)
        defer { server.stop() }
        #expect(try await run(client, engine) == ["⟦Korean⟧ a", "⟦Korean⟧ b"])
    }

    @Test func openAIShortAnswerIsCountMismatch() async throws {
        #expect(try await fails("short", kind: openAI) == .countMismatch(expected: 2, got: 1))
    }

    @Test func openAI401IsUnauthorized() async throws {
        guard case let .unauthorized(m) = try await fails("401", kind: openAI) else { return fail("not unauthorized") }
        #expect(m.contains("Incorrect API key"))
    }

    @Test func the401ThatEchoesTheKeyIsScrubbed() async throws {
        let (server, client, engine) = try setup("401echo", kind: openAI)
        defer { server.stop() }
        do throws(EngineError) { _ = try await run(client, engine); Issue.record("expected 401") } catch {
            guard case let .unauthorized(m) = error else { return fail("not unauthorized") }
            #expect(m.contains("***") && !m.contains(key))
            clean(error)
        }
    }

    @Test func openAI429ReadsRetryAfter() async throws {
        let error = try await fails("429", kind: openAI)
        #expect(error == .rateLimited(retryAfter: 7))
        #expect(error.userMessage.contains("7 s"))
    }

    @Test func openAIGarbageIsMalformed() async throws {
        guard case .malformed = try await fails("garbage", kind: openAI) else { return fail("not malformed") }
    }

    @Test func strictServerHealsAndTheFieldIsRemembered() async throws {
        let (server, client, engine) = try setup("strict", kind: openAI)
        defer { server.stop() }
        #expect(try await run(client, engine) == ["⟦Korean⟧ a", "⟦Korean⟧ b"])
        #expect(server.count("POST") == 2)  // the 400, then the retry without temperature
        #expect(await client.learnedRejections(for: engine.id) == ["temperature"])
        #expect(try await run(client, engine) == ["⟦Korean⟧ a", "⟦Korean⟧ b"])
        #expect(server.count("POST") == 3)  // stripped before sending: one request
    }

    @Test func seededRejectionsAreStrippedFromTheFirstRequest() async throws {
        let (server, client, engine) = try setup("strict", kind: openAI)
        defer { server.stop() }
        await client.seedRejections(["temperature"], for: engine.id)
        _ = try await run(client, engine)
        #expect(server.count("POST") == 1)
    }

    @Test func aRejectionNobodyCanHealIsRejected() async throws {
        // A model the mock 400s that our body has no matching field for: unknown path → 404 → rejected.
        let (server, client, _) = try setup("ok", kind: openAI)
        defer { server.stop() }
        let engine = EngineConfig(name: "x", kind: .openAICompatible(baseURL: server.base.appendingPathComponent("nope"),
                                                                     model: "m", thinking: .off, extraHeaders: [:]))
        do throws(EngineError) { _ = try await client.translate(["a"], source: nil, target: "ko", glossary: [], engine: engine); Issue.record("expected an error") }
        catch { guard case .rejected = error else { return fail("\(error)") } }
    }

    @Test func extraHeaderCarriesTheKeyPlaceholder() async throws {
        let server = try MockServer(mode: "ok")
        defer { server.stop() }
        let engine = EngineConfig(name: "x", kind: .openAICompatible(baseURL: server.v1, model: "m", thinking: .off,
                                                                      extraHeaders: ["x-api-key": "{{key}}"]))
        let client = EngineClient(secrets: MemorySecrets([engine.id: key]))
        _ = try await run(client, engine)
        #expect(server.requests.first?.contains("auth=present") == true)
    }

    // MARK: other kinds

    @Test func anthropicOk() async throws {
        let (server, client, engine) = try setup("ok", kind: { .anthropic(baseURL: $0.base, model: "claude-haiku-5-5", thinking: .off) })
        defer { server.stop() }
        #expect(try await run(client, engine) == ["⟦anthropic⟧ a", "⟦anthropic⟧ b"])
        #expect(server.requests == ["POST /v1/messages lines=2 mode=ok auth=present thinking_off=no"])
    }

    @Test func anthropicErrors() async throws {
        let kind: (MockServer) -> EngineKind = { .anthropic(baseURL: $0.base, model: "m", thinking: .off) }
        guard case .unauthorized = try await fails("401", kind: kind) else { return fail("not unauthorized") }
        guard case .malformed = try await fails("garbage", kind: kind) else { return fail("not malformed") }
    }

    @Test func anthropicNeedsAKeyAndSendsNothingWithout() async throws {
        let server = try MockServer(mode: "ok")
        defer { server.stop() }
        let engine = EngineConfig(name: "c", kind: .anthropic(baseURL: server.base, model: "m", thinking: .off))
        let client = EngineClient(secrets: MemorySecrets())
        await #expect(throws: EngineError.missingKey) { try await client.translate(["a"], source: nil, target: "ko", glossary: [], engine: engine) }
        await #expect(throws: EngineError.missingKey) { try await client.models(engine) }
        #expect(server.requests.isEmpty)
    }

    @Test func aCloudOpenAIEngineNeedsAKeyButALocalOneDoesNot() async throws {
        let client = EngineClient(secrets: MemorySecrets())
        let cloud = EngineConfig(name: "c", kind: .openAICompatible(baseURL: URL(string: "https://api.example.invalid/v1")!, model: "m",
                                                                      thinking: .off, extraHeaders: [:]))
        await #expect(throws: EngineError.missingKey) { try await client.translate(["a"], source: nil, target: "ko", glossary: [], engine: cloud) }
        let server = try MockServer(mode: "ok")
        defer { server.stop() }
        let local = EngineConfig(name: "l", kind: openAI(server))
        #expect(try await run(client, local).count == 2)
        #expect(server.requests.first?.contains("auth=absent") == true)
    }

    @Test func deepLOk() async throws {
        let (server, client, engine) = try setup("ok", kind: { .deepL(baseURL: $0.base, formality: nil) })
        defer { server.stop() }
        #expect(try await run(client, engine) == ["⟦KO⟧ a", "⟦KO⟧ b"])
        guard case .unauthorized = try await fails("401", kind: { .deepL(baseURL: $0.base, formality: nil) }) else {
            return fail("DeepL 403 is not unauthorized")
        }
    }

    @Test func libreTranslateTemplateSendsOneRequestPerLine() async throws {
        let kind: (MockServer) -> EngineKind = {
            .httpTemplate(HTTPTemplate(url: "http://127.0.0.1:\($0.port)/translate", headers: ["Content-Type": "application/json"],
                                       body: #"{"q": {{text}}, "source": "{{source}}", "target": "{{target}}", "api_key": "{{key}}"}"#,
                                       resultPath: "translatedText"))
        }
        let (server, client, engine) = try setup("ok", kind: kind)
        defer { server.stop() }
        #expect(try await run(client, engine) == ["⟦ko⟧ a", "⟦ko⟧ b"])
        #expect(server.count("POST /translate") == 2)
    }

    @Test func jsonArrayTemplateIsOneRequest() async throws {
        let kind: (MockServer) -> EngineKind = {
            .httpTemplate(HTTPTemplate(url: "http://127.0.0.1:\($0.port)/v2/translate", headers: ["Content-Type": "application/json"],
                                       body: #"{"text": {{lines}}, "target_lang": "{{target_upper}}"}"#,
                                       resultPath: "translations[*].text", batching: .jsonArray))
        }
        let (server, client, engine) = try setup("ok", kind: kind)
        defer { server.stop() }
        #expect(try await run(client, engine) == ["⟦KO⟧ a", "⟦KO⟧ b"])
        #expect(server.count("POST") == 1)
    }

    @Test func aTemplateWithAKeyHeaderNeedsTheKey() async throws {
        let engine = EngineConfig(name: "t", kind: .httpTemplate(HTTPTemplate(
            url: "http://127.0.0.1:9/translate", headers: ["Authorization": "Bearer {{key}}"], body: #"{"q": {{text}}}"#,
            resultPath: "translatedText")))
        let client = EngineClient(secrets: MemorySecrets())
        await #expect(throws: EngineError.missingKey) { try await client.translate(["a"], source: nil, target: "ko", glossary: [], engine: engine) }
    }

    // MARK: models, prewarm, probe

    @Test func modelsAreCachedUntilRefreshed() async throws {
        let (server, client, engine) = try setup("ok", kind: openAI)
        defer { server.stop() }
        #expect(try await client.models(engine) == ["mock-large", "mock-small"])
        #expect(try await client.models(engine).count == 2)
        #expect(server.count("GET /v1/models") == 1)
        _ = try await client.models(engine, refresh: true)
        #expect(server.count("GET /v1/models") == 2)
    }

    @Test func prewarmFillsTheModelCacheAndIgnoresErrors() async throws {
        let (server, client, engine) = try setup("ok", kind: openAI)
        defer { server.stop() }
        await client.prewarm(engine)
        _ = try await client.models(engine)
        #expect(server.count("GET /v1/models") == 1)
        await EngineClient(secrets: MemorySecrets()).prewarm(EngineConfig(name: "x", kind: .anthropic(baseURL: server.base, model: "", thinking: .off)))
        #expect(server.count("GET /v1/models") == 1)
    }

    @Test func probeReportsTheSampleAndTheTime() async throws {
        let (server, client, engine) = try setup("slow:150", kind: openAI)
        defer { server.stop() }
        let r = await client.probe(engine, target: "ko")
        #expect(r.sample == "⟦Korean⟧ Hello, world." && r.error == nil && r.ms >= 150)
        let bad = try MockServer(mode: "401")
        defer { bad.stop() }
        let e = EngineConfig(name: "b", kind: openAI(bad))
        let r2 = await EngineClient(secrets: MemorySecrets([e.id: key])).probe(e, target: "ko")
        guard case .unauthorized = r2.error else { return fail("probe error \(String(describing: r2.error))") }
        #expect(r2.sample == nil)
    }

    @Test func originOfATemplateURLKeepsOnlySchemeAndHost() {
        #expect(EngineClient.origin(of: "http://localhost:5000/translate?k={{key}}") == "http://localhost:5000")
        #expect(EngineClient.origin(of: "https://api.example.com") == "https://api.example.com")
        #expect(EngineClient.origin(of: "https://{{host}}/x") == nil)
    }

    // MARK: cancellation

    @Test func cancellingAHungRequestReturnsPromptly() async throws {
        let (server, client, engine) = try setup("hang", kind: openAI)
        defer { server.stop() }
        // 2026-10-19 (t3a1-context-settings): the bound was 300 ms from the cancel, and it flaked under load (load average 30 to 44
        // during the 1.1.2 release gates). Derivation: what this test blocks is a cancel that does not reach the HTTP task, so the
        // caller waits for the hung request. That request cannot answer (the mock sleeps an hour); the first moment it can return
        // on its own is the transport's silence limit (`timeoutIntervalForRequest`, 30 s), as a timeout error, not `.cancelled`.
        // So the bound is that instant, measured from before the request existed: a waiting version returns at or after it, a
        // correct one returns when the task is cancelled plus wake-up latency, ms of work against 30 s. It costs time only when
        // the code is broken. (The speed of a cancel is not what this guards.)
        let silenceLimit = Duration.seconds(EngineTransport.session.configuration.timeoutIntervalForRequest)
        let launched = ContinuousClock.now
        let task = Task { () -> EngineError? in
            do throws(EngineError) { _ = try await run(client, engine); return nil } catch { return error }
        }
        for _ in 0..<100 where server.count("POST") == 0 { try await Task.sleep(for: .milliseconds(30)) }
        #expect(server.count("POST") == 1)
        task.cancel()
        let result = await task.value
        let elapsed = ContinuousClock.now - launched
        #expect(result == EngineError.cancelled)
        #expect(elapsed < silenceLimit, "the cancel returned after \(elapsed); the hung request could time out on its own at \(silenceLimit)")
        #expect(await client.learnedRejections(for: engine.id).isEmpty)
        #expect(server.count("POST") == 1)  // no retry after cancel
    }

    // MARK: no key in any message

    @Test func scrubberRemovesTheKeyAndCutsTheMessage() {
        let k = "sk-abc/def+ghi"
        let s = Scrubber(key: k)
        #expect(s("bad key \(k)!") == "bad key ***!")
        #expect(s("in url ?k=\(k.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)") == "in url ?k=***")
        #expect(s(String(repeating: "x", count: 500)).count == 200)
        #expect(s("a \n  b\t c") == "a b c")
    }

    @Test func everyErrorHasAUserMessage() {
        let all: [EngineError] = [.missingKey, .unauthorized("x"), .rateLimited(retryAfter: nil), .rejected("x"), .server("x"),
                                  .countMismatch(expected: 2, got: 1), .malformed("x"), .network("x"), .commandFailed("x"), .cancelled]
        for e in all { #expect(!e.userMessage.isEmpty) }
    }
}
