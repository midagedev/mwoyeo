import Foundation
import Testing
@testable import MwoyeoCore

/// "Memory only" (lead decision D1, 2026-10-19), nearby's line above (G8), the Memory sheet's edits and pin (G5), and the "Sent:"
/// summary (G17). The pure side of T3c; `ContextChecks` runs the same rules end to end through `TranslationService`.
@Suite struct MemoryOnlyTests {
    private let deepL = EngineKind.deepL(baseURL: URL(string: "https://api.deepl.com")!, formality: nil)
    private let template = EngineKind.httpTemplate(HTTPTemplate(url: "https://x.example.com", resultPath: "r"))
    private let command = EngineKind.command(CommandSpec(executable: "/bin/cat"))

    private func engine(_ kind: EngineKind, _ context: EngineContext? = nil) -> EngineConfig {
        EngineConfig(name: "E", kind: kind, context: context)
    }

    private func profile(note: String = "", entries: [MemoryEntry] = [], mode: AppContextOverride.Mode? = nil) -> AppProfile {
        AppProfile(bundleID: "com.example.chat", appName: "Chat", source: "ja", target: "ko", note: note, entries: entries,
                   context: mode.map { AppContextOverride(mode: $0) })
    }

    private let name = MemoryEntry(src: "田中", dst: "다나카", kind: .person, gender: .m)

    // MARK: when it applies

    @Test func theWrittenMemoryOfAnAppIsTheOptIn() {
        for kind in [CtxFix.openAI(), CtxFix.local, CtxFix.anthropic] {
            for p in [profile(note: "casual"), profile(entries: [name]), profile(note: "casual", entries: [name])] {
                let o = ContextOptions.memoryOnlyOptions(engine: engine(kind), profile: p)
                #expect(o?.enabled == true && o?.memoryOnly == true && o?.transcriptCount == 0, "\(kind)")
                #expect(o?.includeTitle == false && o?.includeLearned == false && o?.deepLInstructions == false && o?.longTranscript == false)
            }
        }
    }

    @Test func itAppliesToNothingElse() {
        let written = profile(note: "casual", entries: [name])
        #expect(ContextOptions.memoryOnlyOptions(engine: nil, profile: written) == nil)                              // Apple Translation
        #expect(ContextOptions.memoryOnlyOptions(engine: engine(deepL), profile: written) == nil)                    // its own opt-in
        #expect(ContextOptions.memoryOnlyOptions(engine: engine(template), profile: written) == nil)                 // owns its body
        #expect(ContextOptions.memoryOnlyOptions(engine: engine(command), profile: written) == nil)
        #expect(ContextOptions.memoryOnlyOptions(engine: engine(CtxFix.local), profile: nil) == nil)
        #expect(ContextOptions.memoryOnlyOptions(engine: engine(CtxFix.local), profile: profile()) == nil)          // nothing written
        #expect(ContextOptions.memoryOnlyOptions(engine: engine(CtxFix.local), profile: profile(note: "  \n ")) == nil)
        #expect(ContextOptions.memoryOnlyOptions(engine: engine(CtxFix.local), profile: profile(entries: [MemoryEntry(src: "x", dst: "")])) == nil)
    }

    /// The app's override of `off` turns it off too, whatever the app wrote and whatever the engine says.
    @Test func anOverrideOfOffSendsNothing() {
        let written = profile(note: "casual", entries: [name], mode: .off)
        for context in [nil, EngineContext(), EngineContext(enabled: true, previousLines: 4, includeTitle: true, useLearned: true)] {
            let o = ContextOptions.requestOptions(engine: engine(CtxFix.local, context), profile: written)
            #expect(o.enabled == false && o.memoryOnly == false, "\(String(describing: context))")
        }
    }

