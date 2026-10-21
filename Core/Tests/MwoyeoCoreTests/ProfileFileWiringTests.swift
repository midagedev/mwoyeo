import Foundation
import Testing
@testable import MwoyeoCore

/// Round prof-file (R3, 2026-10-21): what the settings file, the context plan and the preview ask of Core (design names-and-context
/// §4.2, §5.2, §10): the `memory` mode, the chain's hint rows, the replace rows of a chain, the lines a request sends against the lines
/// it chooses its hints on, the 1.1.4 shape, and the glossary's share of the preview. Each case says what it failed on before.
@Suite struct ProfileFileWiringTests {
    private func profile(_ id: String, entries: [MemoryEntry] = [], note: String = "", context: AppContextOverride? = nil) -> AppProfile {
        AppProfile(bundleID: id, appName: id, source: "ja", target: "ko", note: note, entries: entries, context: context)
    }

    private func chain(_ profiles: [AppProfile], apply: EntryApply = .hint, glossary: [GlossaryPair] = []) -> MergedChain {
        ProfileChain.merge(profiles.map { .profile($0) } + [.allApps], base: ChainBase(glossary: glossary, glossaryApply: apply))
    }

    // MARK: the memory mode

    /// FAIL-first: before `Mode.memory` the case did not exist ("a mode this build does not know" read as no override).
    @Test func theMemoryModeIsTheMemoryAmountAndRoundTrips() throws {
        let memory = AppContextOverride(mode: .memory)
        #expect(ContextAmount(memory) == .memory && !ContextAmount(memory).sendsLines)
        let data = try JSONEncoder().encode(memory)
        #expect(String(decoding: data, as: UTF8.self).contains("\"memory\""))
        #expect(try JSONDecoder().decode(AppContextOverride.self, from: data).mode == .memory)
        // The old layer reads it as the card, the note and the names and nothing of the screen.
        let resolved = ContextOptions.resolved(base: ContextOptions(), override: memory)
        #expect(resolved.enabled && resolved.memoryOnly && resolved.transcriptCount == 0)
        // A profile that says `memory` while All apps says `conversation` is on `memory`: the narrowest sets it.
        let merged = ProfileChain.merge([.profile(profile("a", context: memory)), .allApps],
                                        base: ChainBase(amount: .conversation(3)))
        #expect(merged.amount == .memory)
    }

    // MARK: hint rows or a note (design §4.2's memory row)

    /// FAIL-first: `hasMemory` counted a `replace` row, so a chain of replace rows alone sent a memory-only request with no names in it.
    @Test func aReplaceRowAloneIsNoMemoryToSend() {
        let replace = MemoryEntry(src: "勇者", dst: "용사", apply: .replace)
        let hint = MemoryEntry(src: "魔王", dst: "마왕")
        let both = MemoryEntry(src: "村人", dst: "무라", apply: .both)
        #expect(!chain([profile("a", entries: [replace])]).hasMemory)
        #expect(chain([profile("a", entries: [replace, hint])]).hasMemory)
        #expect(chain([profile("a", entries: [both])]).hasMemory)
        #expect(chain([profile("a", entries: [replace], note: "casual")]).hasMemory)
        let engine = EngineConfig(name: "E", kind: .openAICompatible(baseURL: URL(string: "http://localhost:1/v1")!, model: "m", thinking: .off, extraHeaders: [:]))
        #expect(ContextOptions.requestOptions(engine: engine, chain: chain([profile("a", entries: [replace])])) == .off)
        #expect(ContextOptions.requestOptions(engine: engine, chain: chain([profile("a", entries: [hint])])).memoryOnly)
    }

    // MARK: the replace rows of a chain (design §10)

    /// The default path: no row says replace and the glossary is a hint, so nothing is written into any source.
    @Test func noReplaceRowIsTheDefaultPath() {
        let hint = MemoryEntry(src: "勇者", dst: "용사")
        #expect(ContextMemory.replaceRows(chain: chain([profile("a", entries: [hint])], glossary: [GlossaryPair(src: "魔王", dst: "마왕")])).isEmpty)
        #expect(ContextMemory.replaceRows(chain: chain([])).isEmpty)
    }

    @Test func theChainsReplaceRowsGoNarrowFirstThenTheGlossaryItLacks() {
        let narrow = MemoryEntry(src: "勇者", dst: "용사님", apply: .both)
        let broad = MemoryEntry(src: "勇者", dst: "용사", apply: .replace)
        let other = MemoryEntry(src: "魔王", dst: "마왕", apply: .replace)
        let head = profile("head", entries: [narrow])
        let base = profile("base", entries: [broad, other])
        let rows = ContextMemory.replaceRows(chain: chain([head, base], apply: .both,
                                                          glossary: [GlossaryPair(src: "勇者", dst: "전역 용사"), GlossaryPair(src: "村人", dst: "무라")]))
        #expect(rows.map(\.src) == ["勇者", "魔王", "村人"])
        #expect(rows.map(\.dst) == ["용사님", "마왕", "무라"])
        #expect(rows.last?.apply == .both && rows.last?.origin == .user)
    }

