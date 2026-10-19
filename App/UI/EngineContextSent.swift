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

    /// The words of the "Sent:" line, in the app's language. The fields come from `SentSummary`; an app's name and its category word are
    /// already in the language.
    struct Words {
        var sent: (String) -> String
        var linesOnly: String
        var windowTitle: String
        var note: String
        var names: (Int) -> String
        var namesLearned: (Int) -> String
        var before: (Int) -> String
        var after: (Int) -> String

        @MainActor static var current: Words {
            Words(sent: { String(localized: "Sent: \($0)") }, linesOnly: String(localized: "lines only"),
                  windowTitle: String(localized: "window title"), note: String(localized: "note"),
                  names: { String(localized: "up to \($0) names") }, namesLearned: { String(localized: "up to \($0) names (learned too)") },
                  before: { String(localized: "\($0) lines before") }, after: { String(localized: "\($0) lines after") })
        }
    }

    /// The line for `summary` in `words`: the app and its category, the window title, the note, the names, the lines before and after,
    /// in the order Core's English line (`SentSummary.text`) gives them; "lines only" when nothing but the lines to translate goes.
    static func said(_ summary: SentSummary, in words: Words) -> String {
        var parts: [String] = []
        if let app = summary.appName { parts.append(summary.domain.map { "\(app) · \($0)" } ?? app) }
        if summary.windowTitle { parts.append(words.windowTitle) }
        if summary.hasNote { parts.append(words.note) }
        if summary.names > 0 { parts.append(summary.learned ? words.namesLearned(summary.names) : words.names(summary.names)) }
        if summary.linesBefore > 0 { parts.append(words.before(summary.linesBefore)) }
        if summary.linesAfter > 0 { parts.append(words.after(summary.linesAfter)) }
        return words.sent(parts.isEmpty ? words.linesOnly : parts.joined(separator: " · "))
    }

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
        let words = Words(sent: { "S[\($0)]" }, linesOnly: "LO", windowTitle: "WT", note: "NOTE", names: { "N\($0)" }, namesLearned: { "L\($0)" },
                          before: { "B\($0)" }, after: { "A\($0)" })
        func engine(_ kind: EngineKind, _ context: EngineContext?) -> EngineConfig {
            var e = EngineConfig(name: "Sent check", kind: kind)
            e.context = context
            return e
        }
        func marked(_ kind: EngineKind, _ context: EngineContext?) -> String {
            said(ContextPreview.engineSummary(engine: engine(kind, context), profiles: [], category: { _ in nil }), in: words)
        }
        let saved = model.settings.appProfiles
        defer { model.settings.appProfiles = saved }
        model.settings.appProfiles = []

        // The words.
        check("Off says lines only, for every kind, whatever the other switches hold",
              [cloud, local, anthropic, deepL].allSatisfy { marked($0, nil) == "S[LO]" && marked($0, offKept) == "S[LO]" }, marked(cloud, offKept))
        check("On says the sample app and its category, the lines before and the lines after",
              marked(cloud, on3) == "S[Example Chat · social · B3 · A2]" && marked(anthropic, EngineContext(enabled: true, previousLines: 0)) == "S[Example Chat · social · B2 · A2]",
              "\(marked(cloud, on3)) | \(marked(anthropic, EngineContext(enabled: true, previousLines: 0)))")
        check("the window title is in the line only where the request would carry it: the local server always, a cloud engine on opt-in",
              marked(local, on3).contains("WT") && !marked(cloud, on3).contains("WT") && !marked(deepL, on3).contains("WT")
              && marked(cloud, EngineContext(enabled: true, previousLines: 3, includeTitle: true)).contains("WT"),
              "\(marked(local, on3)) | \(marked(cloud, on3))")
        let full = SentSummary(mode: .context, appName: "Mail", domain: "email", windowTitle: true, hasNote: true, names: 3, linesBefore: 4, linesAfter: 2)
        var learned = full
        learned.learned = true
        check("every field of a summary has its word, in the order of Core's English line, and the line says only the fields that are set",
              said(full, in: words) == "S[Mail · email · WT · NOTE · N3 · B4 · A2]" && said(learned, in: words) == "S[Mail · email · WT · NOTE · L3 · B4 · A2]"
              && said(SentSummary(mode: .memoryOnly, appName: "Mail", hasNote: true), in: words) == "S[Mail · NOTE]"
              && said(SentSummary(mode: .linesOnly), in: words) == "S[LO]")

        // The line and the footnote of the sheet.
        let lineOff = line(for: engine(cloud, nil), in: model)
        let lineOn = line(for: engine(cloud, on3), in: model)
        check("the line the sheet shows follows the switches: lines only when off, the sample app and the lines when on",
              lineOff == Words.current.sent(Words.current.linesOnly) && lineOn != lineOff && lineOn.contains("Example Chat"), "\(lineOff) → \(lineOn)")
        let says = String(localized: "Recent lines are sent too, for context.")
        check("the footnote says that lines go along when the engine's context can be on, and nothing when it cannot be",
              footnotes(for: engine(cloud, on3), in: model) == [says] && footnotes(for: engine(cloud, nil), in: model).isEmpty
              && footnotes(for: engine(template, on3), in: model).isEmpty)

        // Memory only (D1): the apps that wrote a note or names are named, with Context off.
        func profile(_ id: String, name: String, note: String = "", entries: [MemoryEntry] = [], engine: UUID? = nil, context: AppContextOverride? = nil) -> AppProfile {
            AppProfile(bundleID: id, appName: name, source: "ja", target: "ko", customEngineID: engine, note: note, entries: entries, context: context)
        }
        let rows = [MemoryEntry(src: "先輩", dst: "선배", kind: .term)]
        let notes = String(localized: "Your notes and names for \(ListFormatter.localizedString(byJoining: ["Mail"])) are sent too.")
        model.settings.appProfiles = [profile("com.example.mail", name: "Mail", note: "formal")]
        let memoryLine = line(for: engine(cloud, nil), in: model)
        check("a note written for an app puts its name in the footnote of an engine whose Context is off, and in the line: memory only, no lines",
              footnotes(for: engine(cloud, nil), in: model) == [notes] && footnotes(for: engine(anthropic, nil), in: model) == [notes]
              && memoryLine.contains("Mail") && memoryLine.contains(Words.current.note) && !memoryLine.contains(Words.current.before(2)), memoryLine)
        model.settings.appProfiles = [profile("com.example.mail", name: "Mail", entries: rows), profile("com.example.chat", name: "Chat", note: "casual")]
        check("names written for an app count as memory too, and the footnote lists every app that has some, in profile order",
              footnotes(for: engine(cloud, nil), in: model) == [String(localized: "Your notes and names for \(ListFormatter.localizedString(byJoining: ["Mail", "Chat"])) are sent too.")],
              "\(footnotes(for: engine(cloud, nil), in: model))")
        model.settings.appProfiles = [profile("com.example.mail", name: "Mail", note: "formal")]
        check("with Context on, the footnote says both: the lines and the apps' memory",
              footnotes(for: engine(cloud, on3), in: model) == [says, notes], "\(footnotes(for: engine(cloud, on3), in: model))")
        model.settings.appProfiles = [profile("com.example.mail", name: "Mail", note: "formal", context: AppContextOverride(mode: .off))]
        check("an app whose context is off sends nothing, memory included: the footnote and the line say lines only",
              footnotes(for: engine(cloud, nil), in: model).isEmpty && line(for: engine(cloud, nil), in: model) == lineOff)
        model.settings.appProfiles = [profile("com.example.mail", name: "Mail", note: "formal")]
        check("DeepL and an HTTP template send no memory without their own opt-in, so the footnote does not name the app",
              footnotes(for: engine(deepL, nil), in: model).isEmpty && footnotes(for: engine(template, nil), in: model).isEmpty)
        // Whether the memory of an app that names ANOTHER engine is disclosed here is the request path's rule (which engine is in front when a
        // lens covers that app), checked with the request path, so this file does not pin it either way. An app that names this one is
        // disclosed under every rule.
        let own = engine(cloud, nil)
        model.settings.appProfiles = [profile("com.example.mail", name: "Mail", note: "formal", engine: own.id)]
        check("an app that names this engine as its own has its memory disclosed to it", footnotes(for: own, in: model) == [notes], "\(footnotes(for: own, in: model))")
    }
#endif
}
