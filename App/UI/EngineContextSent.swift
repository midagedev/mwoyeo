import MwoyeoCore
import SwiftUI

/// What the engine sheet says it sends: the "Sent:" line of the Context section and the sentences of the footnote under the box that
/// allows sending. This file is the one place both come from; the sheet and the checks only ask `line` and `footnotes`.
///
/// This version knows the apps' memory (the context service, D1): an engine whose Context is off still sends an app's name and category,
/// its note and its names in the text when the person wrote some for the app ("memory only"), so the line and the footnote say so, by the
/// request path's own rule (`AppModel.sentPreview(forEngine:)`, `AppModel.contextDisclosure(forEngine:)`).
enum EngineContextSent {
    /// One check's report: what it says, whether it held, and what to print when it did not.
    typealias Check = (_ what: String, _ ok: Bool, _ note: String) -> Void

    // MARK: the words

    /// The words of the "Sent:" line, in the app's language. The fields come from `SentSummary`; an app's name is the app's own, its
    /// category (Core's id, `CategoryDomain.words`) goes through `category`.
    struct Words {
        var sent: (String) -> String
        var category: (String) -> String
        var linesOnly: String
        var windowTitle: String
        var note: String
        var names: (Int) -> String
        /// The scopes of the names, in the parentheses after the count: the app's (with `learnedToo` after it when the engine's learned
        /// rows are counted) and the glossary's (design names-and-context §3.3).
        var thisApp: (Int) -> String
        var learnedToo: String
        var allApps: (Int) -> String
        var before: (Int) -> String
        var after: (Int) -> String

        @MainActor static var current: Words {
            Words(sent: { String(localized: "Sent: \($0)") }, category: { EngineContextSent.categoryWord($0) }, linesOnly: String(localized: "lines only"),
                  windowTitle: String(localized: "window title"), note: String(localized: "note"),
                  names: { String(localized: "up to \($0) names") }, thisApp: { String(localized: "\($0) this app") },
                  learnedToo: String(localized: "learned too"), allApps: { String(localized: "\($0) all apps") },
                  before: { String(localized: "\($0) lines before") }, after: { String(localized: "\($0) lines after") })
        }
    }

    /// The line for `summary` in `words`: the app and its category, the window title, the note, the names, the lines before and after,
    /// in the order Core's English line (`SentSummary.text`) gives them; "lines only" when nothing but the lines to translate goes.
    static func said(_ summary: SentSummary, in words: Words) -> String {
        var parts: [String] = []
        if let app = summary.appName { parts.append(summary.domain.map { "\(app) · \(words.category($0))" } ?? app) }
        if summary.windowTitle { parts.append(words.windowTitle) }
        if summary.hasNote { parts.append(words.note) }
        if summary.names + summary.allApps > 0 {
            var scopes: [String] = []
            if summary.names > 0 { scopes.append(words.thisApp(summary.names) + (summary.learned ? ", " + words.learnedToo : "")) }
            if summary.allApps > 0 { scopes.append(words.allApps(summary.allApps)) }
            parts.append(words.names(summary.names + summary.allApps) + " (" + scopes.joined(separator: ", ") + ")")
        }
        if summary.linesBefore > 0 { parts.append(words.before(summary.linesBefore)) }
        if summary.linesAfter > 0 { parts.append(words.after(summary.linesAfter)) }
        return words.sent(parts.isEmpty ? words.linesOnly : parts.joined(separator: " · "))
    }

