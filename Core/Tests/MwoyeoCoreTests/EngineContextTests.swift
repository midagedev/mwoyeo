import Foundation
import Testing
@testable import MwoyeoCore

/// An engine's own context switches (`engines[].context`), the options they map to, and the options one request gets once
/// the frontmost app's override is laid over them.
@Suite struct EngineContextTests {
    private func decode(_ text: String) throws -> EngineContext {
        try JSONDecoder().decode(EngineContext.self, from: Data(text.utf8))
    }

    /// `options` with the fields the mapping sets put back to their defaults: what is left must be `ContextOptions()`, so a
    /// field that the mapping touches by mistake shows.
    private func untouched(_ options: ContextOptions) -> ContextOptions {
        var rest = options
        rest.enabled = false
        rest.transcriptCount = nil
        rest.longTranscript = false
        rest.includeLearned = false
        rest.includeTitle = false
        rest.deepLInstructions = false
        return rest
    }

    // MARK: the type

    @Test func everyDefaultIsOff() {
        let e = EngineContext()
        #expect(e.enabled == false && e.includeTitle == false && e.useLearned == false && e.deepLInstructions == false)
        #expect(e.previousLines == AppContextOverride.defaultPreviousLines)
        #expect((try? decode("{}")) == e)
    }

    /// Code that sets a value (init, a later set) is clamped into 0...8, like `AppContextOverride`.
    @Test func previousLinesIsClampedWhenSetInCode() {
        #expect(EngineContext(previousLines: 99).previousLines == AppContextOverride.maxPreviousLines)
        #expect(EngineContext(previousLines: -3).previousLines == 0)
        var e = EngineContext(previousLines: 2)
        e.previousLines = 12
        #expect(e.previousLines == AppContextOverride.maxPreviousLines)
        e.previousLines = -1
        #expect(e.previousLines == 0)
    }

    /// A file is read by the validator and by this decode, and they must agree: the validator reports an out-of-range or
    /// fractional `previousLines` as "ignored", which leaves the default, never a clamped end.
    @Test func aPreviousLinesOutsideTheRangeOrNotWholeInAFileIsTheDefault() throws {
        for text in [#"{"previousLines":12}"#, #"{"previousLines":9}"#, #"{"previousLines":40}"#, #"{"previousLines":-1}"#,
                     #"{"previousLines":5.5}"#, #"{"previousLines":"many"}"#, #"{"previousLines":true}"#, #"{"previousLines":null}"#, "{}"] {
            #expect(try decode(text).previousLines == AppContextOverride.defaultPreviousLines, "\(text)")
        }
        for n in 0...AppContextOverride.maxPreviousLines {
            #expect(try decode(#"{"previousLines":\#(n)}"#).previousLines == n)
        }
    }