    // MARK: the lines a request sends and the lines it chooses its hints on (design §10)

    /// FAIL-first: `RequestLayout.selectRows` matches a row on `request.items`. A request built with the rewritten text as its items
    /// (the first idea) has no row for 勇者, which the rewrite replaced: "both" would have been "replace" in the body.
    @Test func aRewrittenLineStillGetsItsHintRow() throws {
        let both = MemoryEntry(src: "勇者", dst: "용사", kind: .person, apply: .both)
        let on = ContextOptions(enabled: true)
        let original = "勇者が来た"
        var request = ContextRequest(items: [original], memory: [both], target: "ko")
        request.rewritten = ["용사가 来た"]
        let body = RequestLayout.body(kind: CtxFix.local, request: request, options: on)
        let message = CtxFix.lastMessage(body)
        #expect(message["memory"] as? [String] == ["勇者 -> 용사 (person)"])
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("용사가 来た") && !text.contains(original))
        // The first idea, as a witness: rewriting first loses the hint.
        let first = ContextRequest(items: ["용사가 来た"], memory: [both], target: "ko")
        #expect(CtxFix.lastMessage(RequestLayout.body(kind: CtxFix.local, request: first, options: on))["memory"] == nil)
        // No rewrite sends the items, as every request did.
        #expect(ContextRequest(items: [original], target: "ko").sent == [original])
    }

    // MARK: the 1.1.4 shape (design §5.2)

    @Test func theOldShapeIsWhatOnly114Said() throws {
        func legacy(_ json: String) throws -> LegacySettings { try JSONDecoder().decode(LegacySettings.self, from: Data(json.utf8)) }
        let engine = #"{"id":"00000000-0000-0000-0000-0000000000A1","name":"E","kind":"deepL","baseURL":"https://api.deepl.com"}"#
        #expect(try legacy("{}").isOldShape == false)
        #expect(try legacy(#"{"appProfiles":[]}"#).isOldShape)
        #expect(try legacy(#"{"appleUsesPinnedTerms":false}"#).isOldShape)
        #expect(try legacy(#"{"engines":[\#(engine)]}"#).isOldShape == false)
        let withContext = #"{"id":"00000000-0000-0000-0000-0000000000A1","name":"E","kind":"deepL","baseURL":"https://api.deepl.com","context":{"enabled":true}}"#
        #expect(try legacy(#"{"engines":[\#(withContext)]}"#).isOldShape)
        // `profiles` makes it the new shape, whatever else the file holds; the engine's `allow` is kept, not rebuilt from the old context.
        let hybrid = try legacy(#"{"profiles":[],"appProfiles":[{"bundleID":"a.b","source":"ja","target":"ko"}]}"#)
        #expect(!hybrid.isOldShape && ProfileMigration.convert(hybrid).value.profiles.isEmpty)
        // The mode of a row is `MemoryEntry.apply`, the one owner: it survives the file shape and an old file's rows come out hint.
        let file = ProfileFile(id: "p", name: "P", source: "ja", target: "ko",
                               entries: [MemoryEntry(src: "勇者", dst: "용사", apply: .both), MemoryEntry(src: "魔王", dst: "마왕")])
        let again = try JSONDecoder().decode(ProfileFile.self, from: JSONEncoder().encode(file))
        #expect(again.entries.map(\.apply) == [.both, .hint])
        // One bad row is skipped, not the profile's rows.
        let lossy = try JSONDecoder().decode(ProfileFile.self, from: Data(#"{"id":"p","name":"P","entries":[{"src":"a"},{"src":"勇者","dst":"용사","apply":"replace"}]}"#.utf8))
        #expect(lossy.entries.map(\.src) == ["勇者"] && lossy.entries.first?.apply == .replace)
    }

    // MARK: the preview (design §3)

    /// FAIL-first: `allApps` counted the whole glossary (20 here), though only the pairs that occur go, within the one row cap.
    @Test func theGlossaryCountsWithinTheRowCapAndNotWhenItIsReplaced() {
        let kind = LayoutKind.engine(CtxFix.local)
        let rows = (0..<3).map { MemoryEntry(src: "名前\($0)", dst: "이름\($0)", kind: .person) }
        let pairs = (0..<20).map { ("語\($0)", "말\($0)") }
        let s = RequestLayout.sentSummary(options: ContextOptions(enabled: true, memoryOnly: true), kind: kind, appName: "Chat", rows: rows, glossary: pairs)
        let cap = ContextBudget.for(.local).maxRows
        #expect(s.names == 3 && s.allApps == cap - 3 && s.names + s.allApps == cap)
        let replaced = RequestLayout.sentSummary(options: ContextOptions(enabled: true, memoryOnly: true), kind: kind, appName: "Chat", rows: rows,
                                                 glossary: pairs, glossaryApply: .replace)
        #expect(replaced.allApps == 0 && replaced.names == 3)
        // A short glossary counts whole, as before.
        let few = RequestLayout.sentSummary(options: ContextOptions(enabled: true, memoryOnly: true), kind: kind, appName: "Chat", rows: rows,
                                            glossary: Array(pairs.prefix(2)))
        #expect(few.allApps == 2)
    }
}
