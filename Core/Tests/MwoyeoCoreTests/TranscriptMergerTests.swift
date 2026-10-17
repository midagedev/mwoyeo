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
