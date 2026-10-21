import Foundation
import Testing
@testable import MwoyeoCore

@Suite struct TranscriptTests {
    typealias Obs = TranscriptRecorder.Observed
    typealias Event = TranscriptRecorder.TranscriptEvent

    private func line(_ s: String = "Hello", _ t: String? = "안녕", inLens: Bool = true) -> [Obs] {
        [Obs(source: s, translation: t, inLens: inLens)]
    }

    private func run(_ r: inout TranscriptRecorder, _ times: [TimeInterval], _ lines: [Obs]) -> [Event] {
        times.flatMap { r.observe(time: $0, lines: lines) }
    }

    private func entries(_ e: [Event]) -> [TranscriptRecorder.Entry] {
        e.compactMap { if case let .entry(x) = $0 { x } else { nil } }
    }

    private func cues(_ e: [Event]) -> [TranscriptRecorder.Cue] {
        e.compactMap { if case let .cue(x) = $0 { x } else { nil } }
    }

    @Test func heldSubtitleMakesOneEntryAndOneCue() {
        var r = TranscriptRecorder()
        let times = (0...40).map { 100 + Double($0) / 10 }
        var ev = run(&r, times, line())
        ev += r.finish(time: 104)
        #expect(entries(ev).count == 1)
        #expect(entries(ev)[0].time == 100)
        let c = cues(ev)
        #expect(c.count == 1)
        #expect(c[0].start == 100)
        #expect(c[0].end == times.last!)
    }

    @Test func goneTwelveSecondsThenBackIsTwoLines() {
        var r = TranscriptRecorder()
        var ev = run(&r, [0, 1], line())
        ev += run(&r, [2, 8, 13], [])
        ev += run(&r, [14, 15], line())
        ev += r.finish(time: 15)
        #expect(entries(ev).map(\.time) == [0, 14])
        let c = cues(ev)
        #expect(c.map(\.start) == [0, 14])
        #expect(c.map(\.end) == [1, 15])
    }

    @Test func goneThreeSecondsThenBackContinues() {
        var r = TranscriptRecorder()
        var ev = run(&r, [0, 1], line())
        ev += run(&r, [2, 3], [])
        ev += run(&r, [4, 5], line())
        ev += r.finish(time: 5)
        #expect(entries(ev).count == 1)
        let c = cues(ev)
        #expect(c.count == 1)
        #expect(c[0].start == 0)
        #expect(c[0].end == 5)
    }

    @Test func lateTranslationKeepsAppearanceAsCueStart() {
        var r = TranscriptRecorder()
        var ev = r.observe(time: 5, lines: line("Hi", nil))
        ev += r.observe(time: 5.25, lines: line("Hi", nil))
        ev += r.observe(time: 5.5, lines: line("Hi", "안녕"))
        ev += r.observe(time: 6, lines: line("Hi", "안녕하세요"))
        ev += r.finish(time: 6)
        // 2026-10-21 (D13): the entries were [5.5 안녕] only; a line that stays and is translated differently is written again (below).
        #expect(entries(ev) == [.init(time: 5.5, source: "Hi", translation: "안녕"), .init(time: 6, source: "Hi", translation: "안녕하세요")])
        #expect(cues(ev) == [.init(start: 5, end: 6, source: "Hi", translation: "안녕하세요")])
    }

    @Test func aLineThatStaysAndIsTranslatedDifferentlyIsWrittenAgainOnceAndItsCueKeepsTheLastTranslation() {
        // film3, 2026-10-21 (D13): "Controls and noise." was read, then the script went on, and the lens showed 대조군 for the line that never left it;
        // the log had only the first translation.
        var r = TranscriptRecorder()
        var ev = run(&r, [0, 1], line("Controls", "제어"))
        ev += run(&r, [2, 3, 4], line("Controls", "대조군"))
        ev += r.finish(time: 4)
        #expect(entries(ev) == [.init(time: 0, source: "Controls", translation: "제어"), .init(time: 2, source: "Controls", translation: "대조군")])
        #expect(cues(ev) == [.init(start: 0, end: 4, source: "Controls", translation: "대조군")])
    }

    @Test func aTranslationThatReturnsToTheFirstOneIsAnotherEntryAndTheSameTranslationAgainIsNot() {
        var r = TranscriptRecorder()
        var ev = run(&r, [0, 1], line("Hi", "안녕"))
        ev += run(&r, [2, 3], line("Hi", "여보세요"))
        ev += run(&r, [4, 5], line("Hi", "안녕"))
        ev += run(&r, [6, 7], line("Hi", "안녕"))
        #expect(entries(ev).map(\.translation) == ["안녕", "여보세요", "안녕"])
    }

