import Foundation
import MwoyeoCore
import MwoyeoEngines

/// The request path of text that is not under a lens: `translate_text` and `test_rules` for an agent, the Translate Text window, the Services
/// entry and the Shortcuts action for a person (docs/design/text-translation.md §1). One owner of which settings a request translates under
/// (`resolve`) and of the call itself (`run`); the lens's own `TranslationService` does the translating, a lens's memory is what the engine is
/// sent (`ContextPlan`), and a profile's rewrites and scripts apply as on a lens. Moved from `MCPTranslate.translate`, not copied.
enum TextTranslation {
    /// Who asks. An agent runs in a process of its own and acts for a person who is not watching: it starts no program and probes the key
    /// it needs. A person at the window is the app itself (design §1, the table of what differs).
    enum Asker {
        case agent, person

        var refusesCommands: Bool { self == .agent }
        var probesKey: Bool { self == .agent }
        /// `AppProfile.allAppsID` is a profile a person may pick; an agent's `profile` names one of `list_apps` (`test_rules` takes the same).
        var picksAllApps: Bool { self == .person }
    }

    /// The window a request is made for, and what the person (or agent) picked over it.
    struct Request: Sendable, Equatable {
        /// The app whose profile decides (the one in front, or the agent's `app`).
        var app: String?
        /// The window's title, as a lens would have confirmed it: titles pick profiles.
        var title: String?
        /// A profile picked by hand (its id, or `AppProfile.allAppsID`): as if every lens were pinned to it. nil is Auto.
        var profile: String?
        /// "apple", or the id of an added engine; nil is the engine the chain names.
        var engine: String?
        /// Languages picked over the chain's (a window's language bar, a shortcut's target); nil follows the chain.
        var source: String?
        var target: String?

        init(app: String? = nil, title: String? = nil, profile: String? = nil, engine: String? = nil, source: String? = nil, target: String? = nil) {
            self.app = app
            self.title = title
            self.profile = profile
            self.engine = engine
            self.source = source
            self.target = target
        }
    }

    /// Why a request was not run. Each caller says it in its own words (an agent's tool errors, the window's localized status line).
    enum Refusal: Error, Equatable {
        case noSuchProfile(String)
        case noSuchEngine(choice: String, known: [String])
        case commandEngine
        case keyUnreachable(engine: String, reason: String)
    }

    /// The settings a request translates under, and what was decided on the way.
    struct Resolved: Sendable {
        /// The base settings with the chain's pair and engine, the picked languages and the picked engine laid over them.
        var settings: AppSettings
        var app: String?
        var title: String?
        /// The lens the engine is sent memory for (nil: no app, profile or title named, so nothing but the lines).
        var lens: LensContext?
        /// The first profile of the chain, the one that decided the languages; nil when All apps did.
        var profile: AppProfile?
        var source: String { settings.sourceLanguage }
        var target: String { settings.targetLanguage }
        var engine: EngineConfig? { settings.activeEngineConfig }
    }

    /// One line's answer: nil translation is a line the service gave nothing for; nil engine is a line it left as it was (a counter, a name
    /// already in the target script) and so did not send.
    struct Row: Sendable, Equatable {
        var translation: String?
        var engine: String?
    }

    struct Answer: Sendable {
        var rows: [Row]
        /// Whether the service returned anything at all.
        var translated: Bool
        /// The newest issue the service raised; nil when its last word was "fine".
        var issue: TranslationIssue?
        /// The profile that decided the languages, and whether the chain's memory was part of what the engine was sent ("used" / "not used");
        /// nil when the chain keeps no memory.
        var profile: String?
        var memory: String?
    }

    // MARK: Which settings