    @Test func theOtherSwitchesStillComeFirst() {
        let written = profile(note: "casual", entries: [name])
        // The engine's switch: the full context, not memory only.
        let on = ContextOptions.requestOptions(engine: engine(CtxFix.local, EngineContext(enabled: true, previousLines: 2)), profile: written)
        #expect(on.enabled && !on.memoryOnly && on.transcriptCount == 2)
        // The app's override: the same.
        for mode in [AppContextOverride.Mode.nearby, .conversation] {
            let o = ContextOptions.requestOptions(engine: engine(CtxFix.local), profile: profile(note: "casual", mode: mode))
            #expect(o.enabled && !o.memoryOnly, "\(mode)")
        }
        // Nothing switched on: memory only.
        #expect(ContextOptions.requestOptions(engine: engine(CtxFix.local), profile: written).memoryOnly)
        #expect(ContextOptions.requestOptions(engine: engine(CtxFix.local, EngineContext(enabled: false, useLearned: true)), profile: written).memoryOnly)
    }

    /// The default path: with no memory and Context off, the options are `ContextOptions()` for every engine kind and every
    /// way of having no memory. (`TranslationService` then takes today's path; the end-to-end bytes are in `ContextChecks`.)
    @Test func noMemoryAndContextOffIsOff() {
        let nothing: [AppProfile?] = [nil, profile(), profile(note: ""), profile(note: " \n"), profile(mode: nil)]
        for kind in [CtxFix.openAI(), CtxFix.local, CtxFix.anthropic, deepL, template, command] {
            for p in nothing {
                #expect(ContextOptions.requestOptions(engine: engine(kind), profile: p) == ContextOptions(), "\(kind)")
                #expect(ContextOptions.requestOptions(engine: engine(kind, EngineContext()), profile: p) == ContextOptions())
            }
        }
        #expect(ContextOptions.requestOptions(engine: nil, profile: profile(note: "casual", entries: [name])) == ContextOptions())
    }

    @Test func theWindowIsReadForAppsWithWrittenMemoryOnly() {
        let local = engine(CtxFix.local)
        #expect(!ContextOptions.memoryOnlyCouldApply(engine: local, profiles: []))
        #expect(!ContextOptions.memoryOnlyCouldApply(engine: local, profiles: [profile(), profile(note: "x", mode: .off)]))
        #expect(ContextOptions.memoryOnlyCouldApply(engine: local, profiles: [profile(), profile(note: "x")]))
        #expect(!ContextOptions.memoryOnlyCouldApply(engine: engine(deepL), profiles: [profile(note: "x")]))
        #expect(!ContextOptions.memoryOnlyCouldApply(engine: nil, profiles: [profile(note: "x")]))
        // Not "context could be on": the footnote about recent lines being sent stays true to its words.
        #expect(!ContextOptions.couldBeOn(engine: local, profiles: [profile(note: "x", entries: [name])]))
    }

    // MARK: what it sends

    private var memoryOnly: ContextOptions { ContextOptions(enabled: true, transcriptCount: 0, memoryOnly: true) }

    private func request() -> ContextRequest {
        var r = CtxFix.rich(items: ["田中は来た"], memory: [name, MemoryEntry(src: "山田", dst: "야마다", origin: .user),
                                                          MemoryEntry(src: "田中", dst: "다나카", origin: .learned)])
        r.above = ["上の行1", "上の行2"]
        return r
    }