    /// The display word of a category id Core sends (the values of `CategoryDomain.words`), in the app's language; nil for an id this
    /// version has no word for. Every id has its own `String(localized:)`, so the catalog sees each as a key.
    static func knownCategoryWord(_ id: String) -> String? {
        switch id {
        case "books": return String(localized: "books", comment: "App category in the Sent: line")
        case "business": return String(localized: "business", comment: "App category in the Sent: line")
        case "design": return String(localized: "design", comment: "App category in the Sent: line")
        case "dev": return String(localized: "dev", comment: "App category in the Sent: line (developer tools)")
        case "education": return String(localized: "education", comment: "App category in the Sent: line")
        case "entertainment": return String(localized: "entertainment", comment: "App category in the Sent: line")
        case "finance": return String(localized: "finance", comment: "App category in the Sent: line")
        case "food": return String(localized: "food", comment: "App category in the Sent: line (food and drink)")
        case "games": return String(localized: "games", comment: "App category in the Sent: line")
        case "health": return String(localized: "health", comment: "App category in the Sent: line (health and fitness)")
        case "lifestyle": return String(localized: "lifestyle", comment: "App category in the Sent: line")
        case "maps": return String(localized: "maps", comment: "App category in the Sent: line (navigation)")
        case "medical": return String(localized: "medical", comment: "App category in the Sent: line")
        case "music": return String(localized: "music", comment: "App category in the Sent: line")
        case "news": return String(localized: "news", comment: "App category in the Sent: line")
        case "photo": return String(localized: "photo", comment: "App category in the Sent: line (photography)")
        case "productivity": return String(localized: "productivity", comment: "App category in the Sent: line")
        case "reference": return String(localized: "reference", comment: "App category in the Sent: line")
        case "shopping": return String(localized: "shopping", comment: "App category in the Sent: line")
        case "social": return String(localized: "social", comment: "App category in the Sent: line (social networking)")
        case "sports": return String(localized: "sports", comment: "App category in the Sent: line")
        case "travel": return String(localized: "travel", comment: "App category in the Sent: line")
        case "utilities": return String(localized: "utilities", comment: "App category in the Sent: line")
        case "video": return String(localized: "video", comment: "App category in the Sent: line")
        case "weather": return String(localized: "weather", comment: "App category in the Sent: line")
        default: return nil
        }
    }

    /// The category word of the line: the display word of a known id, an id with no word as it is.
    static func categoryWord(_ id: String) -> String { knownCategoryWord(id) ?? id }

    // MARK: what the sheet asks

    /// The Context section's "Sent: …" line for `engine` as the sheet has it now (its switches as settings hold them): the first app
    /// that wrote memory for it, as the request path sends it, else a sample app under the engine's own switches.
    @MainActor static func line(for engine: EngineConfig, in model: AppModel) -> String {
        said(model.sentPreview(forEngine: engine), in: .current)
    }

    /// The sentences under the box that allows sending (each its own line): that lines of the window go along, and for which apps the
    /// person's notes and names go along.
    @MainActor static func footnotes(for engine: EngineConfig, in model: AppModel) -> [String] {
        let disclosure = model.contextDisclosure(forEngine: engine)
        var out: [String] = []
        if disclosure.lines { out.append(String(localized: "Recent lines are sent too, for context.")) }
        if !disclosure.memoryApps.isEmpty {
            let apps = ListFormatter.localizedString(byJoining: disclosure.memoryApps)
            out.append(String(localized: "Your notes and names for \(apps) are sent too."))
        }
        return out
    }

#if !MAS
    // MARK: checks

