import Foundation
import Darwin

/// A local test server process on a free port: started, waited for, and stopped by the test (its pid is the one captured).
/// The one owner of launching and stopping for `MockServer` and `PlanServer`.
///
/// Stopping never calls `Process.waitUntilExit()`: on the test runner's cooperative threads it parks in a run loop that never
/// hears of the exit, and the whole `swift test` hung in `stop()` with the server already gone (2026-10-18 in `MockServer`,
/// 2026-10-19 in `PlanServer`; `ServerProcessTests`). The termination handler is told on a queue of its own.
final class ServerProcess: @unchecked Sendable {
    let port: Int
    private let process = Process()
    private let exited = DispatchSemaphore(value: 0)

    /// Runs `python3 -I <arguments…>`, where `arguments` gets the port; returns once the port accepts a connection.
    init(stderr: FileHandle = .nullDevice, arguments: (Int) -> [String]) throws {
        port = try Self.freePort()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-I"] + arguments(port)
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        process.terminationHandler = { [exited] _ in exited.signal() }
        try process.run()
        for _ in 0..<100 {
            if Self.accepts(port) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        stop()
        throw NSError(domain: "ServerProcess", code: 1, userInfo: [NSLocalizedDescriptionKey: "server did not start"])
    }

    func stop() {
        if process.isRunning { process.terminate() }
        if exited.wait(timeout: .now() + 10) == .success { exited.signal() }
    }

    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0,
                               sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard ok == 0 else { throw NSError(domain: "ServerProcess", code: 2) }
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
