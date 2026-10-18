import Foundation
import Testing

/// `MockServer.stop()` on the test runner's cooperative threads. `Process.waitUntilExit()` parks there in a run loop that
/// never hears of the exit: the whole `swift test` hung in `stop()` with its mock already gone (2026-10-18, twice).
@Suite struct MockServerTests {
    @Test(.timeLimit(.minutes(1))) func manyServersStopAtOnce() async throws {
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
}
