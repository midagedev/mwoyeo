import AppKit
import MwoyeoCore

/// Per-app language profiles. The app in front picks which one applies, so only one pair is in effect at a time:
/// a lens over a window of another app translates with the pair of the app you are using, not the one it covers.
extension AppModel {
    /// Follows the frontmost app. Mwoyeo itself never counts (opening Settings must not drop the profile in use).
    func startWatchingFrontmostApp() {
        let me = Bundle.main.bundleIdentifier
        func note(_ app: NSRunningApplication?) {
            guard let id = app?.bundleIdentifier, id != me else { return }
            frontmostBundleID = id
        }
        note(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { note(app) }
        }
    }

    /// The profile in effect now.
    var activeProfile: AppProfile? { AppProfiles.profile(for: frontmostBundleID, in: settings.appProfiles) }

    func profile(for bundleID: String) -> AppProfile? { AppProfiles.profile(for: bundleID, in: settings.appProfiles) }

    /// The language bar's edits: they go to the profile in effect, else to the base settings.
    func setLanguages(source: String? = nil, target: String? = nil) {
        if let p = activeProfile, let i = settings.appProfiles.firstIndex(of: p) {
            if let source { settings.appProfiles[i].source = source }
            if let target { settings.appProfiles[i].target = target }
        } else {
            if let source { settings.sourceLanguage = source }
            if let target { settings.targetLanguage = target }
        }
    }

    func remember(_ profile: AppProfile) {
        settings.appProfiles = AppProfiles.remembering(profile, in: settings.appProfiles)
    }

    func forgetProfile(_ bundleID: String) {
        settings.appProfiles.removeAll { $0.bundleID == bundleID }
    }

    /// The app that owns window `id`, for a lens that follows it.
    static func app(ofWindow id: CGWindowID) -> (bundleID: String, name: String)? {
        guard let w = WindowInfo.window(id: id), let app = NSRunningApplication(processIdentifier: w.pid),
              let bundleID = app.bundleIdentifier else { return nil }
        return (bundleID, app.localizedName ?? w.appName)
    }
}

/// What the paragraph reader knows about the app a lens covers.
extension AppModel {
    /// The app under a lens: the window it follows, else the topmost window under its centre.
    static func readerContext(for config: RegionConfig) -> ReaderContext {
        let app: (bundleID: String, name: String)?
        if let anchor = config.anchor {
            app = Self.app(ofWindow: anchor.windowID)
        } else if let w = WindowInfo.onScreen().first(where: { $0.bounds.contains(CGPoint(x: config.rect.midX, y: config.rect.midY)) }),
                  let running = NSRunningApplication(processIdentifier: w.pid), let id = running.bundleIdentifier {
            app = (id, running.localizedName ?? w.appName)
        } else {
            app = nil
        }
        guard let app else { return ReaderContext() }
        return ReaderContext(bundleID: app.bundleID, category: category(ofApp: app.bundleID))
    }

    /// `LSApplicationCategoryType` from the app's Info.plist; nil when the app has none or the plist cannot be read (the decider
    /// then goes by the bundle ID and the layout).
    static func category(ofApp bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return Bundle(url: url)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
    }
}
