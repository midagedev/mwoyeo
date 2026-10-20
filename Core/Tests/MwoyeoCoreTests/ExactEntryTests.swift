import Foundation
import Testing
@testable import MwoyeoCore

/// A line that is only a name or a term is that row's translation, without asking the engine (mem-hints, 2026-10-20), and the one rule for
/// which rows a request sends (`ContextMemory.sendable`) that `RequestLayout.prepare` and the exact entry share. `ContextChecks` runs the
/// same through `TranslationService` with the engine behind a mock.
@Suite struct ExactEntryTests {
    private let tsukumo = MemoryEntry(src: "九十九", dst: "츠쿠모", kind: .person)
    private let suzanne = MemoryEntry(src: "シュザンヌ", dst: "쉬잔", kind: .person)
    private let shrine = MemoryEntry(src: "月影の祠", dst: "월영 사당", kind: .term)
    private let mia = MemoryEntry(src: "Mia", dst: "미아", kind: .person)
    private func learned(_ src: String, _ dst: String) -> MemoryEntry { MemoryEntry(src: src, dst: dst, kind: .term, origin: .learned) }

    private var rows: [MemoryEntry] { [tsukumo, suzanne, shrine, mia] }

    // MARK: the line

    @Test func aLineThatIsExactlyTheSourceIsTheTranslation() {
        #expect(ContextMemory.exactTranslation(of: "シュザンヌ", in: rows) == "쉬잔")
        #expect(ContextMemory.exactTranslation(of: "月影の祠", in: rows) == "월영 사당")
        #expect(ContextMemory.exactTranslation(of: "  九十九  ", in: rows) == "츠쿠모")
        #expect(ContextMemory.exactTranslation(of: "九十九\n", in: rows) == "츠쿠모")
    }

    /// The marks a name plate carries are taken off to compare and put back around the translation, so the plate keeps its look.
    @Test func plateMarksAreTrimmedToCompareAndKeptAroundTheTranslation() {
        #expect(ContextMemory.exactTranslation(of: "「シュザンヌ」", in: rows) == "「쉬잔」")
        #expect(ContextMemory.exactTranslation(of: "【九十九】", in: rows) == "【츠쿠모】")
        #expect(ContextMemory.exactTranslation(of: "シュザンヌ:", in: rows) == "쉬잔:")
        #expect(ContextMemory.exactTranslation(of: "シュザンヌ：", in: rows) == "쉬잔：")
        #expect(ContextMemory.exactTranslation(of: "『月影の祠』 ", in: rows) == "『월영 사당』")
        #expect(ContextMemory.exactTranslation(of: "［ 九十九 ］", in: rows) == "［ 츠쿠모 ］")
        #expect(ContextMemory.exactTranslation(of: "\"Mia\"", in: rows) == "\"미아\"")
    }

    /// A line that holds the name among other words is the engine's.
    @Test func aLineThatOnlyContainsTheNameIsNotMatched() {
        for line in ["九十九、お前こそ剣を落とすなよ", "シュザンヌ様", "月影の祠の番人", "九十九九", "九十九 and Mia", "Mia's", "Miami", "ここが月影の祠よ。", "九十九。"] {
            #expect(ContextMemory.exactTranslation(of: line, in: rows) == nil, "\(line)")
        }
        // The marks come off the ends only: a name that continues inside the line is another name.
        #expect(ContextMemory.exactTranslation(of: "シュザンヌ・ド・リュミエール", in: rows) == nil)
        #expect(ContextMemory.exactTranslation(of: "九十九「シュザンヌ」", in: rows) == nil)
        #expect(ContextMemory.exactTranslation(of: "「九十九」と「シュザンヌ」", in: rows) == nil)
    }