    @Test func aTranslationThatBecomesTheSourceOrEmptyIsNotAnEntryAndDoesNotForgetTheLastOne() {
        var r = TranscriptRecorder()
        var ev = run(&r, [0], line("Hi", "안녕"))
        ev += run(&r, [1], line("Hi", "Hi"))
        ev += run(&r, [2], line("Hi", ""))
        ev += run(&r, [3], line("Hi", "안녕"))
        #expect(entries(ev).map(\.translation) == ["안녕"])
    }

    @Test func translationEqualToSourceWritesNothing() {
        var r = TranscriptRecorder()
        var ev = run(&r, [0, 1, 2], line("OK", "OK"))
        ev += run(&r, [3], line("Empty", ""))
        ev += r.finish(time: 3)
        #expect(ev.isEmpty)
    }

    @Test func overscanOnlyTextWritesNothing() {
        var r = TranscriptRecorder()
        var ev = run(&r, [0, 1, 20], line(inLens: false))
        ev += r.finish(time: 20)
        #expect(ev.isEmpty)
    }

    @Test func leavingTheLensButStayingInOverscanClosesTheCue() {
        var r = TranscriptRecorder()
        var ev = run(&r, [0, 1], line())
        ev += run(&r, [5, 10], line(inLens: false))
        #expect(cues(ev).isEmpty)
        ev += run(&r, [12], line(inLens: false))
        #expect(cues(ev) == [.init(start: 0, end: 1, source: "Hello", translation: "안녕")])
    }

    @Test func finishFlushesOpenCuesSortedByStart() {
        var r = TranscriptRecorder()
        _ = r.observe(time: 1, lines: line("B", "비"))
        _ = r.observe(time: 2, lines: line("B", "비") + line("A", "에이"))
        let c = cues(r.finish(time: 3))
        #expect(c.map(\.source) == ["B", "A"])
        #expect(c.map(\.end) == [2, 2])
        #expect(r.finish(time: 4).isEmpty)
    }

