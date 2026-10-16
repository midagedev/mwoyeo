import Foundation
import Synchronization

public enum DeadlineResult<T: Sendable>: Sendable {
    case value(T)
    case failed(any Error)
    case timedOut
}

/// Runs `op` and returns its result, its error, or `.timedOut` once `d` has passed, whichever comes first.
///
/// The race is an unstructured work task plus a timer task, and a continuation that whichever finishes first resumes
/// exactly once. A task group would not do: it waits for every child, so an operation that ignores cancellation
/// would hold the caller past the deadline. On a timeout the work task is cancelled; if it ignores that, it is
/// leaked by design (it runs on, its result is dropped). A cancelled caller cancels both tasks and gets `.failed`.
public func withDeadline<T: Sendable>(_ d: Duration, _ op: @escaping @Sendable () async throws -> T) async -> DeadlineResult<T> {
    let race = DeadlineRace<T>()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<DeadlineResult<T>, Never>) in
            race.install(continuation)
            let work = Task {
                do { race.finish(.value(try await op())) } catch { race.finish(.failed(error)) }
            }
            let timer = Task {
                do { try await Task.sleep(for: d) } catch { return }
                race.finish(.timedOut)
            }
            race.track(work: work, timer: timer)
        }
    } onCancel: {
        race.finish(.failed(CancellationError()))
    }
}

private final class DeadlineRace<T: Sendable>: Sendable {
    private struct State {
        var result: DeadlineResult<T>?
        var continuation: CheckedContinuation<DeadlineResult<T>, Never>?
        var work: Task<Void, Never>?
        var timer: Task<Void, Never>?
    }
    private let state = Mutex(State())

    func install(_ c: CheckedContinuation<DeadlineResult<T>, Never>) {
        // The caller may have been cancelled before the continuation existed.
        let early = state.withLock { s -> DeadlineResult<T>? in
            if let r = s.result { return r }
            s.continuation = c
            return nil
        }
        if let early { c.resume(returning: early) }
    }

    func track(work: Task<Void, Never>, timer: Task<Void, Never>) {
        let done = state.withLock { s -> Bool in
            if s.result != nil { return true }
            s.work = work
            s.timer = timer
            return false
        }
        if done { work.cancel(); timer.cancel() }
    }

    /// The first call wins; later ones are ignored.
    func finish(_ r: DeadlineResult<T>) {
        let (c, work, timer) = state.withLock { s -> (CheckedContinuation<DeadlineResult<T>, Never>?, Task<Void, Never>?, Task<Void, Never>?) in
            guard s.result == nil else { return (nil, nil, nil) }
            s.result = r
            defer { s.continuation = nil; s.work = nil; s.timer = nil }
            return (s.continuation, s.work, s.timer)
        }
        // No sleeping timer is left behind when the work wins, and a timed-out or cancelled work is asked to stop.
        timer?.cancel()
        work?.cancel()
        c?.resume(returning: r)
    }
}