    /// The checks of this file's own wording and of the memory it discloses, `check-logic` lines under "engine context".
    @MainActor static func checks(_ model: AppModel, _ report: Check) {
        func check(_ what: String, _ ok: Bool, _ note: @autoclosure () -> String = "") { report(what, ok, ok ? "" : note()) }
        let cloud = EngineKind.openAICompatible(baseURL: URL(string: "https://api.example.invalid/v1")!, model: "m1", thinking: .off, extraHeaders: [:])
        let local = EngineKind.openAICompatible(baseURL: URL(string: "http://localhost:11434/v1")!, model: "m1", thinking: .off, extraHeaders: [:])
        let anthropic = EngineKind.anthropic(baseURL: URL(string: "https://anthropic.example.invalid")!, model: "m1", thinking: .off)
        let deepL = EngineKind.deepL(baseURL: URL(string: "https://api-free.deepl.invalid/")!, formality: nil)
        let template = EngineKind.httpTemplate(HTTPTemplate(url: "https://service.example.invalid/translate", resultPath: "text"))
        let on3 = EngineContext(enabled: true, previousLines: 3)
        let offKept = EngineContext(enabled: false, previousLines: 5, includeTitle: true, useLearned: true, deepLInstructions: true)
        let words = Words(sent: { "S[\($0)]" }, category: { "C(\($0))" }, linesOnly: "LO", windowTitle: "WT", note: "NOTE", names: { "N\($0)" },
                          thisApp: { "T\($0)" }, learnedToo: "LT", allApps: { "G\($0)" }, before: { "B\($0)" }, after: { "A\($0)" })
        func engine(_ kind: EngineKind, _ context: EngineContext?) -> EngineConfig {
            var e = EngineConfig(name: "Sent check", kind: kind)
            e.context = context
            return e
        }
        func marked(_ kind: EngineKind, _ context: EngineContext?) -> String {
            said(ContextChecks.engineSummary(engine(kind, context), []), in: words)   // prof-file: the engine's old `context` goes through the converter
        }
        let saved = model.settings.appProfiles, savedEngines = model.settings.engines, savedSelection = model.settings.customEngineID
        let savedContext = model.settings.context, savedLearned = model.settings.useLearned
        defer {
            model.settings.appProfiles = saved
            model.settings.engines = savedEngines
            model.settings.customEngineID = savedSelection
            model.settings.context = savedContext
            model.settings.useLearned = savedLearned
        }
        model.settings.appProfiles = []
        // prof-file (2026-10-21): the engines of these fixtures carry 1.1.4's `context`. The line and the footnote are asked of the settings the
        // converter makes of them (All apps' amount, learning, and the engine's `allow`), as a file of 1.1.4 would be read.
        func asked(_ e: EngineConfig) -> EngineConfig {
            model.settings.engines = [e]
            model.settings.customEngineID = e.id
            model.settings.context = nil
            model.settings.useLearned = false
            model.settings = model.settings.convertedFromOldFields()
            return model.settings.engines[0]
        }
        func lineOf(_ e: EngineConfig) -> String { line(for: asked(e), in: model) }
        func footnotesOf(_ e: EngineConfig) -> [String] { footnotes(for: asked(e), in: model) }

        // The words.
        check("Off says lines only, for every kind, whatever the other switches hold",
              [cloud, local, anthropic, deepL].allSatisfy { marked($0, nil) == "S[LO]" && marked($0, offKept) == "S[LO]" }, marked(cloud, offKept))
        check("On says the sample app and its category, the lines before and the lines after",
              marked(cloud, on3) == "S[Example Chat · C(social) · B3 · A2]" && marked(anthropic, EngineContext(enabled: true, previousLines: 0)) == "S[Example Chat · C(social) · B2 · A2]",
              "\(marked(cloud, on3)) | \(marked(anthropic, EngineContext(enabled: true, previousLines: 0)))")
        check("the window title is in the line only where the request would carry it: the local server always, a cloud engine on opt-in",
              marked(local, on3).contains("WT") && !marked(cloud, on3).contains("WT") && !marked(deepL, on3).contains("WT")
              && marked(cloud, EngineContext(enabled: true, previousLines: 3, includeTitle: true)).contains("WT"),
              "\(marked(local, on3)) | \(marked(cloud, on3))")
        let full = SentSummary(mode: .context, appName: "Mail", domain: "email", windowTitle: true, hasNote: true, names: 3, allApps: 2, linesBefore: 4, linesAfter: 2)
        var learned = full
        learned.learned = true
        // 2026-10-21 (round nameslens, G15): the names part of the line is the total with the scopes of its names in parentheses (design
        // names-and-context §3.3); it used to be the total alone, with "(learned too)" after it. Derivation: 3 of the app + 2 of the glossary
        // = N5; the app's part takes the learned marker.
        check("every field of a summary has its word, in the order of Core's English line, and the line says only the fields that are set",
              said(full, in: words) == "S[Mail · C(email) · WT · NOTE · N5 (T3, G2) · B4 · A2]" && said(learned, in: words) == "S[Mail · C(email) · WT · NOTE · N5 (T3, LT, G2) · B4 · A2]"
              && said(SentSummary(mode: .memoryOnly, appName: "Mail", hasNote: true), in: words) == "S[Mail · NOTE]"
              && said(SentSummary(mode: .linesOnly), in: words) == "S[LO]")
        check("a scope with no names is left out of the parentheses, and the line is Core's English line in the same order",
              said(SentSummary(mode: .memoryOnly, appName: "Mail", names: 2), in: words) == "S[Mail · N2 (T2)]"
              && said(SentSummary(mode: .memoryOnly, appName: "Mail", allApps: 4), in: words) == "S[Mail · N4 (G4)]"
              && SentSummary(mode: .memoryOnly, appName: "Mail", names: 2, allApps: 1).text == "Sent: Mail · up to 3 names (2 this app, 1 all apps)")

        // The category word: Core's ids go through the app's language, in every language the app ships.
        let ids = Set(CategoryDomain.words.values)
        let unknown = ids.filter { knownCategoryWord($0) == nil }.sorted()
        check("every category id Core can send has a display word here, and an id nobody knows is shown as it is",
              !ids.isEmpty && unknown.isEmpty && categoryWord("email") == "email" && knownCategoryWord("email") == nil, "no word for \(unknown)")
        let languages = Bundle.main.localizations.filter { $0 != "en" && $0 != "Base" }
        let missing = languages.flatMap { language -> [String] in
            guard let path = Bundle.main.path(forResource: language, ofType: "lproj"), let table = Bundle(path: path) else { return [language] }
            return ids.sorted().filter { table.localizedString(forKey: $0, value: "\u{1}", table: nil) == "\u{1}" }.map { "\(language):\($0)" }
        }
        check("every language the app ships has a word for every category id, a copy to review at least", !languages.isEmpty && missing.isEmpty,
              "missing \(missing) of \(languages)")

        // The line and the footnote of the sheet.
        let lineOff = lineOf(engine(cloud, nil))
        let lineOn = lineOf(engine(cloud, on3))
        check("the line the sheet shows follows the switches: lines only when off, the sample app and the lines when on",
              lineOff == Words.current.sent(Words.current.linesOnly) && lineOn != lineOff && lineOn.contains("Example Chat"), "\(lineOff) → \(lineOn)")
        let says = String(localized: "Recent lines are sent too, for context.")
        check("the footnote says that lines go along when the engine's context can be on, and nothing when it cannot be",
              footnotesOf(engine(cloud, on3)) == [says] && footnotesOf(engine(cloud, nil)).isEmpty
              && footnotesOf(engine(template, on3)).isEmpty)

        // Memory only (D1): the apps that wrote a note or names are named, with Context off.
        func profile(_ id: String, name: String, note: String = "", entries: [MemoryEntry] = [], engine: UUID? = nil, context: AppContextOverride? = nil) -> AppProfile {
            AppProfile(bundleID: id, appName: name, source: "ja", target: "ko", customEngineID: engine, note: note, entries: entries, context: context)
        }
        let rows = [MemoryEntry(src: "先輩", dst: "선배", kind: .term)]
        let notes = String(localized: "Your notes and names for \(ListFormatter.localizedString(byJoining: ["Mail"])) are sent too.")
        model.settings.appProfiles = [profile("com.example.mail", name: "Mail", note: "formal")]
        let memoryLine = lineOf(engine(cloud, nil))
        check("a note written for an app puts its name in the footnote of an engine whose Context is off, and in the line: memory only, no lines",
              footnotesOf(engine(cloud, nil)) == [notes] && footnotesOf(engine(anthropic, nil)) == [notes]
              && memoryLine.contains("Mail") && memoryLine.contains(Words.current.note) && !memoryLine.contains(Words.current.before(2)), memoryLine)
        model.settings.appProfiles = [profile("com.example.mail", name: "Mail", entries: rows), profile("com.example.chat", name: "Chat", note: "casual")]
        check("names written for an app count as memory too, and the footnote lists every app that has some, in profile order",
              footnotesOf(engine(cloud, nil)) == [String(localized: "Your notes and names for \(ListFormatter.localizedString(byJoining: ["Mail", "Chat"])) are sent too.")],
              "\(footnotesOf(engine(cloud, nil)))")
        model.settings.appProfiles = [profile("com.example.mail", name: "Mail", note: "formal")]
        check("with Context on, the footnote says both: the lines and the apps' memory",
              footnotesOf(engine(cloud, on3)) == [says, notes], "\(footnotesOf(engine(cloud, on3)))")
        model.settings.appProfiles = [profile("com.example.mail", name: "Mail", note: "formal", context: AppContextOverride(mode: .off))]
        check("an app whose context is off sends nothing, memory included: the footnote and the line say lines only",
              footnotesOf(engine(cloud, nil)).isEmpty && lineOf(engine(cloud, nil)) == lineOff)
        model.settings.appProfiles = [profile("com.example.mail", name: "Mail", note: "formal")]
        check("DeepL and an HTTP template send no memory without their own opt-in, so the footnote does not name the app",
              footnotesOf(engine(deepL, nil)).isEmpty && footnotesOf(engine(template, nil)).isEmpty)
        // Whether the memory of an app that names ANOTHER engine is disclosed here is the request path's rule (which engine is in front when a
        // lens covers that app), checked with the request path, so this file does not pin it either way. An app that names this one is
        // disclosed under every rule.
        let own = engine(cloud, nil)
        model.settings.appProfiles = [profile("com.example.mail", name: "Mail", note: "formal", engine: own.id)]
        check("an app that names this engine as its own has its memory disclosed to it", footnotesOf(own) == [notes], "\(footnotesOf(own))")
    }
#endif
}
