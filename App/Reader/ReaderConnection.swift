import CoreGraphics
import CoreVideo
import Foundation
import IOSurface
import MwoyeoCore
import os

/// The app's side of one reader service (`Reader/`): an `NSXPCConnection` per role, the picture packed into an IOSurface, the
/// reply decoded, and the service's coming and going told as events. It never times out and never cancels a read: a job that
/// the service has not answered stays pending until it does or the service dies (design invariant I3). Retry, routing and
/// health are the host's (R3).
///
/// The service is found by name, `<app bundle id>.reader.<role>`, in this app's `Contents/XPCServices`; a re-identified copy of
/// the app talks to its own re-identified services.
final class ReaderConnection: @unchecked Sendable {
    let role: ReaderRole
    let serviceName: String

    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var pid: Int32?
    private var nextID: UInt64 = 0
    private var listeners: [UUID: AsyncStream<ReaderConnectionEvent>.Continuation] = [:]
    private let fakes: ReaderFakePlan
    private let log = Logger(subsystem: "dev.midagedev.mwoyeo", category: "reader")

    private static let shared = OSAllocatedUnfairLock(initialState: [ReaderRole: ReaderConnection]())

    /// The process's connection to the service of `role`.
    static func shared(_ role: ReaderRole) -> ReaderConnection {
        shared.withLock { connections in
            if let existing = connections[role] { return existing }
            let made = ReaderConnection(role: role)
            connections[role] = made
            return made
        }
    }

    /// `fakes` is `ReaderFakePlan.environment` by default; a gate passes its own.
    init(role: ReaderRole, appID: String = Bundle.main.bundleIdentifier ?? "dev.midagedev.mwoyeo", fakes: ReaderFakePlan = .environment) {
        self.role = role
        self.serviceName = role.serviceName(appID: appID)
        self.fakes = fakes
        #if !MAS
        for typo in fakes.unrecognized { FileHandle.standardError.write("reader: MWOYEO_FAKE_READER mode not understood: \(typo)\n".data(using: .utf8)!) }
        #endif
    }

    /// The pid of the service that answered last, nil before the first answer and after an interruption.
    var servicePid: Int32? { lock.withLock { pid } }

