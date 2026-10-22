import AppKit
import Observation
import SwiftUI

/// Reduce Motion, in one place: System Settings › Accessibility › Display. Every animation of the app that repeats or only decorates
/// asks `Motion.shared.reduced` and holds still (or fades) when it is on; nothing else reads the system setting.
/// SwiftUI views that read `reduced` in their body are redrawn when it changes; AppKit and layer code listens for `changed`.
@MainActor
@Observable
final class Motion {
    static let shared = Motion()
    /// Posted on the default center when `reduced` flips (the system setting changed, or a check forced it).
    static let changed = Notification.Name("dev.midagedev.mwoyeo.motion.changed")

    private var system = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var override: Bool?

    /// Whether to hold still: the system setting, or what a check forced.
    var reduced: Bool { override ?? system }

    private init() {
        #if !MAS
        if DebugSwitch.isOn("MWOYEO_REDUCE_MOTION", in: ProcessInfo.processInfo.environment) { override = true }
        #endif
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                          object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Motion.shared.refresh() }
        }
    }

    /// The system setting was read again.
    private func refresh() {
        let was = reduced
        system = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduced != was { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    /// For the checks: Reduce Motion on or off whatever the system says; nil goes back to the system.
    func force(_ value: Bool?) {
        let was = reduced
        override = value
        if reduced != was { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    /// `animation`, or none while Reduce Motion is on.
    func animation(_ animation: Animation) -> Animation? { reduced ? nil : animation }
}
