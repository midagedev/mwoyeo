import AppKit
import MwoyeoCore

/// When a lens may read the window it covers: at most every `interval` seconds while a capture pass runs, and only while the
/// settings could put context on (`ContextOptions.couldBeOn`). A pure value, so the rule is tested without a clock or a window.
/// The title needs 3 reads over at least 1 s to be confirmed (`TitleConfirmer`), so 0.5 s apart confirms it on the third.
struct SampleGate: Equatable {
    static let interval: TimeInterval = 0.5

    var enabled = false
    private var last = -TimeInterval.infinity
    private var busy = false

    /// True when a read is due now; the caller then reads and calls `finish()`. Never while a read is running.
    mutating func admit(now: TimeInterval) -> Bool {
        guard enabled, !busy, now - last >= Self.interval else { return false }
        last = now
        busy = true
        return true
    }

    mutating func finish() { busy = false }
}

/// The window a lens covers, read on each capture pass that is due (`SampleGate`): the app, its category word, and the title through
/// `TitleConfirmer`. One per lens. Main actor: it reads the window list and the running applications.
@MainActor
final class LensWatch {
    private var confirmer = TitleConfirmer()
    private var app: String?
    private var categories: [String: String?] = [:]
    private var sent: LensContext?

    /// Reads the lens's window now. `context` is the document when it differs from the one last returned (nil for "nothing new");
    /// `gone` says the lens covers no readable window any more (the caller stops handing a context to the pipeline).
    func sample(config: RegionConfig, now: TimeInterval) -> (context: LensContext?, gone: Bool) {
        ingest(Self.window(of: config), lensID: config.id.uuidString, now: now)
    }

    /// One read of the window (nil: none), fed through the title confirmation. `sample` without the window list, so the rules are
    /// tested with a title sequence.
    func ingest(_ w: Read?, lensID: String, now: TimeInterval) -> (context: LensContext?, gone: Bool) {
        guard let w else {
            if sent == nil { return (nil, false) }
            reset()
            return (nil, true)
        }
        // Another app under the lens: its first title is taken at once, not weighed against the old app's.
        if w.bundleID != app { confirmer = TitleConfirmer() }
        app = w.bundleID
        let title = confirmer.observe(TitleNormalizer.normalize(w.title, appName: w.appName), at: now)
        if categories.index(forKey: w.bundleID) == nil { categories[w.bundleID] = .some(w.category ?? AppModel.category(ofApp: w.bundleID)) }
        let category = categories[w.bundleID] ?? nil
        let context = LensContext(bundleID: w.bundleID, appName: w.appName, categoryWord: CategoryDomain.word(for: category),
                                  confirmedTitle: title, lensID: lensID)
        guard context != sent else { return (nil, false) }
        sent = context
        return (context, false)
    }

    /// Forgets everything read (the settings no longer put context on, or the lens covers nothing).
    func reset() {
        confirmer = TitleConfirmer()
        app = nil
        sent = nil
    }

    /// One read of the window: the app that owns it and its raw title. `category` is for tests; a real read leaves it nil and the
    /// app's `LSApplicationCategoryType` is looked up once per app.
    struct Read { var bundleID: String; var appName: String; var title: String; var category: String? = nil }

    /// The window the lens follows, else the topmost one under its centre: the app that owns it and its title. The title needs the
    /// Screen Recording grant the lens already has; without it the title is empty and the card has none.
    static func window(of config: RegionConfig) -> Read? {
        let w: WindowInfo?
        if let anchor = config.anchor {
            w = WindowInfo.window(id: anchor.windowID)
        } else {
            let centre = CGPoint(x: config.rect.midX, y: config.rect.midY)
            w = WindowInfo.onScreen().first { $0.bounds.contains(centre) }
        }
        guard let w, let running = NSRunningApplication(processIdentifier: w.pid), let bundleID = running.bundleIdentifier else { return nil }
        return Read(bundleID: bundleID, appName: running.localizedName ?? w.appName, title: w.title)
    }
}
