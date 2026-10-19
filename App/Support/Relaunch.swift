import AppKit
import os

/// Starting Mwoyeo again. A grant of Screen Recording takes effect only in a process started after it, so a lens whose capture
/// the system refuses despite the grant says "Restart Mwoyeo to finish" and does this: the new process opens the saved lenses at
/// its start, as any launch does.
enum Relaunch {
    /// The first argument of the new process; the next is the pid of the one it replaces.
    private static let flag = "--relaunched"
    /// What the new process takes over: the files a scripted run or a capture points at. The App Store build reads none of them.
    #if MAS
    private static let carried: [String] = []
    #else
    private static let carried = ["MWOYEO_SETTINGS_FILE", "MWOYEO_DEFAULTS_SUITE", "MWOYEO_MEMORY_SECRETS", "MWOYEO_TRACE"]
    #endif
    private static let log = Logger(subsystem: "dev.midagedev.mwoyeo", category: "app")

    /// Opens a new instance of this app, then quits this one once the system has started it.
    @MainActor static func run() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.arguments = [flag, String(getpid())]
        // LaunchServices hands the new process this one's environment with these laid over it, so a preview is turned off by name
        // (a preview that relaunches would relaunch itself for ever).
        var environment = ProcessInfo.processInfo.environment.filter { carried.contains($0.key) }
        #if !MAS
        environment["MWOYEO_PREVIEW"] = ""
        #endif
        config.environment = environment
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { app, error in
            if let error {
                log.error("relaunch failed: \(error.localizedDescription)")
                return
            }
            log.notice("relaunched as pid \(app?.processIdentifier ?? 0)")
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// In a relaunched process: waits, at most five seconds, until the process it replaces has gone, so that the shortcuts and
    /// the lenses of the two never overlap. Returns at once in any other process.
    static func waitForPredecessor() async {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count, let pid = pid_t(args[i + 1]) else { return }
        let deadline = Date().addingTimeInterval(5)
        while kill(pid, 0) == 0, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
    }
}
