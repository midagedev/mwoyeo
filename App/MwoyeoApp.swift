import AppKit
import MwoyeoCore
import SwiftUI

/// Command-line modes, which run before the app starts and print to stdout:
///   `Mwoyeo --render in.png out.png …`        the pipeline on a still image (see SelfTest).
///   `Mwoyeo --capture-ui outdir scenario…`    window captures and logic checks (see UICapture).
///   `Mwoyeo --settings-path`                  prints where settings.json is (`MWOYEO_SETTINGS_FILE` names another).
///   `Mwoyeo --check-settings [path]`          prints `settings.json:<line>: <message>` per issue, or `ok`; exit 1 when
///                                             there are issues. Without a path it checks the real file.
@main
enum Entry {
    static func main() {
        // `Mwoyeo --render in.png out.png` runs the pipeline on a still image (no permissions needed).
        if CommandLine.arguments.dropFirst().first == "--render" {
            SelfTest.run(Array(CommandLine.arguments.dropFirst(2)))
        }
        // `Mwoyeo --warm-vision <step> <key>` is the child the app starts to compile one Swift Vision model of a language set
        // (`SwiftVisionChild`).
        if CommandLine.arguments.dropFirst().first == "--warm-vision" {
            let rest = CommandLine.arguments.dropFirst(2)
            SwiftVisionChild.runChild(step: rest.first ?? "", key: rest.dropFirst().first ?? SwiftVisionGate.anyLanguage)
        }
        if CommandLine.arguments.dropFirst().first == "--capture-ui" {
            UICapture.run(Array(CommandLine.arguments.dropFirst(2)))
        }
        if let first = CommandLine.arguments.dropFirst().first, first == "--settings-path" || first == "--check-settings" {
            SettingsFileCommand.run(Array(CommandLine.arguments.dropFirst()))
        }
        MwoyeoApp.main()
    }
}

struct MwoyeoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPanel()
                .environment(model)
        } label: {
            Image(systemName: menuSymbol)
                .accessibilityLabel("Mwoyeo")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }

    private var menuSymbol: String {
        if model.isPaused { return "pause.circle" }
        if !model.translationsVisible { return "eye.slash" }
        return model.regions.contains(where: \.isEnabled) ? "text.viewfinder" : "viewfinder"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await AppModel.shared.bootstrap() }
        // `MWOYEO_PREVIEW=menu|onboarding` shows that window on launch, for screenshots.
        switch ProcessInfo.processInfo.environment["MWOYEO_PREVIEW"] {
        case "menu": Task { @MainActor in WindowPresenter.shared.showMenuPreview() }
        case "onboarding": Task { @MainActor in WindowPresenter.shared.showOnboarding() }
        default: break
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in WindowPresenter.shared.showOnboarding() }
        return true
    }
}

/// Opens AppKit-hosted windows (onboarding) and the Settings scene for a menu-bar-only app.
@MainActor
final class WindowPresenter {
    static let shared = WindowPresenter()
    private var onboarding: NSWindow?

    func showOnboarding() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = onboarding {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: OnboardingView { [weak self] in self?.closeOnboarding() }
            .environment(AppModel.shared))
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        onboarding = w
    }

    func showMenuPreview() {
        let w = NSWindow(contentViewController: NSHostingController(rootView: MenuPanel().environment(AppModel.shared)))
        w.styleMask = [.titled, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.setFrameTopLeftPoint(CGPoint(x: 200, y: (NSScreen.main?.frame.maxY ?? 900) - 120))
        w.makeKeyAndOrderFront(nil)
        preview = w
    }

    private var preview: NSWindow?

    func closeOnboarding() {
        onboarding?.close()
        onboarding = nil
    }
}
