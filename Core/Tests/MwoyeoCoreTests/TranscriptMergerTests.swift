import Foundation
import Testing
@testable import MwoyeoCore

@Suite struct TranscriptMergerTests {
    typealias Entry = TranscriptRecorder.Entry
    typealias Cue = TranscriptRecorder.Cue

    private func entry(_ t: TimeInterval, _ s: String) -> TranscriptRecorder.TranscriptEvent { .entry(Entry(time: t, source: s, translation: "t:" + s)) }
    private func cue(_ a: TimeInterval, _ b: TimeInterval, _ s: String) -> TranscriptRecorder.TranscriptEvent {
        .cue(Cue(start: a, end: b, source: s, translation: "t:" + s))
    }

    private let fragment = "Patch 1.4 finally fixed the double jump bug. What else are you hoping"
    private let whole = "Patch 1.4 finally fixed the double jump bug. What else are you hoping they fix next?"

    @Test func fullerReadingReplacesTheFragmentHeldBeforeIt() {
        var m = TranscriptMerger(hold: 3)
        #expect(m.add([entry(1, fragment)], now: 1).isEmpty)
        #expect(m.add([entry(2, whole)], now: 2).isEmpty)
        let out = m.add([], now: 6)
        #expect(out == [Entry(time: 1, source: whole, translation: "t:" + whole)])
    }

    @Test func aLineTranslatedDifferentlyWhileHeldIsWrittenOnceWithTheNewerTranslation() {
        // D13 (2026-10-21): the same source again, with another translation, within the hold: one entry, the newer translation, the first time.
        var m = TranscriptMerger(hold: 3)
        _ = m.add([entry(1, "Controls and noise.")], now: 1)
        _ = m.add([.entry(Entry(time: 2, source: "Controls and noise.", translation: "대조군 및 소음."))], now: 2)
        #expect(m.finish() == [Entry(time: 1, source: "Controls and noise.", translation: "대조군 및 소음.")])
    }

    @Test func aLineTranslatedDifferentlyAfterItWasWrittenIsWrittenAgain() {
        var m = TranscriptMerger(hold: 3)
        _ = m.add([entry(1, "Controls and noise.")], now: 1)
        #expect(m.add([], now: 5) == [Entry(time: 1, source: "Controls and noise.", translation: "t:Controls and noise.")])
        _ = m.add([.entry(Entry(time: 6, source: "Controls and noise.", translation: "대조군 및 소음."))], now: 6)
        #expect(m.add([], now: 10) == [Entry(time: 6, source: "Controls and noise.", translation: "대조군 및 소음.")])
    }

    @Test func theRecorderAndTheMergerTogetherLogTheEffectOfAChangeOnALineThatNeverLeft() {
        // What `TranscriptWriter` does: the recorder's events go through the merger once a second, and the entries come out after the hold.
        var r = TranscriptRecorder()
        var m = TranscriptMerger(hold: 3)
        var written: [Entry] = []
        let controls = TranscriptRecorder.Observed(source: "Controls and noise.", translation: "제어 및 소음.", inLens: true)
        let fixed = TranscriptRecorder.Observed(source: "Controls and noise.", translation: "대조군 및 소음.", inLens: true)
        for t in 0..<20 {
            written += m.add(r.observe(time: Double(t), lines: [t < 8 ? controls : fixed]), now: Double(t))
        }
        written += m.add(r.finish(time: 20), now: 20) + m.finish()
        #expect(written.map(\.translation) == ["제어 및 소음.", "대조군 및 소음."])
        #expect(written.map(\.time) == [0, 8])
        #expect(m.cues.map(\.translation) == ["대조군 및 소음."])
    }

    @Test func aFragmentArrivingAfterTheWholeIsDropped() {
        var m = TranscriptMerger(hold: 3)
        _ = m.add([entry(1, whole)], now: 1)
        _ = m.add([entry(1.5, "they fix next?")], now: 1.5)
        #expect(m.finish() == [Entry(time: 1, source: whole, translation: "t:" + whole)])
    }

    @Test func punctuationAndSpacingDoNotMakeANewLine() {
        var m = TranscriptMerger(hold: 3)
        _ = m.add([entry(1, "Use the lure and be patient - it took me forty minutes.")], now: 1)
        _ = m.add([entry(2, "Use the lure and be patient it took me forty minutes")], now: 2)
        #expect(m.finish().count == 1)
    }

    @Test func similarShortLabelsStaySeparate() {
        var m = TranscriptMerger(hold: 3)
        _ = m.add([entry(1, "1h ago"), entry(1, "11h ago"), entry(1, "Best"), entry(1, "Best of the week")], now: 1)
        #expect(m.finish().map(\.source) == ["1h ago", "11h ago", "Best", "Best of the week"])
    }

    @Test func entriesComeOutInFirstSeenOrderOnceHeldLongEnough() {
        var m = TranscriptMerger(hold: 3)
        _ = m.add([entry(0, "alpha line one")], now: 0)
        _ = m.add([entry(1, "bravo line two")], now: 1)
        #expect(m.add([], now: 3).map(\.source) == ["alpha line one"])
        #expect(m.add([entry(3.5, "charlie line three")], now: 4.5).map(\.source) == ["bravo line two"])
        #expect(m.finish().map(\.source) == ["charlie line three"])
    }

    @Test func cuesOfTheVariantsFoldIntoOneAndStaySorted() {
        var m = TranscriptMerger(hold: 3)
        _ = m.add([entry(1, fragment), entry(2, whole)], now: 2)
        _ = m.add([cue(1, 3, fragment)], now: 14)
        _ = m.add([cue(2, 9, whole)], now: 20)
        #expect(m.cues == [Cue(start: 1, end: 9, source: whole, translation: "t:" + whole)])
        _ = m.add([cue(0.5, 1, "Another line entirely")], now: 21)
        #expect(m.cues.map(\.start) == [0.5, 1])
    }

    @Test func theSameTextAMinuteLaterIsAnotherCue() {
        var m = TranscriptMerger(hold: 3)
        _ = m.add([cue(1, 3, "5h ago"), cue(60, 62, "5h ago")], now: 70)
        #expect(m.cues.count == 2)
    }
}
