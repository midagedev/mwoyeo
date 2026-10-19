import AppKit
import MwoyeoCore

/// The learned-memory file (design §10, the user's decision of 2026-10-19): while Save transcripts is on, the names and terms the
/// app learned for an app are written beside the transcripts, `<exportFolder>/Memory/<bundle id>.json`, so an agent can read them
/// before it edits the app's memory in settings.json. There is no setting of its own: one opt-in for "save what the lenses read".
///
/// What the file holds is the rows a request may use (two sightings or more), as source → translation pairs with their kind and
/// gender, and nothing else of the screen: no line, no title, no count of the lines read. A term is at most 40 characters and has no
/// newline or markup (`ContextMemory.rejection`). Nothing here logs.
enum LearnedMemoryFile {
    static let folderName = "Memory"

    static func folder(_ root: URL) -> URL { root.appendingPathComponent(folderName) }

    /// `com.example.chat` → `com.example.chat.json`. A bundle id is already a file name; anything outside letters, digits, `.`, `-`
    /// and `_` becomes `-`, and a name that is empty or only dots cannot be, so it is `app`.
    static func fileName(for bundleID: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        var name = String(bundleID.map { allowed.contains($0) ? $0 : "-" })
        if name.allSatisfy({ $0 == "." }) { name = "app" }
        return String(name.prefix(120)) + ".json"
    }

    /// The rows the file holds: the usable learned rows, sorted by source so the same memory is the same bytes.
    static func rows(from records: [ContextMemory.LearnedRecord]) -> [MemoryEntry] {
        records.filter(\.isUsable).map(\.entry).sorted { $0.src < $1.src }
    }

    /// The file's JSON. Keys are fixed and sorted; a row is `{src, dst, kind, gender?}` and has no other key, whatever the entry holds.
    static func render(bundleID: String, appName: String, rows: [MemoryEntry], updated: Date) -> Data {
        struct Row: Encodable { var src: String; var dst: String; var kind: String; var gender: String? }
        struct File: Encodable { var app: String; var appName: String; var updated: String; var about: String; var rows: [Row] }
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]
        let file = File(app: bundleID, appName: appName, updated: stamp.string(from: updated),
                        about: "Names and terms Mwoyeo learned while translating in this app (src is how it is written, dst how it was translated). "
                            + "To keep one, add it as a row of appProfiles[].entries in settings.json; this file is not read back.",
                        rows: rows.map { Row(src: $0.src, dst: $0.dst, kind: $0.kind.rawValue, gender: $0.gender?.rawValue) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return ((try? encoder.encode(file)) ?? Data()) + Data("\n".utf8)
    }
}

/// When a write is due: per app at most once in `interval`; a change inside the interval is written when the interval ends, with
/// whatever the rows are by then. A pure value, so the rule is tested with numbers and no clock.
struct LearnedWriteGate: Equatable {
    static let interval: TimeInterval = 5

    enum Step: Equatable {
        /// Write now (and the gate counts it as the write).
        case now
        /// Write after this many seconds, then call `flushed`.
        case later(TimeInterval)
        /// A write is already waiting; it will read the newest rows.
        case pending
    }

    private var last: [String: TimeInterval] = [:]
    private var waiting: Set<String> = []

    mutating func changed(_ app: String, at now: TimeInterval) -> Step {
        if waiting.contains(app) { return .pending }
        if let last = last[app], now - last < Self.interval {
            waiting.insert(app)
            return .later(last + Self.interval - now)
        }
        last[app] = now
        return .now
    }

    /// The waiting write of `app` is being done now.
    mutating func flushed(_ app: String, at now: TimeInterval) {
        waiting.remove(app)
        last[app] = now
    }
}

/// Writes the learned-memory files. Main actor: it reads the settings and opens the export folder the way the transcripts do (the
/// panel is never shown for this: no folder yet means no file yet, and the transcript writer is the one that asks).
@MainActor
final class LearnedMemoryWriter {
    struct Env {
        var settings: () -> AppSettings
        /// The access to the export folder, without asking for one.
        var access: (AppSettings) -> ExportFolder.Access?
        /// The app's learned rows (`TranslationService.learnedRows`).
        var records: (String) async -> [ContextMemory.LearnedRecord]
        var now: () -> TimeInterval
        var date: () -> Date
        /// Runs `body` after `seconds` on the main actor.
        var after: (TimeInterval, @escaping @MainActor () async -> Void) -> Void
    }

    private let env: Env
    private var gate = LearnedWriteGate()

    init(_ env: Env) { self.env = env }

    /// The app's learned rows changed. Writes now, soon, or not at all (Save transcripts off). The task is the write in progress, for
    /// a caller that wants to wait for it; nil when nothing is written yet.
    @discardableResult
    func changed(_ bundleID: String) -> Task<Void, Never>? {
        guard env.settings().savesTranscripts else { return nil }
        switch gate.changed(bundleID, at: env.now()) {
        case .now:
            return Task { await write(bundleID) }
        case let .later(seconds):
            env.after(seconds) { [weak self] in
                guard let self else { return }
                self.gate.flushed(bundleID, at: self.env.now())
                await self.write(bundleID)
            }
            return nil
        case .pending:
            return nil
        }
    }

    /// Save transcripts was turned on (or the export folder moved while it is on): the rows learned so far go to the file too, not only
    /// those that change from now on. `apps` are the apps that have usable rows.
    @discardableResult
    func savingTurnedOn(for apps: [String]) -> [Task<Void, Never>] {
        apps.compactMap { changed($0) }
    }

    /// One write: the usable rows to `Memory/<bundle id>.json`, atomically. With no row and no file there is nothing to say; with no row
    /// and a file (the user forgot, removed or pinned the last one) the file says so.
    func write(_ bundleID: String) async {
        let settings = env.settings()
        guard settings.savesTranscripts else { return }
        let rows = LearnedMemoryFile.rows(from: await env.records(bundleID))
        guard let access = env.access(settings) else { return }
        let dir = LearnedMemoryFile.folder(access.url)
        let url = dir.appendingPathComponent(LearnedMemoryFile.fileName(for: bundleID))
        let name = AppProfiles.profile(for: bundleID, in: settings.appProfiles)?.appName ?? bundleID
        let data = LearnedMemoryFile.render(bundleID: bundleID, appName: name, rows: rows, updated: env.date())
        await Task.detached(priority: .utility) {
            defer { access.end() }
            if rows.isEmpty, !FileManager.default.fileExists(atPath: url.path) { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }.value
    }

    /// The writer the app uses: the real settings, the export folder as the transcripts open it (never asking), the translator's rows.
    static func live(settings: @escaping () -> AppSettings, store: @escaping (Data, URL) -> Void,
                     records: @escaping (String) async -> [ContextMemory.LearnedRecord]) -> LearnedMemoryWriter {
        LearnedMemoryWriter(Env(
            settings: settings,
            access: { ExportFolderGate.shared.access(for: $0, ask: false, store: store) },
            records: records,
            now: { ProcessInfo.processInfo.systemUptime },
            date: { Date() },
            after: { seconds, body in
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { Task { @MainActor in await body() } }
            }))
    }
}
