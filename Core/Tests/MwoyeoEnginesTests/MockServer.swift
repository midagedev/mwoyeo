import Foundation
import Darwin
import Testing

/// `tools/mock-openai/server.py` on a free port, started and killed by the test (its pid is the one we captured).
final class MockServer: @unchecked Sendable {
    let port: Int
    private let process = Process()
    private let logURL: URL
    private let exited = DispatchSemaphore(value: 0)

    var base: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var v1: URL { URL(string: "http://127.0.0.1:\(port)/v1")! }

    init(mode: String) throws {
        port = try Self.freePort()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        logURL = FileManager.default.temporaryDirectory.appendingPathComponent("mock-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-I", root.appendingPathComponent("tools/mock-openai/server.py").path, "\(port)", mode]
        process.standardError = try FileHandle(forWritingTo: logURL)
        process.standardOutput = FileHandle.nullDevice
        process.terminationHandler = { [exited] _ in exited.signal() }
        try process.run()
        // Ready when the port accepts a connection.
        for _ in 0..<100 {
            if Self.accepts(port) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        stop()
        throw NSError(domain: "MockServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "mock did not start"])
    }

    func stop() {
        if process.isRunning { process.terminate() }
        // Not `waitUntilExit()`: on the test runner's threads it waited in a run loop that never heard of the exit, and the
        // whole `swift test` hung with the mock already gone (MockServerTests). The handler is told on a queue of its own.
        if exited.wait(timeout: .now() + 10) == .success { exited.signal() }
        try? FileManager.default.removeItem(at: logURL)
    }

    /// One log line per request the mock saw: `POST /v1/chat/completions lines=2 mode=ok auth=present thinking_off=no`.
    var requests: [String] {
        ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func count(_ prefix: String) -> Int { requests.filter { $0.hasPrefix(prefix) }.count }

    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0,
                               sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard ok == 0 else { throw NSError(domain: "MockServer", code: 2) }
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

func fail(_ message: String) { Issue.record(Comment(rawValue: message)) }
