import Foundation
import Testing
import MwoyeoCore
@testable import MwoyeoEngines

@Suite struct CommandRunnerTests {
    private var echoEngine: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("tools/engine-examples/echo-engine.py").path
    }

    private func engine(_ exe: String, _ args: [String]) -> EngineConfig {
        EngineConfig(name: "cmd", kind: .command(CommandSpec(executable: exe, arguments: args)))
    }

    private let client = EngineClient(secrets: MemorySecrets())

    @Test func echoEngineAnswers() async throws {
        let out = try await client.translate(["a", "b"], source: "ja", target: "ko", glossary: [],
                                             engine: engine("python3", [echoEngine]))
        #expect(out == ["[ko] a", "[ko] b"])
    }

    @Test func aFailingCommandReportsItsStderr() async throws {
        let e = engine("/bin/sh", ["-c", "echo boom >&2; exit 3"])
        await #expect(throws: EngineError.commandFailed("boom")) {
            try await client.translate(["a"], source: nil, target: "ko", glossary: [], engine: e)
        }
    }

    @Test func aMissingCommandIsNamed() async {
        let e = engine("no-such-engine-\(UUID().uuidString.prefix(8))", [])
        do throws(EngineError) { _ = try await client.translate(["a"], source: nil, target: "ko", glossary: [], engine: e); Issue.record("expected failure") }
        catch { guard case let .commandFailed(m) = error else { return fail("\(error)") }; #expect(m.hasPrefix("command not found")) }
    }

    @Test func anErrorLineIsShownAsIs() async throws {
        let e = engine("/bin/sh", ["-c", #"cat >/dev/null; echo '{"error": "no GPU"}'"#])
        await #expect(throws: EngineError.server("no GPU")) {
            try await client.translate(["a"], source: nil, target: "ko", glossary: [], engine: e)
        }
    }

    @Test func theChildSeesOnlyPathHomeAndLang() async throws {
        setenv("MWOYEO_TEST_SECRET", "leak", 1)
        let e = engine("/bin/sh", ["-c", #"cat >/dev/null; printf '{"translations": ["%s"]}\n' "$(env | cut -d= -f1 | sort | tr '\n' ' ')""#])
        let out = try await client.translate(["a"], source: nil, target: "ko", glossary: [], engine: e)
        #expect(!out[0].contains("MWOYEO_TEST_SECRET"))
        #expect(out[0].contains("PATH") && out[0].contains("HOME") && out[0].contains("LANG"))
    }

    @Test func outputOverOneMegabyteFails() async throws {
        let e = engine("/bin/sh", ["-c", "cat >/dev/null; head -c 3000000 /dev/zero | tr '\\0' x"])
        await #expect(throws: EngineError.commandFailed("output is larger than 1 MB")) {
            try await client.translate(["a"], source: nil, target: "ko", glossary: [], engine: e)
        }
    }

    @Test func cancelKillsTheChild() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("cmd-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let e = engine("/bin/sh", ["-c", "echo $$ > '\(pidFile.path)'; exec sleep 30"])
        let task = Task { () -> EngineError? in
            do throws(EngineError) { _ = try await client.translate(["a"], source: nil, target: "ko", glossary: [], engine: e); return nil } catch { return error }
        }
        var pid: pid_t = 0
        for _ in 0..<100 {
            if let s = try? String(contentsOf: pidFile, encoding: .utf8), let p = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)) { pid = p; break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(pid > 0)
        task.cancel()
        #expect(await task.value == EngineError.cancelled)
        var gone = false
        for _ in 0..<30 where !gone {
            gone = kill(pid, 0) != 0 && errno == ESRCH
            if !gone { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(gone)
    }
}
