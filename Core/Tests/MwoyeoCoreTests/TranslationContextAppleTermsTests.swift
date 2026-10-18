import Foundation
import Testing
@testable import MwoyeoCore

/// The pinned names and terms put into the source before Apple Translation sees it (design §9, choice (a)). The cases follow the
/// measured patch `~/.cache/mwoyeo-gates/glossary-preinsert/glossary-root.patch` (en>ko/ja/zh, 2026-10-18); the answers'
/// side (`accepts`) is not ported, so none of these look at an answer.
@Suite struct TranslationContextAppleTermsTests {
    private let ko: [MemoryEntry] = [("token", "토큰"), ("model", "모델"), ("loss", "손실"), ("layer", "계층"), ("attention head", "어텐션 헤드"),
                                     ("Aldric", "알드릭"), ("route", "루트"), ("map", "맵"), ("speed", "스피드")]
        .map { MemoryEntry(src: $0.0, dst: $0.1, kind: .term) }

    private func insert(_ source: String, _ entries: [MemoryEntry]? = nil, on: Bool = true) -> ApplePreinsertion {
        ApplePreinsertion.insert(into: source, entries: entries ?? ko, appleUsesPinnedTerms: on)
    }

    // MARK: the flag

    @Test func theFlagIsOffByDefaultAndOffMeansTheInputUntouched() {
        let source = "We split the text into tokens before feeding it to the model."
        // The default: no argument at all.
        let byDefault = ApplePreinsertion.insert(into: source, entries: ko)
        #expect(byDefault.text == source && byDefault.source == source && byDefault.isEmpty && byDefault.spans.isEmpty)
        // Explicitly off, with every entry a user entry that matches.
        let off = insert(source, on: false)
        #expect(off.text == source && off.isEmpty && off.targets.isEmpty)
    }

    @Test func theFlagOnPutsAPinnedNameIn() {
        let g = insert("We split the text into tokens before feeding it to the model.")
        #expect(g.text == "We split the text into 토큰 before feeding it to the 모델.")
        #expect(g.targets == ["토큰", "모델"] && !g.isEmpty)
        #expect(g.source == "We split the text into tokens before feeding it to the model.")
        #expect(insert("Aldric said nothing.").text == "알드릭 said nothing.")
    }

    @Test func onlyUserEntriesGoIn() {
        let learned = MemoryEntry(src: "token", dst: "토큰", origin: .learned)
        #expect(insert("A token.", [learned]).text == "A token.")
        let pinned = MemoryEntry(src: "token", dst: "토큰", origin: .user)
        #expect(insert("A token.", [learned, pinned]).text == "A 토큰.")
    }

    @Test func aSourceWithNoTermIsAskedAsItIs() {
        let g = insert("The weather is fine.")
        #expect(g.isEmpty && g.text == g.source && g.spans.isEmpty)
        #expect(insert("The model is fine.", []).text == "The model is fine.")
    }

    // MARK: the spans

    @Test func spansSayWhereEachTargetStandsInUTF16Units() {
        let g = insert("🙂 Plan the route map.")
        #expect(g.text == "🙂 Plan the 루트 맵.")
        #expect(g.spans.map(\.matched) == ["route", "map"] && g.spans.map(\.target) == ["루트", "맵"])
        let ns = g.text as NSString
        for s in g.spans { #expect(ns.substring(with: NSRange(location: s.range.lowerBound, length: s.range.count)) == s.target) }
        // The plural is part of what matched.
        let plural = insert("All layers were shuffled.")
        #expect(plural.spans.map(\.matched) == ["layers"] && plural.text == "All 계층 were shuffled.")
    }

    // MARK: matching (from the measured patch)

    @Test func aTermAtTheStartOfASentenceMatchesWithACapital() {
        #expect(insert("Loss is computed over the whole batch.").text == "손실 is computed over the whole batch.")
        // an entry written with a capital is not matched in lowercase
        #expect(insert("aldric said nothing.").isEmpty)
    }

    @Test func aPluralBelongsToTheTerm() {
        #expect(insert("All layers were shuffled.").text == "All 계층 were shuffled.")
        #expect(insert("Both models use boxes.", ko + [MemoryEntry(src: "box", dst: "상자")]).text == "Both 모델 use 상자.")
        #expect(insert("The modeling is fine.").isEmpty)
    }

    @Test func aLatinTermMatchesWholeWordsOnly() {
        #expect(insert("The tokenizer and the premodel stay.").isEmpty)
        #expect(insert("A token-level loss.").text == "A 토큰-level 손실.")
        #expect(insert("The model's loss is high.").text == "The 모델's 손실 is high.")
    }

    @Test func aTermInAnotherScriptMatchesWhereverItStands() {
        let g = insert("東京タワーは高い。", [MemoryEntry(src: "東京", dst: "도쿄"), MemoryEntry(src: "タワー", dst: "타워")])
        #expect(g.text == "도쿄타워は高い。" && g.targets == ["도쿄", "타워"])
    }

    @Test func theLongestTermWinsAndNothingIsReplacedTwice() {
        let g = insert("Each attention head reads the head of the list.", ko + [MemoryEntry(src: "head", dst: "머리")])
        #expect(g.text == "Each 어텐션 헤드 reads the 머리 of the list." && g.targets == ["어텐션 헤드", "머리"])
        // a target that holds another term is not looked at again
        let loop = [MemoryEntry(src: "model", dst: "모델"), MemoryEntry(src: "모델", dst: "model")]
        #expect(insert("The model reads the model card.", loop).text == "The 모델 reads the 모델 card.")
        // two entries as long as each other that overlap: the first one given wins
        let tie = [MemoryEntry(src: "東京", dst: "도쿄"), MemoryEntry(src: "京都", dst: "교토")]
        #expect(insert("東京都", tie).text == "도쿄都")
        #expect(insert("東京都", tie.reversed()).text == "東교토")
    }

    @Test func anEntryWhoseTermIsItsTargetIsIgnored() {
        #expect(insert("The softmax output.", [MemoryEntry(src: "softmax", dst: "softmax")]).isEmpty)
    }

    @Test func twoTermsNextToEachOtherKeepTheirOrder() {
        let g = insert("Plan the route map.")
        #expect(g.text == "Plan the 루트 맵." && g.targets == ["루트", "맵"])
    }

    @Test func pinnedEntriesFromAnAppProfileGoIn() {
        let profile = AppProfile(bundleID: "a.b", appName: "A", source: "en", target: "ko",
                                 entries: [MemoryEntry(src: "Aldric", dst: "알드릭", kind: .person), MemoryEntry(src: "keep", dst: "성채")])
        #expect(ApplePreinsertion.insert(into: "Aldric holds the keep.", entries: profile.entries, appleUsesPinnedTerms: true).text == "알드릭 holds the 성채.")
        #expect(ApplePreinsertion.insert(into: "Aldric holds the keep.", entries: profile.entries).text == "Aldric holds the keep.")
    }
}