    @Test func aNameWithItsOwnDotsAndMarksIsMatchedAsWritten() {
        let long = MemoryEntry(src: "シュザンヌ・ド・リュミエール", dst: "쉬잔 드 뤼미에르", kind: .person)
        let company = MemoryEntry(src: "（株）", dst: "주식회사", kind: .term)
        let all = rows + [long, company]
        #expect(ContextMemory.exactTranslation(of: "シュザンヌ・ド・リュミエール", in: all) == "쉬잔 드 뤼미에르")
        #expect(ContextMemory.exactTranslation(of: "【シュザンヌ・ド・リュミエール】", in: all) == "【쉬잔 드 뤼미에르】")
        // The source's own marks are its own: the line as written wins, and nothing is put back around it.
        #expect(ContextMemory.exactTranslation(of: "（株）", in: all) == "주식회사")
        #expect(ContextMemory.exactTranslation(of: "シュザンヌ", in: all) == "쉬잔")
    }

    /// The sheet's identity decides what is the same name: case, accents and width are ignored, as `MemoryEntry.id` does for `pin`.
    @Test func caseAndWidthAreIgnoredLikeTheSheetDoes() {
        #expect(ContextMemory.exactTranslation(of: "MIA", in: rows) == "미아")
        #expect(ContextMemory.exactTranslation(of: "mia", in: rows) == "미아")
        #expect(ContextMemory.exactTranslation(of: "Ｍｉａ", in: rows) == "미아")          // full-width Latin
        #expect(ContextMemory.exactTranslation(of: "【ＭＩＡ】", in: rows) == "【미아】")
        let wide = MemoryEntry(src: "ＡＢＣ商会", dst: "ABC 상회", kind: .org)             // the row written in full-width Latin
        #expect(ContextMemory.exactTranslation(of: "ABC商会", in: [wide]) == "ABC 상회")
        let accent = MemoryEntry(src: "Zoë", dst: "조에", kind: .person)
        #expect(ContextMemory.exactTranslation(of: "ZOE", in: [accent]) == "조에")
    }

    /// Two rows of one source (a request's rows are a plain list): the user's wins over a learned one, whichever comes first.
    @Test func aLearnedRowLosesToAnAppEntry() {
        let hint = learned("九十九", "구십구")
        #expect(ContextMemory.exactTranslation(of: "九十九", in: [hint, tsukumo]) == "츠쿠모")
        #expect(ContextMemory.exactTranslation(of: "九十九", in: [tsukumo, hint]) == "츠쿠모")
        #expect(ContextMemory.exactTranslation(of: "九十九", in: [hint]) == "구십구")
    }

    @Test func nothingMatchesNothing() {
        #expect(ContextMemory.exactTranslation(of: "", in: rows) == nil)
        #expect(ContextMemory.exactTranslation(of: "   ", in: rows) == nil)
        #expect(ContextMemory.exactTranslation(of: "「」", in: rows) == nil)
        #expect(ContextMemory.exactTranslation(of: "九十九", in: []) == nil)
        #expect(ContextMemory.exactTranslation(of: "ハク", in: rows) == nil)
        // A row without a translation is not a row (`sendable` drops it before it gets here); the function alone does not serve an empty one.
        let hollow = MemoryEntry(src: "ハク", dst: "", kind: .person)
        #expect(ContextMemory.exactTranslation(of: "ハク", in: ContextMemory.sendable([hollow], glossary: [], includeUser: true, includeLearned: true)) == nil)
    }

    // MARK: which rows a request sends

    @Test func sendableIsTheRuleOfPrecedence() {
        let hint = learned("九十九", "구십구"), other = learned("ハク", "하쿠"), gl = learned("魔王", "마왕")
        let glossary = [("魔王", "마왕님")]
        // All on: the learned row of an app entry's source and the learned row of a glossary term are not sent.
        let all = ContextMemory.sendable([tsukumo, hint, other, gl, suzanne], glossary: glossary, includeUser: true, includeLearned: true)
        #expect(all.map(\.src) == ["九十九", "ハク", "シュザンヌ"])
        #expect(all.first { $0.src == "九十九" }?.dst == "츠쿠모")
        // Learned rows are the options' switch (and Memory only turns it off).
        #expect(ContextMemory.sendable([tsukumo, other], glossary: [], includeUser: true, includeLearned: false).map(\.src) == ["九十九"])
        // User rows are theirs.
        #expect(ContextMemory.sendable([tsukumo, other], glossary: [], includeUser: false, includeLearned: true).map(\.src) == ["ハク"])
        // A row with no source or no translation is no row.
        #expect(ContextMemory.sendable([MemoryEntry(src: "x", dst: ""), tsukumo], glossary: [], includeUser: true, includeLearned: true).map(\.src) == ["九十九"])
    }

