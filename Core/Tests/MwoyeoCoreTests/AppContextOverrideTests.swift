import Foundation
import Testing
@testable import MwoyeoCore

/// The per-app context override: the type, its file shape, and the one function that lays it over the global options.
@Suite struct AppContextOverrideTests {
    /// Every field away from the default, so a field the mapping touches by mistake shows.
    private let base = ContextOptions(enabled: false, transcriptCount: 2, trusted: .all, includeUser: false, includeLearned: true,
                                      includeCard: false, includeTitle: true, format: .json, deepLInstructions: true,
                                      longTranscript: false)

    private func sameExcept(_ a: ContextOptions, _ b: ContextOptions, _ fields: Set<String>) -> Bool {
        var x = a, y = b
        if fields.contains("enabled") { x.enabled = y.enabled }
        if fields.contains("transcriptCount") { x.transcriptCount = y.transcriptCount }
        if fields.contains("longTranscript") { x.longTranscript = y.longTranscript }
        return x == y
    }

    // MARK: the mapping

    @Test func noOverrideIsTheBase() {
        #expect(ContextOptions.resolved(base: base, override: nil) == base)
        #expect(ContextOptions.resolved(base: .off, override: nil) == .off)
    }

    @Test func offTurnsItOffAndKeepsEverythingElse() {
        var on = base
        on.enabled = true
        let got = ContextOptions.resolved(base: on, override: AppContextOverride(mode: .off, previousLines: 6))
        #expect(got.enabled == false)
        #expect(sameExcept(got, on, ["enabled"]))
    }

    @Test func nearbyTurnsItOnWithNoEarlierLines() {
        let got = ContextOptions.resolved(base: base, override: AppContextOverride(mode: .nearby, previousLines: 6))
        #expect(got.enabled == true && got.transcriptCount == 0)
        // previousLines does not count in nearby, and longTranscript stays as the base has it.
        #expect(got.longTranscript == false && sameExcept(got, base, ["enabled", "transcriptCount"]))
        var longBase = base
        longBase.longTranscript = true
        #expect(ContextOptions.resolved(base: longBase, override: AppContextOverride(mode: .nearby)).longTranscript == true)
    }

    @Test func conversationTakesPreviousLinesAndLongTranscriptOnlyAboveFour() {
        for n in 0...8 {
            let got = ContextOptions.resolved(base: base, override: AppContextOverride(mode: .conversation, previousLines: n))
            #expect(got.enabled == true && got.transcriptCount == n, "previousLines \(n)")
            #expect(got.longTranscript == (n > ContextOptions.shortTranscript), "previousLines \(n)")
            #expect(sameExcept(got, base, ["enabled", "transcriptCount", "longTranscript"]), "previousLines \(n)")
        }
        // At 4 or fewer lines a base that already allows the long transcript keeps it.
        var longBase = base
        longBase.longTranscript = true
        #expect(ContextOptions.resolved(base: longBase, override: AppContextOverride(mode: .conversation, previousLines: 3)).longTranscript == true)
    }

    @Test func anOverrideCanTurnItOnFromTheOffDefaultAndOffStaysOff() {
        #expect(ContextOptions.resolved(base: ContextOptions(), override: AppContextOverride(mode: .nearby)).enabled == true)
        #expect(ContextOptions.resolved(base: ContextOptions(), override: AppContextOverride(mode: .off)) == .off)
    }

    /// The request layout reads the mapped options the way the design says: nearby sends no earlier lines, conversation sends
    /// the last N, and more than 4 reach the prompt only because the mapping turned on `longTranscript`.
    @Test func theLayoutSeesTheMappedLines() {
        let before = (1...8).map { ContextLine(source: "line \($0)") }
        let request = CtxFix.rich(items: ["x"], before: before)
        func lines(_ mode: AppContextOverride.Mode, _ n: Int) -> Int {
            let options = ContextOptions.resolved(base: ContextOptions(), override: AppContextOverride(mode: mode, previousLines: n))
            return RequestLayout.prepare(request, options, .engine(CtxFix.anthropic)).before.count
        }
        #expect(lines(.nearby, 8) == 0)
        #expect(lines(.conversation, 3) == 3)
        #expect(lines(.conversation, 4) == 4)
        #expect(lines(.conversation, 5) == 5)
        #expect(lines(.conversation, 8) == 8)
    }

    // MARK: the type

    /// Code that sets a value (init, a later set) is clamped into 0...8.
    @Test func previousLinesIsClampedWhenSetInCode() {
        #expect(AppContextOverride(mode: .conversation, previousLines: 99).previousLines == 8)
        #expect(AppContextOverride(mode: .conversation, previousLines: -3).previousLines == 0)
        var o = AppContextOverride(mode: .conversation, previousLines: 2)
        o.previousLines = 12
        #expect(o.previousLines == 8)
        o.previousLines = -1
        #expect(o.previousLines == 0)
    }

