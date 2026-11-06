import Foundation
import Testing
@testable import MwoyeoCore

/// App Review 2.4.5(iii), 2026-11-05: the reader services outlived the app. The decision of when a worker service exits, on a fake
/// clock. The real-process half is tools/app-store/outlive-check.sh.
@Suite struct ServiceLifetimeTests {
    /// A clock that runs its timers only when told, and an exit that is counted.
    final class World: @unchecked Sendable {
        var timers: [(TimeInterval, @Sendable () -> Void)] = []
        var exits = 0
        lazy var lifetime = ServiceLifetime(grace: 1, after: { [unowned self] delay, work in timers.append((delay, work)) },
                                            exit: { [unowned self] in exits += 1 })
        func fire() { let due = timers; timers = []; due.forEach { $0.1() } }
    }

    @Test func theServiceExitsOnceTheAppsLastConnectionIsGone() {
        let w = World()
        w.lifetime.opened()
        w.fire()
        #expect(w.exits == 0, "a service the app holds stays")
        w.lifetime.closed()
        #expect(w.timers.map(\.0) == [1], "it waits the grace, no longer")
        w.fire()
        #expect(w.exits == 1)
    }

    @Test func aConnectionThatReplacesTheOldOneWithinTheGraceKeepsTheService() {
        // The script host drops a connection that did not answer and makes the next one at once.
        let w = World()
        w.lifetime.opened()
        w.lifetime.closed()
        w.lifetime.opened()
        w.fire()
        #expect(w.exits == 0)
        #expect(w.lifetime.openConnections == 1)
    }

    @Test func aConnectionThatCameAndWentWithinTheGraceStartsTheWaitAgain() {
        let w = World()
        w.lifetime.opened()
        w.lifetime.closed()
        w.lifetime.opened()
        w.lifetime.closed()
        #expect(w.timers.count == 2)
        w.timers[0].1()
        #expect(w.exits == 0, "the first wait is stale")
        w.timers[1].1()
        #expect(w.exits == 1)
    }

    @Test func oneOfTwoConnectionsGoingKeepsTheService() {
        let w = World()
        w.lifetime.opened()
        w.lifetime.opened()
        w.lifetime.closed()
        #expect(w.timers.isEmpty)
        #expect(w.exits == 0)
    }

    @Test func theShippedGraceIsOneSecond() {
        // New pin, 2026-11-06: a reviewer quits the app and looks at Activity Monitor; a second is under that look.
        #expect(ServiceLifetime.standardGrace == 1)
    }
}