    /// The layout and the exact entry read the same rule: what `prepare` may pick from is what `exactRows` serves from.
    @Test func theLayoutPicksFromTheRowsTheExactEntryServesFrom() {
        let hint = learned("九十九", "구십구"), other = learned("ハク", "하쿠"), gl = learned("魔王", "마왕")
        let memory = [tsukumo, hint, other, gl, suzanne]
        let glossary = [("魔王", "마왕님")]
        let items = ["九十九", "ハク", "魔王", "シュザンヌ"]
        for options in [CtxFix.on, ContextOptions(enabled: true, includeLearned: true, memoryOnly: true), ContextOptions(enabled: true),
                        ContextOptions(enabled: true, includeUser: false, includeLearned: true)] {
            let request = CtxFix.rich(items: items, memory: memory, glossary: glossary)
            let kind = LayoutKind.engine(CtxFix.local)
            let served = RequestLayout.exactRows(request: request, options: options, kind: kind)
            let picked = RequestLayout.selectedRows(request: request, options: options, kind: kind)
            #expect(picked.allSatisfy { p in served.contains { $0.id == p.id && $0.origin == p.origin && $0.dst == p.dst } }, "\(options)")
            #expect(Set(served.map(\.id)) == Set(picked.map(\.id)), "\(options)")
        }
    }

    // MARK: where the memory reaches the request

    @Test func exactRowsAreEmptyWhereTheMemoryDoesNotReachTheRequest() {
        let request = CtxFix.rich(items: ["九十九"], memory: rows)
        let local = LayoutKind.engine(CtxFix.local)
        #expect(RequestLayout.exactRows(request: request, options: ContextOptions(enabled: true), kind: local).count == rows.count)
        // Off.
        #expect(RequestLayout.exactRows(request: request, options: .off, kind: local).isEmpty)
        // A kind without context: an HTTP template or a command owns its body.
        let template = EngineKind.httpTemplate(HTTPTemplate(url: "https://x.example.com", resultPath: "r"))
        #expect(RequestLayout.exactRows(request: request, options: ContextOptions(enabled: true), kind: .engine(template)).isEmpty)
        // DeepL takes the memory only through its own opt-in.
        let deepL = LayoutKind.engine(.deepL(baseURL: URL(string: "https://api.deepl.com")!, formality: nil))
        #expect(RequestLayout.exactRows(request: request, options: ContextOptions(enabled: true), kind: deepL).isEmpty)
        #expect(RequestLayout.exactRows(request: request, options: ContextOptions(enabled: true, deepLInstructions: true), kind: deepL).count == rows.count)
        // Apple's on-device model carries the rows in its instructions.
        #expect(RequestLayout.exactRows(request: request, options: ContextOptions(enabled: true), kind: .appleFoundationModels).count == rows.count)
    }

    @Test func memoryOnlyServesTheUserRowsAndNothingLearned() {
        let memory = rows + [learned("ハク", "하쿠")]
        let request = CtxFix.rich(items: ["ハク"], memory: memory)
        let local = LayoutKind.engine(CtxFix.local)
        let memoryOnly = ContextOptions(enabled: true, includeLearned: true, memoryOnly: true)
        #expect(ContextMemory.exactTranslation(of: "ハク", in: RequestLayout.exactRows(request: request, options: memoryOnly, kind: local)) == nil)
        #expect(ContextMemory.exactTranslation(of: "九十九", in: RequestLayout.exactRows(request: request, options: memoryOnly, kind: local)) == "츠쿠모")
        let learning = ContextOptions(enabled: true, includeLearned: true)
        #expect(ContextMemory.exactTranslation(of: "ハク", in: RequestLayout.exactRows(request: request, options: learning, kind: local)) == "하쿠")
    }
}
