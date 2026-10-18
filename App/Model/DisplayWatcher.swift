import AppKit
import MwoyeoCore

/// The one place that hears the Mac wake or its displays change. What a lens does about it is `CaptureRecovery`'s rule, carried out
/// by the lens (`RegionSession.displaysChanged`).
@MainActor
final class DisplayWatcher {
    /// The app's lifetime: the watcher is never torn down.
    private var observers: [NSObjectProtocol] = []

    init(onEvent: @escaping @MainActor (CaptureEvent) -> Void) {
        func watch(_ center: NotificationCenter, _ name: Notification.Name, _ event: CaptureEvent) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { onEvent(event) } }
            observers.append(token)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        // The Mac slept, or only its displays did (a lid, an external display's power saving): both end a stream.
        watch(workspace, NSWorkspace.didWakeNotification, .wake)
        watch(workspace, NSWorkspace.screensDidWakeNotification, .wake)
        watch(.default, NSApplication.didChangeScreenParametersNotification, .screensChanged)
    }
}

extension DisplayLayout {
    /// The displays now.
    @MainActor static var current: DisplayLayout {
        let screens = NSScreen.screens
        return DisplayLayout(frames: screens.map { ScreenGeometry.quartzRect(fromAppKit: $0.frame) },
                             primary: screens.first.map { ScreenGeometry.quartzRect(fromAppKit: $0.visibleFrame) } ?? .null)
    }
}
