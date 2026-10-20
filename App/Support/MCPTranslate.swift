import Foundation
import MwoyeoCore
import MwoyeoEngines

/// `translate_text`: a few lines through the very `TranslationService` a lens uses (`SelfTest`'s `--render` builds the same), under the
/// settings in effect for an app (its languages, its engine) and with that app's memory as a lens over the app would send it
/// (`LensContext`; `ContextPlan` decides what reaches which engine). An agent that has written a memory checks it here.
///
/// A fresh service per call: its cache is keyed by the glossary but not by an app's memory, so a service kept between calls would answer
/// the line an agent asked about before it wrote the memory from its cache.
enum MCPTranslate {
    static let maxLines = 20
    static let maxLineLength = 2000

    /// What the service said while it ran: which engine answered which language group, and the newest issue it raised (nil when the last
    /// word was "fine").
    private final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var routes: [TranslationRoute] = []
        private var latest: TranslationIssue?
        func answered(_ event: TranslationEvent) {
            lock.withLock { routes += event.groups.filter { $0.kind == .answered }.map(\.route) }
        }
        func issue(_ issue: TranslationIssue?) { lock.withLock { latest = issue } }
        var all: (routes: [TranslationRoute], issue: TranslationIssue?) { lock.withLock { (routes, latest) } }
    }

    static func run(_ a: [String: Any], _ world: MCPWorld) throws -> [String: Any] {
        let lines = a["lines"] as? [String] ?? []
        if lines.isEmpty { throw MCPToolError("translate_text was not run: lines holds no line") }
        let app = a["app"] as? String
        var settings = world.settings().effective(frontmost: app)
        if let choice = a["engine"] as? String { try choose(choice, in: &settings) }
        if let engine = settings.activeEngineConfig {
            if case .command = engine.kind {
                throw MCPToolError("translate_text does not run command engines (programs of the person's own); name apple or another engine")
            }
            // The Keychain may be out of reach of this process; saying so is better than an engine that fails as if it had no key.
            do { _ = try world.secrets.secret(for: engine.id) } catch {
                throw MCPToolError("translate_text cannot use \(engine.name): its API key is in the Keychain and this process cannot read it (\(error)). Use apple, or ask the person to translate with it in Mwoyeo")
            }
        }

        let lens = app.map { LensContext(bundleID: $0, appName: AppProfiles.profile(for: $0, in: settings.appProfiles)?.appName ?? $0,
                                         categoryWord: nil, confirmedTitle: nil, lensID: "mcp") }
        let service = TranslationService(settings: settings, secrets: world.secrets)
        let heard = Heard()
        let (outcome, languages) = MCPAsync.wait { () -> (TranslationOutcome, [String]) in
            await service.setIssueHandler { heard.issue($0) }
            _ = await service.observe { heard.answered($0) }
            let outcome = await service.translate(lines, context: lens)
            var languages: [String] = []
            for line in lines { languages.append(await service.sourceLanguage(for: line)) }
            return (outcome, languages)
        }
        let (routes, issue) = heard.all
        guard !outcome.translations.isEmpty else {
            throw MCPToolError("translate_text could not translate: " + (issue?.message ?? "no engine answered"))
        }

        // A line the service left as it was (a counter, a name already in the target script) was not sent to the engine: no engine.
        let rows = lines.indices.map { i -> [Any] in
            let translation = outcome.translations[lines[i]]
            let engine = translation == nil || translation == lines[i] ? nil : routes.last(where: { $0.source == languages[i] })?.engineName
            return [translation ?? NSNull(), engine ?? NSNull()]
        }
        var result: [String: Any] = ["columns": ["translation", "engine"], "rows": rows]
        let pairing = ContextRoute.pair(settings: settings, lens: app)
        let plan = ContextPlan.decide(settings: settings, engine: pairing.engine, engineRests: false, profile: pairing.profile)
        // Whether the app's memory was part of what the engine was sent; an app without one has nothing to send.
        if let profile = pairing.profile, profile.hasMemory { result["memory"] = plan == nil ? "not used" : "used" }
        if let issue { result["issue"] = issue.message }
        return result
    }

    /// `engine`: "apple", or the id of an added engine.
    static func choose(_ choice: String, in settings: inout AppSettings) throws {
        if choice.lowercased() == "apple" {
            settings.customEngineID = nil
        } else if let engine = settings.engines.first(where: { $0.id.uuidString.caseInsensitiveCompare(choice) == .orderedSame }) {
            settings.customEngineID = engine.id
        } else {
            let known = ["apple"] + settings.engines.map { "\($0.id.uuidString) (\($0.name))" }
            throw MCPToolError("translate_text was not run: engine: \"\(choice)\" is not an engine; use one of \(known.joined(separator: ", "))")
        }
    }
}

// MARK: - async work from the synchronous loop

/// The server reads and answers one line at a time on the main thread. A tool that has to await (the translation service is an actor)
/// runs its work on the cooperative pool, and the main run loop keeps turning while the loop waits, so whatever the work needs from the
/// run loop (the system's services answer on it) still happens, as in `--render`. It polls for the end: the main queue may be busy with
/// the very job that waits (a check run inside the app), so a wake-up through it could never come.
enum MCPAsync {
    private final class Box<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T?
        func put(_ value: T) { lock.withLock { stored = value } }
        var value: T? { lock.withLock { stored } }
    }

    static func wait<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
        let box = Box<T>()
        Task.detached { box.put(await work()) }
        while true {
            if let done = box.value { return done }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }
}