    @Test func aWrongTypedSwitchIsOffAndLeavesTheOthers() throws {
        let switches = ["enabled", "includeTitle", "useLearned", "deepLInstructions"]
        for field in switches {
            for bad in [#""yes""#, "1", "0", "null", "[true]", #"{"on":true}"#] {
                // The other three switches are on, `previousLines` is 5, and `field` holds the bad value.
                let others = switches.filter { $0 != field }.map { #""\#($0)":true"# }.joined(separator: ",")
                let e = try decode(#"{\#(others),"previousLines":5,"\#(field)":\#(bad)}"#)
                let want = EngineContext(enabled: field != "enabled", previousLines: 5, includeTitle: field != "includeTitle",
                                         useLearned: field != "useLearned", deepLInstructions: field != "deepLInstructions")
                #expect(e == want, "\(field) \(bad)")
            }
        }
        // Unknown keys (a newer version's) are ignored.
        #expect(try decode(#"{"enabled":true,"future":{"a":1}}"#) == EngineContext(enabled: true))
    }

    /// The encode writes every key, so a file shows an agent the whole vocabulary; a field added to the type must be in
    /// this fully populated value, or its key is missing from the comparison with `CodingKeys` and this fails.
    @Test func encodesEveryKeyAndReadsItBack() throws {
        let e = EngineContext(enabled: true, previousLines: 6, includeTitle: true, useLearned: true, deepLInstructions: true)
        let data = try JSONEncoder().encode(e)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(root.keys) == Set(EngineContext.CodingKeys.allCases.map(\.rawValue)))
        #expect(root["previousLines"] as? Int == 6 && root["enabled"] as? Bool == true)
        #expect(try JSONDecoder().decode(EngineContext.self, from: data) == e)
        let off = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(EngineContext())) as? [String: Any])
        #expect(Set(off.keys) == Set(EngineContext.CodingKeys.allCases.map(\.rawValue)))
    }

    // MARK: the mapping

    @Test func noContextOrADisabledOneIsOff() {
        #expect(ContextOptions.from(engine: nil) == ContextOptions())
        #expect(ContextOptions.from(engine: nil) == .off)
        // Every other switch is on and the lines are many: `enabled == false` still sends nothing extra.
        let loud = EngineContext(enabled: false, previousLines: 8, includeTitle: true, useLearned: true, deepLInstructions: true)
        #expect(ContextOptions.from(engine: loud) == ContextOptions())
        #expect(ContextOptions.from(engine: EngineContext()) == ContextOptions())
    }

    @Test func everyFieldIsMapped() {
        for n in 0...AppContextOverride.maxPreviousLines {
            for bits in 0..<8 {
                let title = bits & 1 != 0, learned = bits & 2 != 0, deepL = bits & 4 != 0
                let got = ContextOptions.from(engine: EngineContext(enabled: true, previousLines: n, includeTitle: title,
                                                                    useLearned: learned, deepLInstructions: deepL))
                let why = "previousLines \(n) title \(title) learned \(learned) deepL \(deepL)"
                #expect(got.enabled == true, "\(why)")
                #expect(got.transcriptCount == n, "\(why)")
                #expect(got.longTranscript == (n > ContextOptions.shortTranscript), "\(why)")
                #expect(got.includeLearned == learned, "\(why)")
                #expect(got.includeTitle == title, "\(why)")
                #expect(got.deepLInstructions == deepL, "\(why)")
                // Every other field is its default: the engine's switches do not choose rows, the card, the format or trust.
                #expect(got.trusted == .none && got.includeUser && got.includeCard && got.format == .line, "\(why)")
                #expect(untouched(got) == ContextOptions(), "\(why)")
            }
        }
    }

    @Test func moreThanFourPreviousLinesTurnOnTheLongTranscript() {
        func long(_ n: Int) -> Bool { ContextOptions.from(engine: EngineContext(enabled: true, previousLines: n)).longTranscript }
        #expect([0, 1, 2, 3, 4].allSatisfy { !long($0) })
        #expect([5, 6, 7, 8].allSatisfy { long($0) })
    }

    /// The request layout reads the mapped options the way `previousLines` says: N lines before, and more than 4 reach the
    /// prompt only because the mapping turned on `longTranscript`.
    @Test func theLayoutSeesTheMappedLines() {
        let before = (1...8).map { ContextLine(source: "line \($0)") }
        let request = CtxFix.rich(items: ["x"], before: before)
        for n in 0...8 {
            let options = ContextOptions.from(engine: EngineContext(enabled: true, previousLines: n))
            #expect(RequestLayout.prepare(request, options, .engine(CtxFix.anthropic)).before.count == n, "previousLines \(n)")
        }
    }

    // MARK: the options of one request

    private func engine(_ context: EngineContext?) -> EngineConfig {
        EngineConfig(name: "E", kind: CtxFix.anthropic, context: context)
    }

    private func profile(_ context: AppContextOverride?) -> AppProfile {
        AppProfile(bundleID: "com.example.chat", appName: "Chat", source: "ja", target: "en", context: context)
    }

    @Test func noEngineContextAndNoOverrideSendsToday() {
        #expect(ContextOptions.effective(engine: nil, profile: nil) == ContextOptions())
        #expect(ContextOptions.effective(engine: engine(nil), profile: nil) == ContextOptions())
        #expect(ContextOptions.effective(engine: engine(nil), profile: profile(nil)) == ContextOptions())
        #expect(ContextOptions.effective(engine: engine(EngineContext()), profile: profile(nil)) == ContextOptions())
    }

    @Test func theEnginesSwitchesAreTheBaseWhenAnAppSaysNothing() {
        let e = EngineContext(enabled: true, previousLines: 6, includeTitle: true, useLearned: true, deepLInstructions: true)
        let got = ContextOptions.effective(engine: engine(e), profile: profile(nil))
        #expect(got == ContextOptions.from(engine: e))
        #expect(got.enabled && got.transcriptCount == 6 && got.longTranscript && got.includeTitle && got.includeLearned && got.deepLInstructions)
    }

    @Test func anAppOverrideLiesOverTheEnginesAndKeepsItsOtherSwitches() {
        let e = EngineContext(enabled: true, previousLines: 6, includeTitle: true, useLearned: true, deepLInstructions: true)
        // off turns it off but nothing else changes.
        let off = ContextOptions.effective(engine: engine(e), profile: profile(AppContextOverride(mode: .off)))
        #expect(off.enabled == false && off.includeTitle && off.includeLearned && off.deepLInstructions)
        // nearby: the lines around the text, no earlier ones.
        let nearby = ContextOptions.effective(engine: engine(e), profile: profile(AppContextOverride(mode: .nearby)))
        #expect(nearby.enabled && nearby.transcriptCount == 0)
        // conversation: this app's count, not the engine's.
        let talk = ContextOptions.effective(engine: engine(e), profile: profile(AppContextOverride(mode: .conversation, previousLines: 2)))
        #expect(talk.enabled && talk.transcriptCount == 2 && talk.includeTitle && talk.includeLearned && talk.deepLInstructions)
        #expect(talk == ContextOptions.resolved(base: .from(engine: e), override: AppContextOverride(mode: .conversation, previousLines: 2)))
    }

    /// Design §9: an app's override is written by the user, and writing it is the opt-in. So `nearby` or `conversation` on an
    /// app turns context ON for an engine that has no context of its own, and for Apple (no engine). It turns on only what
    /// the override says: the title, the learned rows and DeepL's instructions stay off, because the base is Off. This is
    /// intended; do not "fix" it so that an engine's `enabled: false` wins over an app's override.
    @Test func anAppOverrideTurnsContextOnEvenWithNoEngineContext() {
        for config in [nil, engine(nil), engine(EngineContext())] {
            let nearby = ContextOptions.effective(engine: config, profile: profile(AppContextOverride(mode: .nearby)))
            #expect(nearby.enabled == true && nearby.transcriptCount == 0, "\(String(describing: config?.context))")
            #expect(nearby.includeTitle == false && nearby.includeLearned == false && nearby.deepLInstructions == false)
            let talk = ContextOptions.effective(engine: config, profile: profile(AppContextOverride(mode: .conversation, previousLines: 3)))
            #expect(talk.enabled == true && talk.transcriptCount == 3 && talk.longTranscript == false)
        }
        // An engine that is off and loud keeps the loud switches off too: from(engine:) is Off whatever they say.
        let loud = EngineContext(enabled: false, previousLines: 8, includeTitle: true, useLearned: true, deepLInstructions: true)
        let got = ContextOptions.effective(engine: engine(loud), profile: profile(AppContextOverride(mode: .nearby)))
        #expect(got.enabled && got.includeTitle == false && got.includeLearned == false && got.deepLInstructions == false)
    }
}