    @Test func theCardTheNoteAndTheRowsAndNothingOfTheDocument() {
        let loud = ContextOptions(enabled: true, transcriptCount: 8, includeLearned: true, includeTitle: true, deepLInstructions: true,
                                  longTranscript: true, memoryOnly: true)
        for kind in [CtxFix.openAI(), CtxFix.local, CtxFix.anthropic] {
            for options in [memoryOnly, loud] {
                let body = RequestLayout.body(kind: kind, request: request(), options: options)
                let last = CtxFix.lastMessage(body)
                let system = CtxFix.systemText(body)
                #expect(last["memory"] as? [String] == ["田中 -> 다나카 (person, m)"], "\(kind)")
                #expect(last["context_before"] == nil && last["context_after"] == nil && last["referents"] == nil, "\(kind)")
                #expect(system.contains("Document: Messages (social).") && system.contains("User's note for this app: Close friends, casual chat."))
                let text = CtxFix.text(body)
                #expect(!text.contains("Alice Smith"), "the window title goes to no engine, on this Mac or not: \(kind)")
                for line in ["前の行1", "前の行2", "次の行", "上の行1", "上の行2"] { #expect(!text.contains(line), "\(line) \(kind)") }
                #expect(!text.contains("\"terms\""), "memory only does not ask for terms")
            }
        }
    }

    @Test func memoryOnlyOnTheFoundationModelsLayoutIsTheSame() {
        let text = CtxFix.text(RequestLayout.body(kind: .appleFoundationModels, request: request(), options: memoryOnly))
        #expect(text.contains("田中 -> 다나카") && text.contains("Document: Messages (social)"))
        #expect(!text.contains("Alice Smith") && !text.contains("前の行1") && !text.contains("次の行") && !text.contains("上の行1"))
    }

    @Test func theSelectedRowsAreTheUsersOwn() {
        let rows = RequestLayout.selectedRows(request: request(), options: memoryOnly, kind: LayoutKind.engine(CtxFix.local))
        #expect(rows.map(\.src) == ["田中"] && rows.allSatisfy { $0.origin == .user })
    }

    @Test func theSentLineHasNoTitleAndNoLines() {
        let line = RequestLayout.sentPreview(request: request(), options: memoryOnly, kind: LayoutKind.engine(CtxFix.local))
        #expect(line.hasPrefix("Sent: Messages · social · note") && line.contains("1 names"))
        #expect(!line.contains("lines") && !line.contains("Alice") && !line.contains("who's who"))
    }

    // MARK: nearby (G8)

    @Test func nearbySendsTheLinesAboveAndBelowAndNoEarlierLines() {
        let nearby = ContextOptions(enabled: true, transcriptCount: 0)
        var r = CtxFix.rich(items: ["現在の行"], before: [ContextLine(source: "古い行")], after: ["下1", "下2", "下3"])
        r.above = ["上1", "上2", "上3"]
        for kind in [CtxFix.openAI(), CtxFix.local, CtxFix.anthropic] {
            let last = CtxFix.lastMessage(RequestLayout.body(kind: kind, request: r, options: nearby))
            #expect(last["context_before"] as? [String] == ["上2", "上3"], "the two nearest lines above, nearest last: \(kind)")
            #expect(last["context_after"] as? [String] == ["下1", "下2"])
        }
        // A line that is itself being translated is not its own neighbour.
        r.above = ["上1", "現在の行"]
        #expect(CtxFix.lastMessage(RequestLayout.body(kind: CtxFix.local, request: r, options: nearby))["context_before"] as? [String] == ["上1"])
    }

    @Test func withEarlierLinesTheLinesAboveAreTheTailOfThem() {
        var r = CtxFix.rich(items: ["現在の行"], before: [ContextLine(source: "古い行"), ContextLine(source: "上2")], after: [])
        r.above = ["上1", "上2"]
        let talk = ContextOptions(enabled: true, transcriptCount: 2)
        #expect(CtxFix.lastMessage(RequestLayout.body(kind: CtxFix.local, request: r, options: talk))["context_before"] as? [String] == ["古い行", "上2"])
    }

    @Test func noLineAboveIsNoKey() {
        let nearby = ContextOptions(enabled: true, transcriptCount: 0)
        let r = CtxFix.rich(items: ["現在の行"], before: [ContextLine(source: "古い行")], after: ["下1"])
        let last = CtxFix.lastMessage(RequestLayout.body(kind: CtxFix.local, request: r, options: nearby))
        #expect(last["context_before"] == nil && last["context_after"] as? [String] == ["下1"])
    }

    // MARK: the options as a value

    @Test func memoryOnlyIsOffByDefaultAndReadLeniently() throws {
        #expect(ContextOptions().memoryOnly == false && ContextOptions.off.memoryOnly == false)
        #expect(try JSONDecoder().decode(ContextOptions.self, from: Data("{}".utf8)).memoryOnly == false)
        #expect(try JSONDecoder().decode(ContextOptions.self, from: Data(#"{"memoryOnly":"yes"}"#.utf8)).memoryOnly == false)
        let round = try JSONDecoder().decode(ContextOptions.self, from: JSONEncoder().encode(memoryOnly))
        #expect(round == memoryOnly)
    }

    // MARK: the user's edits (G18, G19)

    @Test func entriesAreAddedReplacedAndRemoved() {
        var p = profile()
        #expect(p.setEntry(name) == .saved && p.entries.map(\.src) == ["田中"])
        // The same source is the same row.
        #expect(p.setEntry(MemoryEntry(src: " 田中 ", dst: "타나카")) == .saved && p.entries.count == 1 && p.entries[0].dst == "타나카")
        // A row can change its source.
        #expect(p.setEntry(MemoryEntry(src: "山田", dst: "야마다"), replacing: "田中") == .saved && p.entries.map(\.src) == ["山田"])
        // Moving a row onto another row's source: the latest edit wins and the other goes.
        p.setEntry(name)
        #expect(p.entries.count == 2)
        #expect(p.setEntry(MemoryEntry(src: "田中", dst: "다나카 씨"), replacing: "山田") == .saved && p.entries.map(\.dst) == ["다나카 씨"])
        p.removeEntry(src: "田中")
        #expect(p.entries.isEmpty && !p.hasMemory)
        #expect(p.setEntry(MemoryEntry(src: "", dst: "x")) == .invalid && p.setEntry(MemoryEntry(src: "x", dst: "  ")) == .invalid && p.entries.isEmpty)
    }

    @Test func theSheetStopsAtTheCap() {
        var p = profile()
        for i in 0..<AppProfile.maxEntries { #expect(p.setEntry(MemoryEntry(src: "name\(i)", dst: "이름\(i)")) == .saved) }
        #expect(p.entries.count == AppProfile.maxEntries)
        #expect(p.setEntry(MemoryEntry(src: "one more", dst: "하나 더")) == .full && p.entries.count == AppProfile.maxEntries)
        // A row that is already there can still be edited when the sheet is full.
        #expect(p.setEntry(MemoryEntry(src: "name3", dst: "새 이름")) == .saved && p.entries.count == AppProfile.maxEntries)
    }

    @Test func aLearnedOriginIsMadeAUserRowByTheSheet() {
        var p = profile()
        p.setEntry(MemoryEntry(src: "Alice", dst: "앨리스", kind: .person, gender: .f, origin: .learned, uses: 5, lastSeen: Date()))
        #expect(p.entries.count == 1 && p.entries[0].origin == .user)
    }

    // MARK: pin (G5)

    @Test func aPinnedRowIsAUserRowOfTheProfileAndSurvivesTheFile() throws {
        let learned = MemoryEntry(src: "Alice", dst: "앨리스", kind: .person, gender: .f, origin: .learned, uses: 3, lastSeen: Date())
        var profiles = [profile(note: "casual", entries: [name])]
        #expect(AppProfiles.pin(learned, bundleID: "com.example.chat", appName: "Chat", creatingWith: pair, in: &profiles) == .pinned)
        #expect(profiles[0].entries.map(\.src) == ["田中", "Alice"] && profiles[0].entries.allSatisfy { $0.origin == .user })
        // Through the file's text and back: a user row with the pair fields.
        let data = try JSONEncoder().encode(profiles)
        let back = try JSONDecoder().decode([AppProfile].self, from: data)
        let row = try #require(back[0].entries.first { $0.src == "Alice" })
        #expect(row.origin == .user && row.dst == "앨리스" && row.kind == .person && row.gender == .f)
        #expect(!String(decoding: data, as: UTF8.self).contains("origin") && !String(decoding: data, as: UTF8.self).contains("uses"))
        // The memory of the translator follows the profile and has no learned row of the name any more.
        var memory = ContextMemory(profile: profiles[0])
        #expect(memory.user.map(\.src) == ["田中", "Alice"] && memory.learned.isEmpty)
        memory.forgetLearned()
    }

    private let pair = LanguageChoice(source: "en", target: "ko", customEngineID: nil)

    @Test func pinSaysWhatItDid() {
        let learned = MemoryEntry(src: "Alice", dst: "앨리스", origin: .learned)
        // 2026-10-21 (round nameslens, design names-and-context §3.2): an app without a profile used to answer `.noProfile` and stay without
        // one. A pin is an edit of the memory, and the first edit makes the profile (`AppProfiles.ensuring`), with the pair it is given.
        // Derivation: `.pinned` plus one new profile that holds the row and takes `pair`; a row that is gone makes no profile.
        var none: [AppProfile] = []
        #expect(AppProfiles.pin(learned, bundleID: "com.example.chat", appName: "Chat", creatingWith: pair, in: &none) == .pinned)
        #expect(none == [AppProfile(bundleID: "com.example.chat", appName: "Chat", source: "en", target: "ko", entries: [MemoryEntry(src: "Alice", dst: "앨리스")])])
        var gone: [AppProfile] = []
        #expect(AppProfiles.pin(nil, bundleID: "com.example.chat", appName: "Chat", creatingWith: pair, in: &gone) == .gone && gone.isEmpty)
        var profiles = [profile()]
        #expect(AppProfiles.pin(nil, bundleID: "com.example.chat", appName: "Chat", creatingWith: pair, in: &profiles) == .gone)
        // The user's own row for the source stays as it is.
        profiles = [profile(entries: [MemoryEntry(src: "alice", dst: "앨리")])]
        #expect(AppProfiles.pin(learned, bundleID: "com.example.chat", appName: "Chat", creatingWith: pair, in: &profiles) == .alreadyYours && profiles[0].entries[0].dst == "앨리")
        // A full sheet pins nothing.
        profiles = [profile(entries: (0..<AppProfile.maxEntries).map { MemoryEntry(src: "n\($0)", dst: "이름\($0)") })]
        #expect(AppProfiles.pin(learned, bundleID: "com.example.chat", appName: "Chat", creatingWith: pair, in: &profiles) == .full && profiles[0].entries.count == AppProfile.maxEntries)
        // The id a view derives from a source is the row's.
        #expect(MemoryEntry.id(forSource: " ＡＬＩＣＥ ") == learned.id && MemoryEntry.id(forSource: "Alice") == learned.id)
    }

    // MARK: "Sent:" (G17)

    @Test func theSummaryOfMemoryOnly() {
        let rows = [name, MemoryEntry(src: "山田", dst: "야마다")]
        let s = RequestLayout.sentSummary(options: memoryOnly, kind: LayoutKind.engine(CtxFix.local), engineName: "Local", appName: "Chat", domain: "social",
                                          note: "casual", rows: rows)
        #expect(s.mode == .memoryOnly && s.appName == "Chat" && s.domain == "social" && s.hasNote && s.names == 2)
        #expect(!s.windowTitle && s.linesBefore == 0 && s.linesAfter == 0 && !s.learned)
        // 2026-10-21 (round nameslens, design names-and-context §3.3, G15): the names of the line say whose they are. Derivation: two rows
        // of the app and no glossary pair are "2 this app" and no "all apps" part; the total stays 2, so "up to 2 names" is as it was.
        #expect(s.text == "Sent: Chat · social · note · up to 2 names (2 this app)")
    }

    /// 2026-10-21 (round nameslens, G15): the glossary's pairs are the names of all apps, whole on the context path, minus the pairs an
    /// included row of the app replaces. Derivation: 2 rows of the app + 3 pairs of which 田中 is replaced by the app's row = 2 + 2.
    @Test func theSummaryNamesTheScopesOfItsNames() {
        let glossary = [("田中", "다나카씨"), ("勇者", "용사"), ("魔王", "마왕")]
        let s = RequestLayout.sentSummary(options: memoryOnly, kind: LayoutKind.engine(CtxFix.local), appName: "Chat", rows: [name, MemoryEntry(src: "山田", dst: "야마다")],
                                          glossary: glossary)
        #expect(s.names == 2 && s.allApps == 2)
        #expect(s.text == "Sent: Chat · up to 4 names (2 this app, 2 all apps)")
        // The glossary alone, one pair: the singular, and no "this app" part.
        let alone = RequestLayout.sentSummary(options: memoryOnly, kind: LayoutKind.engine(CtxFix.local), appName: "Chat", glossary: [("勇者", "용사")])
        #expect(alone.text == "Sent: Chat · up to 1 name (1 all apps)")
        // Learned rows are of the app.
        var on = ContextOptions(enabled: true, transcriptCount: 0)
        on.includeLearned = true
        let learned = RequestLayout.sentSummary(options: on, kind: LayoutKind.engine(CtxFix.local), appName: "Chat",
                                                rows: [name, MemoryEntry(src: "Alice", dst: "앨리스", origin: .learned)], glossary: glossary)
        #expect(learned.text.contains("up to 4 names (2 this app, learned too, 2 all apps)"), "\(learned.text)")
        // Where the memory does not reach the request, neither does the glossary count: DeepL without its opt-in, Off.
        let deepL = LayoutKind.engine(.deepL(baseURL: URL(string: "https://api.deepl.com")!, formality: nil))
        #expect(RequestLayout.sentSummary(options: ContextOptions(enabled: true), kind: deepL, appName: "Chat", rows: [name], glossary: glossary).allApps == 0)
        #expect(RequestLayout.sentSummary(options: .off, kind: LayoutKind.engine(CtxFix.local), appName: "Chat", glossary: glossary).text == "Sent: lines only")
    }

    @Test func theSummaryOfContextAndOfOff() {
        let on = ContextOptions(enabled: true, transcriptCount: 3)
        let local = RequestLayout.sentSummary(options: on, kind: LayoutKind.engine(CtxFix.local), appName: "Chat", domain: nil, rows: [name])
        #expect(local.mode == .context && local.windowTitle && local.linesBefore == 3 && local.linesAfter == 2 && !local.hasNote)
        #expect(local.text == "Sent: Chat · window title · up to 1 name (1 this app) · 3 lines before · 2 lines after")
        // A cloud engine gets the title only with the opt-in.
        let cloud = RequestLayout.sentSummary(options: on, kind: LayoutKind.engine(CtxFix.anthropic), appName: "Chat", domain: nil)
        #expect(!cloud.windowTitle)
        var optIn = on
        optIn.includeTitle = true
        #expect(RequestLayout.sentSummary(options: optIn, kind: LayoutKind.engine(CtxFix.anthropic), appName: "Chat").windowTitle)
        // Nearby: the lines around the text.
        let nearby = RequestLayout.sentSummary(options: ContextOptions(enabled: true, transcriptCount: 0), kind: LayoutKind.engine(CtxFix.local), appName: "Chat")
        #expect(nearby.linesBefore == 2 && nearby.linesAfter == 2)
        // Off, and engines that own their body.
        #expect(RequestLayout.sentSummary(options: .off, kind: LayoutKind.engine(CtxFix.local), appName: "Chat", rows: [name]).text == "Sent: lines only")
        #expect(RequestLayout.sentSummary(options: on, kind: .engine(template), appName: "Chat", rows: [name]).mode == .linesOnly)
    }

    @Test func theSummaryCountsLearnedRowsOnlyWhenTheyAreOn() {
        let learned = MemoryEntry(src: "Alice", dst: "앨리스", origin: .learned)
        var on = ContextOptions(enabled: true, transcriptCount: 0)
        #expect(RequestLayout.sentSummary(options: on, kind: LayoutKind.engine(CtxFix.local), appName: "Chat", rows: [name, learned]).names == 1)
        on.includeLearned = true
        let with = RequestLayout.sentSummary(options: on, kind: LayoutKind.engine(CtxFix.local), appName: "Chat", rows: [name, learned])
        #expect(with.names == 2 && with.learned && with.text.contains("up to 2 names (2 this app, learned too)"))
    }

    @Test func theSummaryNeverHoldsText() {
        let secret = "SECRETNOTE"
        let s = RequestLayout.sentSummary(options: memoryOnly, kind: LayoutKind.engine(CtxFix.anthropic), appName: "Chat", note: secret,
                                          rows: [MemoryEntry(src: "SECRETSRC", dst: "SECRETDST")])
        #expect(!s.text.contains("SECRET") && s.hasNote)
    }
}