    /// The settings `request` translates under, over `base` (the settings file as the app or the agent reads it). `withRewrites: false` turns
    /// every rewrite and script off, for `test_rules`, which applies them itself.
    static func resolve(_ request: Request, base: AppSettings, asker: Asker, secrets: any SecretStore, withRewrites: Bool = true) throws -> Resolved {
        var settings = base
        if !withRewrites {
            settings.rewrites = []
            settings.script = nil
            for i in settings.appProfiles.indices {
                settings.appProfiles[i].rewrites = []
                settings.appProfiles[i].script = nil
            }
        }
        if let profile = request.profile {
            guard (profile == AppProfile.allAppsID && asker.picksAllApps) || settings.appProfiles.contains(where: { $0.id == profile }) else { throw Refusal.noSuchProfile(profile) }
            // As if every lens were pinned to it: the chain is that profile and All apps, and no condition is asked (design names-and-context §1.3).
            settings.profilePin = profile
        }
        // The window's chain decides the languages and the engine, whichever app is in front (design §1.3, Q1). With no profile it is the base.
        let chain = ContextRoute.merged(settings: settings, lens: request.app, title: request.title)
        settings.sourceLanguage = request.source ?? chain.pair.source
        settings.targetLanguage = request.target ?? chain.pair.target
        settings.customEngineID = chain.pair.customEngineID
        if let choice = request.engine { try choose(choice, in: &settings) }
        if let engine = settings.activeEngineConfig {
            if case .command = engine.kind, asker.refusesCommands { throw Refusal.commandEngine }
            // The Keychain may be out of reach of an agent's process; saying so is better than an engine that fails as if it had no key.
            if asker.probesKey {
                do { _ = try secrets.secret(for: engine.id) } catch { throw Refusal.keyUnreachable(engine: engine.name, reason: String(describing: error)) }
            }
        }
        let unnamed = request.app == nil && request.profile == nil && request.title == nil
        let lens = unnamed ? nil
            : LensContext(bundleID: request.app ?? chain.head.profile?.bundleID ?? "",
                          appName: request.app.map { AppProfiles.profile(for: $0, in: settings.appProfiles)?.appName ?? $0 } ?? chain.head.profile?.name ?? "",
                          categoryWord: nil, confirmedTitle: request.title, lensID: asker == .agent ? "mcp" : "text")
        return Resolved(settings: settings, app: request.app, title: request.title, lens: lens, profile: chain.head.profile)
    }

    /// `engine`: "apple", or the id of an added engine.
    static func choose(_ choice: String, in settings: inout AppSettings) throws {
        if choice.lowercased() == "apple" {
            settings.customEngineID = nil
        } else if let engine = settings.engines.first(where: { $0.id.uuidString.caseInsensitiveCompare(choice) == .orderedSame }) {
            settings.customEngineID = engine.id
        } else {
            throw Refusal.noSuchEngine(choice: choice, known: ["apple"] + settings.engines.map { "\($0.id.uuidString) (\($0.name))" })
        }
    }

    // MARK: The call

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

    /// A service for `resolved`. An agent's call makes a fresh one (its cache is keyed by the glossary but not by an app's memory, so a service
    /// kept between calls would answer the line an agent asked about before it wrote the memory from its cache); the window keeps one while its
    /// settings are equal (`TextTranslator`).
    static func service(for resolved: Resolved, secrets: any SecretStore) -> TranslationService {
        TranslationService(settings: resolved.settings, secrets: secrets)
    }

    /// `lines` through `service` (or a fresh one) the way a lens over the window `resolved` names would translate them. `onResult` hears each
    /// line as it comes back (source, translation).
    static func run(_ lines: [String], _ resolved: Resolved, secrets: any SecretStore, service given: TranslationService? = nil,
                    onResult: (@Sendable (String, String) -> Void)? = nil) async -> Answer {
        let service = given ?? service(for: resolved, secrets: secrets)
        let heard = Heard()
        await service.setIssueHandler { heard.issue($0) }
        let observer = await service.observe { heard.answered($0) }
        let outcome = await service.translate(lines, context: resolved.lens, onResult: onResult)
        var languages: [String] = []
        for line in lines { languages.append(await service.sourceLanguage(for: line)) }
        await service.stopObserving(observer)
        let (routes, issue) = heard.all
        Trace.count("text.run")
        Trace.count("text.units", lines.count)

        // A line the service left as it was (a counter, a name already in the target script) was not sent to the engine: no engine.
        let rows = lines.indices.map { i -> Row in
            let translation = outcome.translations[lines[i]]
            let engine = translation == nil || translation == lines[i] ? nil : routes.last(where: { $0.source == languages[i] })?.engineName
            return Row(translation: translation, engine: engine)
        }
        let pairing = ContextRoute.pair(settings: resolved.settings, lens: resolved.app, title: resolved.title)
        let plan = ContextPlan.decide(settings: resolved.settings, engine: pairing.engine, engineRests: false, chain: pairing.chain)
        // The profile that decided the languages (a title or a pin may have picked another than the app's own), and whether the chain's memory was
        // part of what the engine was sent; a chain without one has nothing to send.
        return Answer(rows: rows, translated: !outcome.translations.isEmpty, issue: issue, profile: pairing.profile?.id,
                      memory: pairing.chain.hasMemory ? (plan == nil ? "not used" : "used") : nil)
    }
}

// MARK: - A text in, a text out