    /// Interruption, invalidation and (re)connection as they happen. Each call is its own stream.
    func events() -> AsyncStream<ReaderConnectionEvent> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { listeners[id] = continuation }
            continuation.onTermination = { [weak self] _ in self?.lock.withLock { _ = self?.listeners.removeValue(forKey: id) } }
        }
    }

    // MARK: Reading

    /// One read, as `VisionExec.run` would do it in this process. A warm-up kind carries no picture. Throws `ReadFailure`
    /// (so that `OCRHealth.programsNotReady` still classifies it).
    func read(_ kind: ReadKind, image: CGImage?, roi: CGRect?, languages: [String] = [], documentLanguages: [Locale.Language] = [],
              customWords: [String] = []) async throws -> VisionExec.Output {
        var job = ReadJob(kind: kind, roi: roi, languages: languages, documentLanguages: documentLanguages, customWords: customWords)
        var packed: IOSurface?
        if kind.needsPicture {
            guard let image, let p = ReaderPixels.surface(from: image) else { throw ReadFailure.badJob("the picture could not be packed") }
            job.image = p.image
            packed = p.surface
        }
        return try Self.output(of: await perform(job, surface: packed), kind: kind)
    }

    /// One read of a frame as ScreenCaptureKit hands it out: the pixel buffer's own IOSurface goes over, no copy. The buffer is
    /// held until the service answers.
    func read(_ kind: ReadKind, pixelBuffer: CVPixelBuffer, roi: CGRect?, languages: [String] = [], documentLanguages: [Locale.Language] = [],
              customWords: [String] = []) async throws -> VisionExec.Output {
        guard let p = ReaderPixels.surface(of: pixelBuffer) else { throw ReadFailure.badJob("the pixel buffer has no IOSurface in a known format") }
        let job = ReadJob(kind: kind, image: p.image, roi: roi, languages: languages, documentLanguages: documentLanguages, customWords: customWords)
        let reply = await perform(job, surface: p.surface)
        withExtendedLifetime(pixelBuffer) {}
        return try Self.output(of: reply, kind: kind)
    }

    private static func output(of reply: ReadReply, kind: ReadKind) throws -> VisionExec.Output {
        if let error = reply.error { throw error }
        switch kind {
        case .doc, .warmDoc: return .paragraphs(reply.paragraphs.map { $0.map(VisionExec.unwire) })
        default: return .lines(reply.lines.map(VisionExec.unwire))
        }
    }

    /// The job as it goes over the wire, and the reply as it comes back: errors included, as `reply.error`. Never throws, never
    /// times out. `job.id` and `job.fake` are set here.
    func perform(_ job: ReadJob, surface: IOSurface? = nil, bytes: Data? = nil) async -> ReadReply {
        var job = job
        job.id = lock.withLock { nextID += 1; return nextID }
        job.fake += fakes.actions(role: role, kind: job.kind)
        let encoded: Data
        do { encoded = try ReaderWire.encode(job) } catch { return failure(job.id, .badJob("\(error)")) }
        let id = job.id
        let reply: ReadReply = await withCheckedContinuation { (continuation: CheckedContinuation<ReadReply, Never>) in
            let once = Once(continuation)
            let proxy = connect().remoteObjectProxyWithErrorHandler { [self] error in
                once.resume(failure(id, Self.failure(of: error)))
            } as? ReaderXPC
            guard let proxy else { once.resume(failure(id, .unavailable("no remote object"))); return }
            proxy.read(encoded, surface: surface, bytes: bytes) { [self] data in
                withExtendedLifetime(surface) {
                    if let reply = try? ReaderWire.decode(ReadReply.self, from: data) { once.resume(reply) } else { once.resume(failure(id, .failed("undecodable reply"))) }
                }
            }
        }
        if reply.pid != 0 { note(pid: reply.pid) }
        return reply
    }

    /// The service says who it is; no job needed. Nil if none answers.
    func hello() async -> ReaderHello? {
        let data: Data? = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            let once = Once(continuation)
            let proxy = connect().remoteObjectProxyWithErrorHandler { _ in once.resume(nil) } as? ReaderXPC
            guard let proxy else { once.resume(nil); return }
            proxy.hello { once.resume($0) }
        }
        guard let data, let hello = try? ReaderWire.decode(ReaderHello.self, from: data) else { return nil }
        note(pid: hello.pid)
        return hello
    }

    /// Asks the service to exit once the jobs queued before this are done. Returns its pid, or nil if it did not answer.
    func exitWhenIdle() async -> Int32? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int32?, Never>) in
            let once = Once(continuation)
            let proxy = connect().remoteObjectProxyWithErrorHandler { _ in once.resume(nil) } as? ReaderXPC
            guard let proxy else { once.resume(nil); return }
            proxy.exitWhenIdle { once.resume($0) }
        }
    }

    /// The last resort of a recycle that cannot wait: SIGKILL to the service pid recorded when it last answered. Only that pid.
    func killService() {
        guard let pid = servicePid else { return }
        log.notice("kill \(self.role.rawValue, privacy: .public) pid=\(pid)")
        kill(pid, SIGKILL)
    }

    // MARK: The connection

    private func connect() -> NSXPCConnection {
        lock.withLock {
            if let connection { return connection }
            let made = NSXPCConnection(serviceName: serviceName)
            made.remoteObjectInterface = ReaderWire.interface()
            made.interruptionHandler = { [weak self, weak made] in self?.interrupted(made) }
            made.invalidationHandler = { [weak self, weak made] in self?.invalidated(made) }
            made.resume()
            connection = made
            return made
        }
    }

    private func interrupted(_ made: NSXPCConnection?) {
        let lost = lock.withLock { defer { pid = nil }; return pid }
        log.notice("\(self.role.rawValue, privacy: .public) interrupted pid=\(lost ?? 0)")
        emit(.interrupted(role, pid: lost))
    }

    private func invalidated(_ made: NSXPCConnection?) {
        lock.withLock {
            if connection === made { connection = nil }
            pid = nil
        }
        log.notice("\(self.role.rawValue, privacy: .public) connection invalidated")
        emit(.invalidated(role))
    }

    private func note(pid seen: Int32) {
        let changed = lock.withLock { () -> Bool in defer { pid = seen }; return pid != seen }
        guard changed else { return }
        log.notice("\(self.role.rawValue, privacy: .public) connected pid=\(seen)")
        if Trace.enabled {
            // The process-shape gate reads this line: the service is another process than the app.
            print("reader: \(role.rawValue) pid=\(seen) gui pid=\(getpid())")
            fflush(stdout)
        }
        emit(.connected(role, pid: seen))
    }

    private func emit(_ event: ReaderConnectionEvent) {
        let all = lock.withLock { Array(listeners.values) }
        for continuation in all { continuation.yield(event) }
    }

    private func failure(_ id: UInt64, _ error: ReadFailure) -> ReadReply { ReadReply(id: id, role: role, pid: 0, error: error) }

    private static func failure(of error: Error) -> ReadFailure {
        let e = error as NSError
        guard e.domain == NSCocoaErrorDomain else { return .unavailable("\(e.domain) \(e.code): \(e.localizedDescription)") }
        switch e.code {
        case NSXPCConnectionInterrupted: return .interrupted
        default: return .unavailable("\(e.code): \(e.localizedDescription)")
        }
    }

    /// Resumes its continuation the first time, whichever of the reply and the error handler comes.
    private final class Once<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Never>?

        init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }

        func resume(_ value: T) {
            let c = lock.withLock { () -> CheckedContinuation<T, Never>? in defer { continuation = nil }; return continuation }
            c?.resume(returning: value)
        }
    }
}

extension ReaderFakePlan {
    /// `MWOYEO_FAKE_READER`: the fakes of the reader gates and the benches. The App Store build fakes nothing, and Core only parses a
    /// spec, so the variable is read here, under the condition that keeps it out of that build.
    #if MAS
    static let environment = ReaderFakePlan(nil)
    #else
    static let environment = ReaderFakePlan(ProcessInfo.processInfo.environment["MWOYEO_FAKE_READER"])
    #endif
}