    /// A file is read by the validator and by this decode, and they must agree: the validator reports an out-of-range
    /// `previousLines` as "ignored", which leaves the default (3). So the decode takes the default too, never a clamped 8.
    @Test func anOutOfRangePreviousLinesInAFileIsTheDefaultNotAClamp() throws {
        let fallback = AppContextOverride(mode: .conversation, previousLines: AppContextOverride.defaultPreviousLines)
        #expect(fallback.previousLines == 3)
        for text in [#"{"mode":"conversation","previousLines":12}"#, #"{"mode":"conversation","previousLines":9}"#,
                     #"{"mode":"conversation","previousLines":40}"#, #"{"mode":"conversation","previousLines":-1}"#,
                     #"{"mode":"conversation","previousLines":-5}"#, #"{"mode":"conversation","previousLines":5.5}"#,
                     #"{"mode":"conversation","previousLines":true}"#] {
            #expect(try JSONDecoder().decode(AppContextOverride.self, from: Data(text.utf8)) == fallback, "\(text)")
        }
        // The ends of the range are kept as written.
        for n in 0...AppContextOverride.maxPreviousLines {
            let o = try JSONDecoder().decode(AppContextOverride.self, from: Data(#"{"mode":"conversation","previousLines":\#(n)}"#.utf8))
            #expect(o.previousLines == n)
        }
    }

    @Test func aMissingOrUnreadablePreviousLinesIsTheDefault() throws {
        for text in [#"{"mode":"conversation"}"#, #"{"mode":"conversation","previousLines":"many"}"#, #"{"mode":"conversation","previousLines":null}"#] {
            let o = try JSONDecoder().decode(AppContextOverride.self, from: Data(text.utf8))
            #expect(o == AppContextOverride(mode: .conversation, previousLines: AppContextOverride.defaultPreviousLines), "\(text)")
        }
    }

    // MARK: in the profile

    private func sorted(_ p: AppProfile) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try enc.encode(p), as: UTF8.self)
    }

    @Test func aProfileKeepsItsContextThroughEncodeAndDecode() throws {
        let p = AppProfile(bundleID: "a.b", appName: "A", source: "ja", target: "en",
                           context: AppContextOverride(mode: .conversation, previousLines: 5))
        #expect(try sorted(p) == #"{"appName":"A","bundleID":"a.b","context":{"mode":"conversation","previousLines":5},"source":"ja","target":"en"}"#)
        let back = try JSONDecoder().decode(AppProfile.self, from: JSONEncoder().encode(p))
        #expect(back == p && back.context == AppContextOverride(mode: .conversation, previousLines: 5))
    }

    @Test func aBadContextIsNoContextAndNeverLosesTheProfile() throws {
        for bad in [#""context":{}"#, #""context":{"mode":"full"}"#, #""context":{"mode":3}"#, #""context":"nearby""#,
                    #""context":[1]"#, #""context":null"#] {
            let p = try JSONDecoder().decode(AppProfile.self, from: Data(#"{"bundleID":"a.b","source":"ja","target":"en","note":"keep",\#(bad)}"#.utf8))
            #expect(p.context == nil && p.bundleID == "a.b" && p.target == "en" && p.note == "keep", "\(bad)")
        }
    }

    /// 1.1.2 wrote a profile without memory fields as exactly these bytes. The literals are what main 35f6f63's own
    /// `AppProfile` encodes (`JSONEncoder` with `.sortedKeys, .withoutEscapingSlashes`, compiled from that commit's source
    /// on 2026-10-19): a profile with no note, no entries and no context must still encode to them, byte for byte.
    @Test func aProfileWithoutMemoryEncodesToTheBytesOf112() throws {
        let id = UUID(uuidString: "7B3F1C2E-5A4D-4E8B-9C21-3D6F0A1B2C3D")!
        let full = AppProfile(bundleID: "com.example.chat", appName: "Example Chat", source: "ja", target: "en",
                              customEngineID: id, paragraphReader: .lineGrouping)
        let plain = AppProfile(bundleID: "com.example.chat", appName: "Example Chat", source: "ja", target: "en")
        #expect(try sorted(full) == #"{"appName":"Example Chat","bundleID":"com.example.chat","customEngineID":"7B3F1C2E-5A4D-4E8B-9C21-3D6F0A1B2C3D","paragraphReader":"lineGrouping","source":"ja","target":"en"}"#)
        #expect(try sorted(plain) == #"{"appName":"Example Chat","bundleID":"com.example.chat","source":"ja","target":"en"}"#)
        // Read back from those bytes and written again, the same bytes: a context of nil adds no key.
        let again = try JSONDecoder().decode(AppProfile.self, from: Data(try sorted(full).utf8))
        let bytes = try sorted(full), saved = try sorted(again)
        #expect(again.context == nil && saved == bytes)
    }
}
