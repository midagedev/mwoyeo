import CoreGraphics
import Foundation
import IOSurface
import MwoyeoCore
import os

/// Runs reader jobs for one role. Exactly one job at a time, to completion, on a dedicated serial queue: never the cooperative
/// pool, so a Vision call that blocks for a minute (a compile) holds nothing but this queue's thread. Never cancels. A job that
/// arrives while one runs waits its turn (the host does not send one: invariant I2).
final class ReaderWorker: NSObject, ReaderXPC {
    let role: ReaderRole
    private let queue = DispatchQueue(label: "dev.midagedev.mwoyeo.reader.worker", qos: .userInitiated)
    private let log = Logger(subsystem: "dev.midagedev.mwoyeo", category: "reader")
    /// A read slower than this is logged with its kind (design §4.15; the lens patience S).
    private static let slowMs = 8000.0

    init(role: ReaderRole) { self.role = role }

    func read(_ job: Data, surface: IOSurface?, bytes: Data?, reply: @escaping (Data) -> Void) {
        queue.async { reply(self.answer(job, surface: surface, bytes: bytes)) }
    }

    /// Answers at once, not behind a running job: who is there is known while a compile is in progress.
    func hello(reply: @escaping (Data) -> Void) {
        let hello = ReaderHello(role: role, pid: getpid(), footprint: ReaderWire.physFootprint())
        reply((try? ReaderWire.encode(hello)) ?? Data())
    }

    func exitWhenIdle(reply: @escaping (Int32) -> Void) {
        // Behind everything already queued: the queue is the idleness.
        queue.async {
            reply(getpid())
            self.log.notice("exit when idle: pid=\(getpid())")
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { exit(0) }
        }
    }

    // MARK: A job

    private func answer(_ data: Data, surface: IOSurface?, bytes: Data?) -> Data {
        let began = ProcessInfo.processInfo.systemUptime
        func reply(_ id: UInt64, lines: [ReadLine] = [], paragraphs: [[ReadLine]] = [], error: ReadFailure? = nil) -> Data {
            let ms = (ProcessInfo.processInfo.systemUptime - began) * 1000
            let r = ReadReply(id: id, role: role, pid: getpid(), lines: lines, paragraphs: paragraphs, ms: ms,
                              footprint: ReaderWire.physFootprint(), error: error)
            return (try? ReaderWire.encode(r)) ?? Data()
        }
        guard let job = try? ReaderWire.decode(ReadJob.self, from: data) else {
            return reply(0, error: .badJob("undecodable job"))
        }
        // A service obeys what the job says; it keeps no fake state of its own (`ReaderFakeAction`).
        if job.fake.contains(.crash) { exit(1) }
        guard role.serves(job.kind) else { return reply(job.id, error: .badJob("\(role.rawValue) does not run \(job.kind.rawValue)")) }
        for case let .slow(ms) in job.fake { Thread.sleep(forTimeInterval: Double(ms) / 1000) }
        if let failure = job.fake.lazy.compactMap(\.failure).first { return reply(job.id, error: failure) }

        var image: CGImage?
        if job.kind.needsPicture {
            guard let described = job.image else { return reply(job.id, error: .badJob("no picture described")) }
            if let surface { image = ReaderPixels.cgImage(surface: surface, as: described) } else if let bytes { image = ReaderPixels.cgImage(bytes: bytes, as: described) }
            guard image != nil else { return reply(job.id, error: .badJob("the picture does not match its description")) }
        }

        let output: VisionExec.Output
        let picture = image
        do {
            output = try Self.blocking {
                try await VisionExec.run(job.kind, image: picture, roi: job.roi, languages: job.languages,
                                         documentLanguages: job.documentLanguages, customWords: job.customWords)
            }
        } catch {
            let failure = ReadFailure.from(error)
            log.error("kind=\(job.kind.rawValue, privacy: .public) failed: \(String(describing: failure), privacy: .public)")
            return reply(job.id, error: failure)
        }
        let shift: CGFloat = job.fake.contains(.shift1) ? 1 : 0
        func wired(_ line: OCRLine) -> ReadLine { shift == 0 ? VisionExec.wire(line) : VisionExec.wire(line).shifted(by: shift) }
        let out: Data
        switch output {
        case let .lines(lines): out = reply(job.id, lines: lines.map(wired))
        case let .paragraphs(paragraphs): out = reply(job.id, paragraphs: paragraphs.map { $0.map(wired) })
        }
        let ms = (ProcessInfo.processInfo.systemUptime - began) * 1000
        if ms > Self.slowMs { log.notice("kind=\(job.kind.rawValue, privacy: .public) ms=\(Int(ms)) (slow)") }
        return out
    }

    /// Runs async work to its end on this (the worker's) thread: the Swift document request is async, the job is not.
    private static func blocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            do { box.result = .success(try await work()) } catch { box.result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try box.result!.get()
    }
}

/// Where `ReaderWorker.blocking` leaves the result of its task for the thread that waits on it.
private final class Box<T: Sendable>: @unchecked Sendable {
    var result: Result<T, Error>?
}
