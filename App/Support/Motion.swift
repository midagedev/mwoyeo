import AppKit
import Observation
import SwiftUI

/// Reduce Motion, in one place: System Settings › Accessibility › Display, and Low Power Mode (untrans117, 2026-10-23: the lens's organic outline
/// and the rest of the decoration cost a battery that asked to be spared). Every animation of the app that repeats or only decorates
/// asks `Motion.shared.reduced` and holds still (or fades) when it is on; nothing else reads the system setting or the power state.
/// SwiftUI views that read `reduced` in their body are redrawn when it changes; AppKit and layer code listens for `changed`.
@MainActor
@Observable
final class Motion {
    static let shared = Motion()
    /// Posted on the default center when `reduced` flips (the system setting changed, or a check forced it).
    static let changed = Notification.Name("dev.midagedev.mwoyeo.motion.changed")

    private var system: Bool
    private var lowPower: Bool
    private var override: Bool?
    /// Where the two states are read from: the system's (a check cannot switch it, and `forceLowPower` puts its own in place).
    @ObservationIgnored private var read: () -> (reduceMotion: Bool, lowPower: Bool) = Motion.readSystem

    private static func readSystem() -> (reduceMotion: Bool, lowPower: Bool) {
        (NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    /// Whether to hold still: the system setting or Low Power Mode, or what a check forced.
    var reduced: Bool { override ?? (system || lowPower) }

    private init() {
        (system, lowPower) = Self.readSystem()
        #if !MAS
        if DebugSwitch.isOn("MWOYEO_REDUCE_MOTION", in: ProcessInfo.processInfo.environment) { override = true }
        #endif
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                          object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Motion.shared.refresh() }
        }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Motion.shared.refresh() }
        }
    }

    /// The system setting and the power state were read again.
    private func refresh() {
        let was = reduced
        (system, lowPower) = read()
        if reduced != was { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    /// For the checks: Reduce Motion on or off whatever the system says; nil goes back to the system.
    func force(_ value: Bool?) {
        let was = reduced
        override = value
        if reduced != was { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    /// For the checks: Low Power Mode on or off, with the system's Reduce Motion out of the way, announced as the system announces it (the
    /// listener reads it on the main queue a moment later); nil goes back to the system. `force` still outranks it.
    func forceLowPower(_ value: Bool?) {
        read = value.map { on in { (false, on) } } ?? Motion.readSystem
        NotificationCenter.default.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
    }

    /// `animation`, or none while Reduce Motion is on.
    func animation(_ animation: Animation) -> Animation? { reduced ? nil : animation }
}
