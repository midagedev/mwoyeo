import Foundation
import MwoyeoCore
import os

/// Runs script jobs, exactly one at a time on a dedicated serial queue. A job that arrives while one runs waits its turn (the app does not send
/// one: `ScriptConnection` serialises its callers, so the time it takes is timed from when it starts).
final class ScriptWorker: NSObject, ScriptXPC {
    private let queue = DispatchQueue(label: "dev.midagedev.mwoyeo.script.worker", qos: .userInitiated)
    private let log = Logger(subsystem: "dev.midagedev.mwoyeo", category: "script")

    func run(_ job: Data, reply: @escaping (Data) -> Void) {
        queue.async { reply(self.answer(job)) }
    }

    func hello(reply: @escaping (Int32) -> Void) {
        queue.async {
            ScriptJS.warm()
            reply(getpid())
        }
    }

    func exitWhenIdle(reply: @escaping (Int32) -> Void) {
        // Behind everything already queued: the queue is the idleness.
        queue.async {
            reply(getpid())
            self.log.notice("exit when idle: pid=\(getpid())")
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { exit(0) }
        }
    }

    private func answer(_ data: Data) -> Data {
        let began = ProcessInfo.processInfo.systemUptime
        var reply: ScriptReply
        if let job = try? ScriptWire.decode(ScriptJob.self, from: data) {
            reply = ScriptJS.run(job)
        } else {
            reply = ScriptReply(id: 0, pid: getpid(), failure: RewriteFailure("undecodable job"))
        }
        reply.pid = getpid()
        reply.ms = (ProcessInfo.processInfo.systemUptime - began) * 1000
        return (try? ScriptWire.encode(reply)) ?? Data()
    }
}