    @Test func srtCueFormatsExactly() {
        let cue = TranscriptRecorder.Cue(start: 103.12, end: 105.48, source: "Hello", translation: "안녕")
        #expect(TranscriptFormat.srtCue(index: 7, cue: cue, origin: 100, track: .source)
            == "7\n00:00:03,120 --> 00:00:05,480\nHello\n\n")
        #expect(TranscriptFormat.srtCue(index: 7, cue: cue, origin: 100, track: .translation)
            == "7\n00:00:03,120 --> 00:00:05,480\n안녕\n\n")
    }

    @Test func srtClampsNegativeStartAndShortCues() {
        let cue = TranscriptRecorder.Cue(start: 99, end: 99.1, source: "a", translation: "b")
        #expect(TranscriptFormat.srtCue(index: 1, cue: cue, origin: 100, track: .source)
            == "1\n00:00:00,000 --> 00:00:00,300\na\n\n")
        let short = TranscriptRecorder.Cue(start: 2, end: 2, source: "a", translation: "b")
        #expect(TranscriptFormat.srtCue(index: 2, cue: short, origin: 0, track: .source)
            == "2\n00:00:02,000 --> 00:00:02,300\na\n\n")
    }

    @Test func srtFormatsNinetyMinutes() {
        let cue = TranscriptRecorder.Cue(start: 5400, end: 5401.5, source: "a", translation: "b")
        #expect(TranscriptFormat.srtCue(index: 1, cue: cue, origin: 0, track: .source)
            == "1\n01:30:00,000 --> 01:30:01,500\na\n\n")
    }

    @Test func markdownEntryQuotesEverySourceLine() {
        let tz = TimeZone(identifier: "UTC")!
        let start = Date(timeIntervalSince1970: 0)
        let e = TranscriptRecorder.Entry(time: 3725, source: "line1\nline2", translation: "번역")
        #expect(TranscriptFormat.markdownEntry(e, start: start, timeZone: tz)
            == "**01:02:05**\n> line1\n> line2\n번역\n\n")
        #expect(TranscriptFormat.markdownHeader(lens: "Lens", date: start, timeZone: tz)
            == "## Lens · 1970-01-01 00:00\n\n")
    }

    @Test func linesSeenTogetherCloseInTheOrderTheyWereGiven() {
        var r = TranscriptRecorder()
        let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel"]
        let lines = words.map { Obs(source: $0, translation: "t-\($0)", inLens: true) }
        var ev = run(&r, [0, 1, 2], lines)
        ev += r.finish(time: 2)
        #expect(cues(ev).map(\.source) == words)
        #expect(entries(ev).map(\.source) == words)
    }

    @Test func jsonlLineIsOneObjectWithTheAgreedKeys() throws {
        let utc = TimeZone(identifier: "UTC")!
        let line = TranscriptFormat.jsonlLine(time: Date(timeIntervalSince1970: 1_760_000_000.123), timeZone: utc, lens: "Chat", app: "com.example.app",
                                              source: "ja", target: "ko", engine: "apple", original: "こんにちは\n\"世界\"/", translation: "안녕\n\"세계\"")
        #expect(line.hasSuffix("}\n") && line.dropLast().contains("\n") == false)
        #expect(line.hasPrefix("{\"time\":\"2025-10-09T08:53:20.123Z\",\"lens\":\"Chat\",\"app\":\"com.example.app\",\"source\":\"ja\",\"target\":\"ko\",\"engine\":\"apple\",\"original\":"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(object["original"] as? String == "こんにちは\n\"世界\"/" && object["translation"] as? String == "안녕\n\"세계\"")
        #expect(object.count == 8)
    }

    @Test func jsonlLineHasNullWhenTheAppIsUnknown() throws {
        let line = TranscriptFormat.jsonlLine(time: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "Asia/Seoul")!, lens: "L", app: nil,
                                              source: "auto", target: "en", engine: "Ollama", original: "a", translation: "b")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(object["app"] is NSNull && object["time"] as? String == "1970-01-01T09:00:00.000+09:00")
    }

    // MARK: the memory of a line (design names-and-context §2.2, §7; round agents)

    private func chain(_ names: [(String, String)] = [], reading: String? = nil) -> MergedChain {
        let rows = names.map { MemoryEntry(src: $0.0, dst: $0.1, kind: .person, reading: reading) }
        let anime = AppProfile(bundleID: "com.example.emu", appName: "Anime", source: "ja", target: "ko", entries: rows, id: "anime")
        return ProfileChain.merge([.profile(anime), .allApps], base: ChainBase())
    }

    @Test func aLineWithMemoryHasProfileAfterAppAndNamesAtTheEnd() throws {
        let memory = TranscriptMemory(original: "ハクは来た", chain: chain([("ハク", "하쿠"), ("花", "하나")]))
        let line = TranscriptFormat.jsonlLine(time: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!, lens: "L", app: "com.example.emu",
                                              source: "ja", target: "ko", engine: "apple", original: "ハクは来た", translation: "하쿠는 왔다", memory: memory)
        #expect(line.contains("\"app\":\"com.example.emu\",\"profile\":\"anime\",\"source\":\"ja\""))
        #expect(line.hasSuffix("\"names\":[[\"ハク\",\"하쿠\",\"anime\"]]}\n"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(object.count == 10 && object["names"] as? [[String]] == [["ハク", "하쿠", "anime"]])
    }

    @Test func aLineWithNoRowInItHasNoNamesKeyAndNoMemoryNoKeyAtAll() throws {
        let plain = TranscriptFormat.jsonlLine(time: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!, lens: "L", app: "a",
                                               source: "ja", target: "ko", engine: "apple", original: "こんにちは", translation: "안녕")
        let none = TranscriptMemory(original: "こんにちは", chain: chain([("ハク", "하쿠")]))
        let withProfile = TranscriptFormat.jsonlLine(time: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!, lens: "L", app: "a",
                                                     source: "ja", target: "ko", engine: "apple", original: "こんにちは", translation: "안녕", memory: none)
        #expect(none.names.isEmpty && !withProfile.contains("\"names\""))
        #expect(!plain.contains("\"profile\"") && !plain.contains("\"names\"") && plain.hasSuffix("\"translation\":\"안녕\"}\n"))
        #expect(withProfile.replacingOccurrences(of: "\"profile\":\"anime\",", with: "") == plain)
    }

    @Test func aRowIsFoundByItsSourceOrItsReadingAndNamesItsProfile() {
        #expect(TranscriptMemory(original: "つくもが来た", chain: chain([("九十九", "Tsukumo")], reading: "つくも")).names == [["九十九", "Tsukumo", "anime"]])
        #expect(TranscriptMemory(original: "no name here", chain: ProfileChain.merge([.allApps], base: ChainBase())).profile == "all")
    }

    @Test func aGlossaryPairThatOccursIsARowFromAllAndAUserRowOfTheChainHidesIt() {
        let base = ChainBase(glossary: [GlossaryPair(src: "ハク", dst: "Haku"), GlossaryPair(src: "花", dst: "Hana"), GlossaryPair(src: "月", dst: "Moon")])
        let anime = AppProfile(bundleID: "com.example.emu", appName: "Anime", source: "ja", target: "ko", entries: [MemoryEntry(src: "ハク", dst: "하쿠")], id: "anime")
        let line = "ハクと花"
        #expect(TranscriptMemory(original: line, chain: ProfileChain.merge([.profile(anime), .allApps], base: base)).names == [["ハク", "하쿠", "anime"], ["花", "Hana", "all"]])
        #expect(TranscriptMemory(original: line, chain: ProfileChain.merge([.allApps], base: base)).names == [["ハク", "Haku", "all"], ["花", "Hana", "all"]])
    }
}
