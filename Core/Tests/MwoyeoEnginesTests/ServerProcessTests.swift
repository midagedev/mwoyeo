import Foundation
import Testing
import MwoyeoCore
@testable import MwoyeoEngines

/// Stopping test servers on the test runner's cooperative threads. `Process.waitUntilExit()` parks there in a run loop that
/// never hears of the exit: the whole `swift test` hung in `stop()` with the server already gone (2026-10-18 in MockServer,
/// 2026-10-19 in PlanServer). Both now stop through `ServerProcess`.
@Suite struct ServerProcessTests {
    @Test(.timeLimit(.minutes(1))) func manyMockServersStopAtOnce() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<48 {
                group.addTask {
                    // As the engine tests do: one request answered, then the stop.
                    let server = try MockServer(mode: "401")
                    defer { server.stop() }
                    var request = URLRequest(url: server.base.appendingPathComponent("v1/messages"))
                    request.httpMethod = "POST"
                    request.httpBody = Data(#"{"messages":[]}"#.utf8)
                    _ = try? await URLSession.shared.data(for: request)
                }
            }
            try await group.waitForAll()
        }
    }

    @Test(.timeLimit(.minutes(1))) func manyPlanServersStopAtOnce() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<48 {
                group.addTask {
                    let server = try PlanServer(plan: ["/v1/chat/completions": ["ok": ["choices": []]]])
                    defer { server.stop() }
                    var request = URLRequest(url: server.v1.appendingPathComponent("chat/completions"))
                    request.httpMethod = "POST"
                    request.httpBody = Data(#"{"messages":[]}"#.utf8)
                    _ = try? await URLSession.shared.data(for: request)
                }
            }
            try await group.waitForAll()
        }
    }
}
