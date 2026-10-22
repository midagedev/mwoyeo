#if !MAS
import Foundation

/// The restart of the script service, held by a check (`ScriptConnection.startGate`; round flake117, 2026-10-22).
///
/// A check of "a lens call is not queued behind a call that is waiting out the restart" needs that call to be in front of the restart while the lens call is made. launchd's own
/// hold (~10 s after the service's start) is a window the check could only poll for, and under load 100-350 it missed it (21 of 69 logs), or launchd's hold was shorter than the
/// check assumed because the first service was slow to start. With the gate closed, a call that has to wait for a new service stops here before its hello, `isStarting` true, until
/// the check opens the gate: the state is set by the check and read by it, and no time is waited for. `passes` counts the starts that reached the gate and `allowed` is what each
/// was told it may wait on top of its start budget, which is what the hello budget's throttle part is asserted by.
final class RestartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var told: [TimeInterval] = []
    private var watchers: [(count: Int, once: OnceResume<Bool>)] = []

    /// From now on a start waits at the gate (the ones already past it are not called back).
    func close() { lock.withLock { closed = true } }

    /// Lets every start that waits go on to its hello, and the ones after it.
    func open() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in closed = false; defer { parked = [] }; return parked }
        for c in all { c.resume() }
    }

    /// The starts that reached the gate, open or closed.
    var passes: Int { lock.withLock { told.count } }

    /// What each of them was told it may wait for launchd's throttle on top of its start budget, in the order they came.
    var allowed: [TimeInterval] { lock.withLock { told } }

    /// What `ScriptConnection.startGate` calls.
    func pass(_ left: TimeInterval) async {
        let wake = lock.withLock { () -> [OnceResume<Bool>] in
            told.append(left)
            let ready = watchers.filter { $0.count <= told.count }
            watchers.removeAll { $0.count <= told.count }
            return ready.map(\.once)
        }
        for once in wake { once.resume(true) }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let wait = lock.withLock { () -> Bool in if closed { parked.append(continuation) }; return closed }
            if !wait { continuation.resume() }
        }
    }

    /// True once `count` starts have reached the gate, false when they have not after `patience` seconds (a hang guard: a run that passes never waits for it).
    func arrived(_ count: Int, patience: Double = 30) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = OnceResume(continuation)
            let there = lock.withLock { () -> Bool in
                if told.count >= count { return true }
                watchers.append((count, once))
                return false
            }
            if there { once.resume(true); return }
            Task { try? await Task.sleep(nanoseconds: UInt64(patience * 1e9)); once.resume(false) }
        }
    }
}

/// `op`'s result, or nil when it has not finished after `patience` seconds. A hang guard for a call that a closed `RestartGate` would keep for ever if the product let it
/// wait for the restart: that call is then a FAIL of its check, not a run that never ends. A run that passes never waits for it.
func within<T: Sendable>(_ patience: Double = 30, _ op: @escaping @Sendable () async -> T) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let once = OnceResume(continuation)
        Task { once.resume(await op()) }
        Task { try? await Task.sleep(nanoseconds: UInt64(patience * 1e9)); once.resume(nil) }
    }
}

/// A boolean one task sets and another reads.
final class RunFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var value: Bool { get { lock.withLock { on } } set { lock.withLock { on = newValue } } }
}

/// Resumes its continuation the first time, whichever of the results comes.
final class OnceResume<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }

    func resume(_ value: T) {
        let c = lock.withLock { () -> CheckedContinuation<T, Never>? in defer { continuation = nil }; return continuation }
        c?.resume(returning: value)
    }
}
#endif
