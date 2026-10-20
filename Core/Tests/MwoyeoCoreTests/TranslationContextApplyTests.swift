import Foundation
import Testing
@testable import MwoyeoCore

/// Design names-and-context §3 (matching, the cap, "Apart", hint and replace) and §10: a row's `apply` mode, the replace rows,
/// the hint cap, `reading` as a second key, glossary hits and the row-cost helper.
@Suite struct TranslationContextApplyTests {
    private let on = ContextOptions(enabled: true)

    // MARK: apply (design §10)

    @Test func applyIsHintByDefaultAndWrittenOnlyWhenItIsNot() throws {
        let hint = MemoryEntry(src: "token", dst: "토큰")
        #expect(hint.apply == .hint)
        // The settings file keeps today's bytes: a hint row has no `apply` key.
        let hintJSON = String(decoding: try JSONEncoder().encode(hint), as: UTF8.self)
        #expect(!hintJSON.contains("\"apply\""))
        for mode in [EntryApply.replace, .both] {
            var row = hint
            row.apply = mode
            let data = try JSONEncoder().encode(row)
            #expect(String(decoding: data, as: UTF8.self).contains("\"apply\":\"\(mode.rawValue)\""))
            #expect(try JSONDecoder().decode(MemoryEntry.self, from: data) == row)
        }
        // Missing, unknown and unreadable values all read as hint, and never lose the row.
        for data in [Data(#"{"src":"a","dst":"b"}"#.utf8),
                     Data(#"{"src":"a","dst":"b","apply":"future"}"#.utf8),
                     Data(#"{"src":"a","dst":"b","apply":3}"#.utf8)] {
            let row = try JSONDecoder().decode(MemoryEntry.self, from: data)
            #expect(row.apply == .hint && row.src == "a" && row.dst == "b")
        }
    }

    // MARK: replaceRows (design §3 "Hint and replace", §10)

    @Test func replaceRowsTakesReplaceAndBothUserRowsOnly() {
        let hint = MemoryEntry(src: "hint", dst: "a", origin: .user)
        let replace = MemoryEntry(src: "replace", dst: "b", origin: .user, apply: .replace)
        let both = MemoryEntry(src: "both", dst: "c", origin: .user, apply: .both)
        let learned = MemoryEntry(src: "learned", dst: "d", origin: .learned, apply: .both)
        let rows = [hint, replace, both, learned]
        #expect(ContextMemory.replaceRows(rows: rows, glossary: [], glossaryApply: .hint).map(\.src) == ["replace", "both"])
        // The row cap is a hint rule: ten replace rows all come back.
        let many = (0..<10).map { MemoryEntry(src: "r\($0)", dst: "x\($0)", origin: .user, apply: .replace) }
        #expect(ContextMemory.replaceRows(rows: many, glossary: [], glossaryApply: .hint).count == 10)
    }

    @Test func replaceRowsAppendsTheGlossaryPairsTheRowsLackWhenItsModeIsNotHint() {
        let hint = MemoryEntry(src: "勇者", dst: "용사", origin: .user)
        let replace = MemoryEntry(src: "魔王", dst: "마왕", origin: .user, apply: .replace)
        let rows = [hint, replace]
        // Hint mode: no glossary pair leaves the hint path.
        #expect(ContextMemory.replaceRows(rows: rows, glossary: [("村人", "무라")], glossaryApply: .hint).map(\.src) == ["魔王"])
        // Replace/both mode: a pair joins unless a row (hint included) already has its folded source.
        for mode in [EntryApply.replace, .both] {
            let merged = ContextMemory.replaceRows(rows: rows, glossary: [("勇者", "다른 용사"), ("村人", "무라")], glossaryApply: mode)
            #expect(merged.map(\.src) == ["魔王", "村人"])
            #expect(merged.last?.kind == .term && merged.last?.origin == .user && merged.last?.apply == mode)
        }
        // One source is one row, whatever its case and width.
        let deduped = ContextMemory.replaceRows(rows: [], glossary: [("token", "토큰"), ("TOKEN", "다른 토큰")], glossaryApply: .replace)
        #expect(deduped.count == 1 && deduped.first?.dst == "토큰")
    }

    /// Apple takes no hints: `applePins` is the replace merge with every user row included, and it keeps today's rows as they are.
    @Test func applePinsIsTheReplaceMergeWithEveryUserRow() {
        let learned = MemoryEntry(src: "learned", dst: "d", origin: .learned)
        let hint = MemoryEntry(src: "token", dst: "앱의 토큰")
        let replace = MemoryEntry(src: "model", dst: "모델", origin: .user, apply: .replace)
        let pinned = ContextMemory.applePins(appRows: [hint, replace, learned], glossary: [("token", "전역의 토큰"), ("moon", "달")])
        #expect(pinned.map(\.src) == ["token", "model", "moon"])
        #expect(pinned.first?.apply == .hint && pinned[1].apply == .replace)
        // The pairs are created with the default mode: today's calls compare the whole row (App/Support/ContextChecks).
        #expect(pinned.last?.apply == .hint && pinned.last?.kind == .term)
    }

    // MARK: hint selection and the cap (design §3)

    @Test func hintSelectionNeverSendsAReplaceRowAndBothGoesAsAHint() {
        let replace = MemoryEntry(src: "アリス", dst: "앨리스", kind: .person, apply: .replace)
        let both = MemoryEntry(src: "田中", dst: "다나카", kind: .person, apply: .both)
        let hint = MemoryEntry(src: "ボブ", dst: "밥", kind: .person)
        let rows = [replace, both, hint]
        let selected = RequestLayout.selectRows(rows, items: ["アリスと田中とボブ"], surrounding: [], budget: .for(.cloud), format: .line)
        #expect(selected.map(\.src) == ["ボブ", "田中"])
        // The request's body carries neither the replace row nor the both row as its hint form.
        let request = ContextRequest(items: ["アリスと田中"], memory: [replace, both], target: "ko")
        let body = RequestLayout.body(kind: CtxFix.local, request: request, options: on)
        #expect(CtxFix.lastMessage(body)["memory"] as? [String] == ["田中 -> 다나카 (person)"])
        // A both row is also a replace row, beside the plain replace row.
        #expect(ContextMemory.replaceRows(rows: rows, glossary: [], glossaryApply: .hint).map(\.src) == ["アリス", "田中"])
    }

    @Test func theRowCapIsEightForCloudAndLocalAndFourForAppleFM() {
        #expect(ContextBudget.for(.cloud).maxRows == 8 && ContextBudget.for(.local).maxRows == 8 && ContextBudget.for(.appleFM).maxRows == 4)
        // Twelve item hits, ordered by uses; the cap takes the first eight for cloud and local, four for Apple FM.
        let rows = (0..<12).map { i in MemoryEntry(src: String(format: "r%02d", i), dst: "x\(i)", kind: .term, origin: .user, uses: 11 - i) }
        let text = rows.map(\.src).joined(separator: " ")
        func selected(_ tier: ContextTier) -> [String] {
            RequestLayout.selectRows(rows, items: [text], surrounding: [], budget: .for(tier), format: .line).map(\.src)
        }
        #expect(selected(.cloud) == ["r00", "r01", "r02", "r03", "r04", "r05", "r06", "r07"])
        #expect(selected(.local) == ["r00", "r01", "r02", "r03", "r04", "r05", "r06", "r07"])
        #expect(selected(.appleFM) == ["r00", "r01", "r02", "r03"])
        // The cap follows the order rather than the input.
        let reversed = Array(rows.reversed())
        #expect(RequestLayout.selectRows(reversed, items: [text], surrounding: [], budget: .for(.cloud), format: .line).map(\.src)
                == ["r00", "r01", "r02", "r03", "r04", "r05", "r06", "r07"])
    }

    @Test func absentApplySelectsExactlyTodaysRows() {
        let rows = [CtxFix.alice, CtxFix.bob, CtxFix.tanaka, CtxFix.skill]
        let explicit = rows.map { row -> MemoryEntry in var r = row; r.apply = .hint; return r }
        let items = ["アリスは来た", "ボブも"]
        let surrounding = ["田中が言った"]
        let absent = RequestLayout.selectRows(rows, items: items, surrounding: surrounding, budget: .for(.cloud), format: .line)
        let stated = RequestLayout.selectRows(explicit, items: items, surrounding: surrounding, budget: .for(.cloud), format: .line)
        #expect(absent == stated)
        // Today's rule: item hits and person speakers, the non-hit term left out.
        #expect(Set(absent.map(\.src)) == ["アリス", "ボブ", "田中"])
    }

    // MARK: reading (design §3)

    @Test func readingIsASecondMatchKey() {
        let ku = MemoryEntry(src: "九十九", dst: "츠쿠모", kind: .place, reading: "つくも")
        let selected = RequestLayout.selectRows([ku], items: ["つくもに着いた"], surrounding: [], budget: .for(.cloud), format: .line)
        #expect(selected.map(\.src) == ["九十九"])
        // The source still matches, and a reading never matches in another row's place.
        #expect(RequestLayout.selectRows([ku], items: ["九十九に着いた"], surrounding: [], budget: .for(.cloud), format: .line).count == 1)
        #expect(RequestLayout.selectRows([ku], items: ["雨が降る"], surrounding: [], budget: .for(.cloud), format: .line).isEmpty)
    }

    // MARK: glossary hits (design §3 "Apart")

    @Test func glossaryPairsLeaveTheRulesAndJoinMemoryOnlyWhenTheTextHasThem() {
        let glossary = [("勇者", "용사"), ("魔王", "마왕"), ("村人", "무라")]
        let request = CtxFix.rich(items: ["勇者と魔王"], memory: [], glossary: glossary)
        let body = RequestLayout.body(kind: CtxFix.local, request: request, options: on)
        let system = CtxFix.systemText(body)
        #expect(!system.contains("勇者 → 용사") && !system.contains("glossary"))
        #expect(CtxFix.lastMessage(body)["memory"] as? [String] == ["勇者 -> 용사 (term)", "魔王 -> 마왕 (term)"])
        // A glossary whose pairs never occur changes no byte: only hits go.
        let absent = CtxFix.rich(items: ["勇者と魔王"], memory: [], glossary: [("村人", "무라")])
        #expect(RequestLayout.body(kind: CtxFix.local, request: absent, options: on)
                == RequestLayout.body(kind: CtxFix.local, request: CtxFix.rich(items: ["勇者と魔王"], memory: [], glossary: []), options: on))
        // The same rule on the Apple Foundation Models prompt: rows, not instructions.
        let fm = CtxFix.json(RequestLayout.body(kind: .appleFoundationModels, request: request, options: on))
        #expect(!(fm["instructions"] as? String ?? "").contains("勇者 → 용사"))
        #expect((fm["prompt"] as? String ?? "").contains("勇者 -> 용사 (term)"))
    }

    // MARK: row cost (design §10)

    @Test func hintCostIsTheRenderedRowPlusOne() {
        for row in [CtxFix.alice, CtxFix.tanaka, CtxFix.skill] {
            #expect(ContextMemory.hintCost(row) == approxTokens(RequestLayout.renderLine(row)) + 1)
        }
        // The budget counts the same number.
        let cost = ContextMemory.hintCost(CtxFix.alice)
        var budget = ContextBudget.for(.cloud)
        budget.rowTokens = cost
        budget.maxRows = 8
        #expect(RequestLayout.selectRows([CtxFix.alice, CtxFix.bob], items: ["アリスとボブ"], surrounding: [], budget: budget, format: .line)
                .map(\.src) == ["アリス"])
    }

    // MARK: the cache key (lead, 2026-10-21)

    /// A row whose `apply` changes is a different request for Apple (replace writes into the source), so the memory's fingerprint, the
    /// translation-memory namespace, changes with it; a memory without replace rows keeps the fingerprint it had before `apply` existed.
    @Test func fingerprintFollowsApplyAndKeepsTodaysForHintRows() {
        let hint = ContextMemory(note: "casual", entries: [CtxFix.alice])
        var both = CtxFix.alice
        both.apply = .both
        #expect(ContextMemory(note: "casual", entries: [both]).memoryFingerprint != hint.memoryFingerprint)
        #expect(!hint.memoryFingerprint.contains("apply="))
    }
}