/// Translate Text's one entry for a whole text: the units of `TextParagraphs` (a line, or the lines of a paragraph that hard line breaks
/// wrapped), the call, the translations put back between the separators of the source. The window, the Services entry and the Shortcuts action each ask it; it keeps a service while the settings it was made for are
/// equal, so a text edited in one place translates only what changed (the service's cache) and a person's memory edit starts afresh.
@MainActor
final class TextTranslator {
    static let shared = TextTranslator(settings: { AppModel.shared.settings }, secrets: { AppModel.shared.secrets })

    struct Result: Sendable {
        /// The source with each unit replaced by its translation (the unit itself where there is none).
        var text: String
        var units: Int
        /// How many distinct units came back, and the engine that answered most recently (nil when none was sent to an engine).
        var translatedUnits: Int
        var engine: String?
        var issue: TranslationIssue?
        var profile: String?
        var memory: String?
        var languages: (source: String, target: String)
        var addedEngine: Bool
        /// Whether the service returned anything: false is a failure to say in words (`issue` has them, when the service had some).
        var translated: Bool
    }

    /// The service's own failures, and what the person asked that could not be run.
    enum Failure: Error { case refused(TextTranslation.Refusal), tooLong(Int) }

    /// The call to the service. A check swaps it for one that answers without an engine: Apple Translation does not answer to a check that
    /// holds the main queue, so what the window does around the call is checked with the call stubbed.
    var call: (_ lines: [String], _ resolved: TextTranslation.Resolved, _ secrets: any SecretStore, _ service: TranslationService,
               _ onResult: (@Sendable (String, String) -> Void)?) async -> TextTranslation.Answer = { lines, resolved, secrets, service, onResult in
        await TextTranslation.run(lines, resolved, secrets: secrets, service: service, onResult: onResult)
    }

    private let settings: () -> AppSettings
    private let secrets: () -> any SecretStore
    private var kept: (settings: AppSettings, service: TranslationService)?
    /// How many services were made and reused, for a check and the trace.
    private(set) var made = 0
    private(set) var reused = 0

    init(settings: @escaping () -> AppSettings, secrets: @escaping () -> any SecretStore) {
        self.settings = settings
        self.secrets = secrets
    }

    /// Where `request` stands before anything is sent: the languages, the engine and the profile it translates under.
    func resolve(_ request: TextTranslation.Request) throws -> TextTranslation.Resolved {
        do { return try TextTranslation.resolve(request, base: settings(), asker: .person, secrets: secrets()) } catch let refusal as TextTranslation.Refusal {
            throw Failure.refused(refusal)
        }
    }

    /// `text` translated under `request`. `progress` hears the units done, the units there are, and the text as far as it has come.
    func translate(_ text: String, _ request: TextTranslation.Request,
                   progress: (@MainActor (_ done: Int, _ total: Int, _ partial: String) -> Void)? = nil) async throws -> Result {
        guard text.count <= TextParagraphs.maxCharacters else { throw Failure.tooLong(text.count) }
        let resolved = try resolve(request)
        let parts = TextParagraphs.split(text)
        let units = TextParagraphs.units(parts)
        // The hard line breaks of wrapped paragraphs (copied from a PDF or a mail) that were read as no break: what was sent is the paragraph.
        Trace.count("text.wraps", TextParagraphs.wrapsJoined(parts))
        let secrets = secrets()
        let service: TranslationService
        if let kept, kept.settings == resolved.settings {
            service = kept.service
            reused += 1
            Trace.count("text.service.reused")
        } else {
            service = TextTranslation.service(for: resolved, secrets: secrets)
            kept = (resolved.settings, service)
            made += 1
        }
        let collected = Collected()
        let hear: (@Sendable (String, String) -> Void)? = progress.map { progress in
            { source, translation in
                let partial = collected.put(source, translation)
                Task { @MainActor in progress(partial.count, units.count, TextParagraphs.join(parts, partial)) }
            }
        }
        let answer = units.isEmpty ? TextTranslation.Answer(rows: [], translated: true, issue: nil, profile: nil, memory: nil)
            : await call(units, resolved, secrets, service, hear)
        var translations: [String: String] = [:]
        for (unit, row) in zip(units, answer.rows) { if let t = row.translation { translations[unit] = t } }
        return Result(text: TextParagraphs.join(parts, translations), units: units.count, translatedUnits: translations.count,
                      engine: answer.rows.compactMap(\.engine).last, issue: answer.issue, profile: answer.profile, memory: answer.memory,
                      languages: (resolved.source, resolved.target), addedEngine: resolved.engine != nil, translated: answer.translated)
    }

    /// The translations heard so far, shared with the service's callbacks.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String: String] = [:]
        /// Adds one and returns what there is now.
        func put(_ source: String, _ translation: String) -> [String: String] { lock.withLock { all[source] = translation; return all } }
    }
}
