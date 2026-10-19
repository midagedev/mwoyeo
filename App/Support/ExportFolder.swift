import AppKit

/// The folder lens images and transcripts are written to, opened the way the App Sandbox wants: the person chooses it in a
/// panel, the app keeps a security-scoped bookmark of it, and every write happens between start and stop of the access
/// (docs/app-store/audit-2026-10-17.md §1, §3). The DMG build is not sandboxed: with no bookmark it writes to the path in
/// `exportFolder` as before.
enum ExportFolder {
    /// An open access to the folder. Ends once, on `end()` or when the last reference goes.
    final class Access: @unchecked Sendable {
        let url: URL
        private let scoped: Bool
        private let lock = NSLock()
        private var open = true

        init(url: URL, scoped: Bool) {
            self.url = url
            self.scoped = scoped
        }

        func end() {
            lock.lock()
            defer { lock.unlock() }
            guard open else { return }
            open = false
            if scoped { url.stopAccessingSecurityScopedResource() }
        }

        deinit { end() }
    }

    enum Resolution: Equatable {
        /// `refreshed`: the bookmark was stale and this is the new one to keep.
        case ok(URL, refreshed: Data?)
        /// No bookmark, and this build may use the path in `exportFolder`.
        case path(URL)
        /// Nothing usable: no folder was ever chosen, or the bookmark no longer opens one.
        case needsChoice(stale: Bool)
    }

    static func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// The folder `settings` points at. A bookmark wins when it opens a folder; on the DMG a path in `exportFolder` that the
    /// bookmark does not point at (edited in settings.json) wins over it, so the file keeps saying where files go.
    static func resolve(_ settings: AppSettings, allowsPath: Bool = !Distribution.isAppStore) -> Resolution {
        if let data = settings.exportBookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) {
                let samePath = url.standardizedFileURL.path == URL(fileURLWithPath: settings.exportFolder).standardizedFileURL.path
                if allowsPath, !samePath, !settings.exportFolder.isEmpty { return .path(URL(fileURLWithPath: settings.exportFolder)) }
                // A stale bookmark still opens the folder when it only moved; a new one is made from the opened URL.
                if stale {
                    let started = url.startAccessingSecurityScopedResource()
                    defer { if started { url.stopAccessingSecurityScopedResource() } }
                    if let fresh = makeBookmark(for: url) { return .ok(url, refreshed: fresh) }
                    return .needsChoice(stale: true)
                }
                return .ok(url, refreshed: nil)
            }
            if allowsPath, !settings.exportFolder.isEmpty { return .path(URL(fileURLWithPath: settings.exportFolder)) }
            return .needsChoice(stale: true)
        }
        if allowsPath, !settings.exportFolder.isEmpty { return .path(URL(fileURLWithPath: settings.exportFolder)) }
        return .needsChoice(stale: false)
    }

    /// Starts the access for a resolved folder; nil for `needsChoice`.
    static func begin(_ resolution: Resolution) -> Access? {
        switch resolution {
        case let .ok(url, _): Access(url: url, scoped: url.startAccessingSecurityScopedResource())
        case let .path(url): Access(url: url, scoped: false)
        case .needsChoice: nil
        }
    }

    /// The folder to show in Settings: nil while none is chosen.
    static func shownPath(_ settings: AppSettings) -> String? {
        switch resolve(settings) {
        case let .ok(url, _), let .path(url): url.path
        case .needsChoice: nil
        }
    }
}

/// Asks for the folder when there is none or the bookmark went stale, and asks at most once until the person chooses one in
/// Settings (`reset`). A declined panel is not shown again by the next save or the next transcript line.
@MainActor
final class ExportFolderGate {
    static let shared = ExportFolderGate()

    /// Shows the choosing panel; nil when the person cancels. `stale`: the folder chosen before no longer opens.
    var asker: (_ stale: Bool) -> URL? = ExportFolderGate.panel
    private(set) var askedSinceReset = false

    /// The access to write under, or nil when none is possible. Saves a refreshed or newly chosen bookmark through `store`.
    func access(for settings: AppSettings, ask: Bool = true, store: (_ bookmark: Data, _ folder: URL) -> Void) -> ExportFolder.Access? {
        let resolution = ExportFolder.resolve(settings)
        if case let .ok(url, refreshed?) = resolution { store(refreshed, url) }
        if let access = ExportFolder.begin(resolution) { return access }
        guard ask, !askedSinceReset else { return nil }
        askedSinceReset = true
        guard case let .needsChoice(stale) = resolution, let url = asker(stale),
              let data = ExportFolder.makeBookmark(for: url) else { return nil }
        store(data, url)
        return ExportFolder.begin(.ok(url, refreshed: nil))
    }

    /// The person chose a folder (or changed saving) in Settings: a later need may ask again.
    func reset() { askedSinceReset = false }

    static func panel(stale: Bool) -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        panel.message = stale ? String(localized: "Mwoyeo can no longer open its saving folder. Choose it again.")
                              : String(localized: "Choose a folder for saved lens images and transcripts.")
        return panel.runModal() == .OK ? panel.url : nil
    }
}
