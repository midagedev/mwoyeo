import Foundation

/// How long a worker service (the readers, the script service) lives: as long as the app holds a connection to it. The services turn off
/// automatic and sudden termination, so that an idle worker stays the warm one the app believes it has; without this, nothing ends them
/// when the app is gone, and they outlive it (App Review 2.4.5(iii), 2026-11-05: "spawns processes that continue running after the user
/// has quit the app"). The app's quit, a force quit or a crash all reach the service the same way: its connection is invalidated.
///
/// The last connection gone, the service waits `grace` for a new one (the script host drops a connection that did not answer and makes
/// the next one at once) and then exits. A connection that came and went within the grace starts the wait again.
public final class ServiceLifetime: @unchecked Sendable {
    /// The shipped wait: long enough for a host that replaces its connection, short against a reviewer's look at Activity Monitor.
    public static let standardGrace: TimeInterval = 1

    private let grace: TimeInterval
    private let after: (TimeInterval, @escaping @Sendable () -> Void) -> Void
    private let exit: @Sendable () -> Void
    private let lock = NSLock()
    private var open = 0
    private var generation = 0

    /// `after` and `exit` are the clock and the end of the process; the tests pass their own.
    public init(grace: TimeInterval = ServiceLifetime.standardGrace,
                after: @escaping (TimeInterval, @escaping @Sendable () -> Void) -> Void = { delay, work in
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
                },
                exit: @escaping @Sendable () -> Void = { Darwin.exit(0) }) {
        self.grace = grace
        self.after = after
        self.exit = exit
    }

    /// A connection the listener accepted: the service lives while it is open. Call before `resume()`.
    public func hold(_ connection: NSXPCConnection) {
        opened()
        connection.invalidationHandler = { [weak self] in self?.closed() }
    }

    /// The number of connections open now.
    public var openConnections: Int { lock.withLock { open } }

    func opened() {
        lock.withLock {
            open += 1
            generation += 1
        }
    }

    func closed() {
        let mine: Int? = lock.withLock {
            open = max(0, open - 1)
            generation += 1
            return open == 0 ? generation : nil
        }
        guard let mine else { return }
        after(grace) { [self] in
            let gone = lock.withLock { open == 0 && generation == mine }
            if gone { exit() }
        }
    }
}
