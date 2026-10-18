import Foundation
import Darwin
import Testing

/// `tools/mock-openai/server.py` on a free port, started and killed by the test (its pid is the one we captured).
final class MockServer: @unchecked Sendable {
    private let server: ServerProcess
    private let logURL: URL

    var port: Int { server.port }
    var base: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var v1: URL { URL(string: "http://127.0.0.1:\(port)/v1")! }

    init(mode: String) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        logURL = FileManager.default.temporaryDirectory.appendingPathComponent("mock-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        server = try ServerProcess(stderr: try FileHandle(forWritingTo: logURL)) { port in
            [root.appendingPathComponent("tools/mock-openai/server.py").path, "\(port)", mode]
        }
    }

    func stop() {
        server.stop()
        try? FileManager.default.removeItem(at: logURL)
    }

    /// One log line per request the mock saw: `POST /v1/chat/completions lines=2 mode=ok auth=present thinking_off=no`.
    var requests: [String] {
        ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func count(_ prefix: String) -> Int { requests.filter { $0.hasPrefix(prefix) }.count }
}

func fail(_ message: String) { Issue.record(Comment(rawValue: message)) }
