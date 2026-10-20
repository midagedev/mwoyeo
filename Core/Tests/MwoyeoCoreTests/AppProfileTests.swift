import Foundation
import Testing
@testable import MwoyeoCore

@Suite struct AppProfileTests {
    private let engineA = UUID(), engineB = UUID()
    private var base: LanguageChoice { LanguageChoice(source: "auto", target: "ko", customEngineID: engineA) }
    private let jaEn = AppProfile(bundleID: "com.example.vn", appName: "VN", source: "ja", target: "en")

    @Test func noProfileKeepsBase() {
        #expect(AppProfiles.effective(base: base, profiles: [jaEn], frontmost: "com.other", engines: [engineA]) == base)
        #expect(AppProfiles.effective(base: base, profiles: [jaEn], frontmost: nil, engines: [engineA]) == base)
        #expect(AppProfiles.effective(base: base, profiles: [], frontmost: "com.example.vn", engines: [engineA]) == base)
    }

    @Test func profileOverridesLanguagesAndNilEngineKeepsBase() {
        let got = AppProfiles.effective(base: base, profiles: [jaEn], frontmost: "com.example.vn", engines: [engineA])
        #expect(got == LanguageChoice(source: "ja", target: "en", customEngineID: engineA))
    }

    @Test func profileEngineOverridesWhenKnown() {
        var p = jaEn
        p.customEngineID = engineB
        #expect(AppProfiles.effective(base: base, profiles: [p], frontmost: p.bundleID, engines: [engineA, engineB]).customEngineID == engineB)
        // An engine the user has since removed falls back to the base choice, not to a dangling id.
        #expect(AppProfiles.effective(base: base, profiles: [p], frontmost: p.bundleID, engines: [engineA]).customEngineID == engineA)
    }

    @Test func rememberingReplacesTheSameApp() {
        var again = jaEn
        again.target = "de"
        let out = AppProfiles.remembering(again, in: AppProfiles.remembering(jaEn, in: []))
        #expect(out == [again])
    }

    /// 2026-10-21 (round nameslens, design names-and-context §3.2, D1): "Remember Languages" of the lens menu used to replace the app's
    /// whole profile with a fresh one of the pair, so the note, the names, the context choice and the reader were lost. Derivation: the
    /// profile has nine fields; remembering is about three of them (source, target, engine), so the other six must come out as they went in.
    private let rich = AppProfile(bundleID: "com.example.rich", appName: "Rich", source: "ja", target: "en", paragraphReader: .lineGrouping,
                                  note: "Fantasy, formal speech.", entries: [CtxFix.alice, CtxFix.tanaka], context: AppContextOverride(mode: .nearby))

    @Test func rememberingLanguagesKeepsTheAppsMemory() {
        let choice = LanguageChoice(source: "ko", target: "de", customEngineID: engineB)
        let after = AppProfiles.remembering(choice, for: rich.bundleID, appName: "Renamed", in: [jaEn, rich])
        let got = after.first { $0.bundleID == rich.bundleID }
        #expect(got?.source == "ko" && got?.target == "de" && got?.customEngineID == engineB)
        #expect(got?.note == rich.note && got?.entries == rich.entries && got?.context == rich.context && got?.paragraphReader == rich.paragraphReader)
        #expect(got?.appName == "Rich" && after.count == 2 && after[0] == jaEn)
    }

    @Test func rememberingLanguagesForANewAppMakesItsProfile() {
        let choice = LanguageChoice(source: "ko", target: "de", customEngineID: engineB)
        #expect(AppProfiles.remembering(choice, for: "com.example.new", appName: "New", in: [jaEn])
                == [jaEn, AppProfile(bundleID: "com.example.new", appName: "New", source: "ko", target: "de", customEngineID: engineB)])
        #expect(rich.languages == LanguageChoice(source: "ja", target: "en", customEngineID: nil))
    }

    /// An app without a profile gets one from the one function (`ensuring`), with the pair it is given; an app with one keeps it.
    @Test func ensuringMakesAProfileOnceWithThePairItIsGiven() {
        var profiles = [jaEn]
        let pair = LanguageChoice(source: "auto", target: "ko", customEngineID: nil)
        let i = AppProfiles.ensuring("com.example.new", appName: "New", in: &profiles, creatingWith: pair)
        #expect(i == 1 && profiles.count == 2 && profiles[1] == AppProfile(bundleID: "com.example.new", appName: "New", source: "auto", target: "ko"))
        #expect(AppProfiles.ensuring("com.example.new", appName: "Other", in: &profiles, creatingWith: LanguageChoice(source: "ja", target: "en", customEngineID: engineA)) == 1)
        #expect(profiles.count == 2 && profiles[1].appName == "New" && profiles[1].target == "ko")
        #expect(AppProfiles.ensuring(jaEn.bundleID, appName: "x", in: &profiles, creatingWith: pair) == 0 && profiles[0] == jaEn)
        // Nothing translates differently when the profile is made: the pair it takes is what the base gave the app.
        let effective = AppProfiles.effective(base: base, profiles: [], frontmost: "com.example.new", engines: [engineA])
        var made: [AppProfile] = []
        AppProfiles.ensuring("com.example.new", appName: "New", in: &made, creatingWith: LanguageChoice(source: effective.source, target: effective.target, customEngineID: nil))
        #expect(AppProfiles.effective(base: base, profiles: made, frontmost: "com.example.new", engines: [engineA]) == effective)
    }

    @Test func decodesLeniently() throws {
        let p = try JSONDecoder().decode(AppProfile.self, from: Data(#"{"bundleID":"a.b","future":1}"#.utf8))
        #expect(p.bundleID == "a.b" && p.appName == "a.b" && p.source == "auto" && p.customEngineID == nil)
    }

    @Test func readerDecodesAsInheritWhenMissingOrUnknown() throws {
        let old = try JSONDecoder().decode(AppProfile.self, from: Data(#"{"bundleID":"a.b","source":"ja","target":"en"}"#.utf8))
        #expect(old.paragraphReader == nil)
        let future = try JSONDecoder().decode(AppProfile.self, from: Data(#"{"bundleID":"a.b","paragraphReader":"somethingNew"}"#.utf8))
        #expect(future.paragraphReader == nil && future.bundleID == "a.b")
        let set = try JSONDecoder().decode(AppProfile.self, from: Data(#"{"bundleID":"a.b","paragraphReader":"lineGrouping"}"#.utf8))
        #expect(set.paragraphReader == .lineGrouping)
    }

    @Test func readerRoundTripsAndProfileOverridesBase() throws {
        let p = AppProfile(bundleID: "a.b", appName: "A", source: "ja", target: "en", paragraphReader: .documentLayout)
        let back = try JSONDecoder().decode(AppProfile.self, from: JSONEncoder().encode(p))
        #expect(back == p)
        #expect(AppProfiles.paragraphReader(base: .automatic, profiles: [p], app: "a.b") == .documentLayout)
        // An app without a profile, a profile without a choice, and no app at all keep the default.
        #expect(AppProfiles.paragraphReader(base: .lineGrouping, profiles: [p], app: "c.d") == .lineGrouping)
        #expect(AppProfiles.paragraphReader(base: .lineGrouping, profiles: [jaEn], app: jaEn.bundleID) == .lineGrouping)
        #expect(AppProfiles.paragraphReader(base: .lineGrouping, profiles: [p], app: nil) == .lineGrouping)
    }

    // MARK: the memory (note and entries)

    private func sorted(_ p: AppProfile) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try enc.encode(p), as: UTF8.self)
    }

    @Test func aProfileSavedBeforeTheMemoryDecodesAndEncodesUnchanged() throws {
        let old = #"{"appName":"A","bundleID":"a.b","paragraphReader":"lineGrouping","source":"ja","target":"en"}"#
        let p = try JSONDecoder().decode(AppProfile.self, from: Data(old.utf8))
        #expect(p == AppProfile(bundleID: "a.b", appName: "A", source: "ja", target: "en", paragraphReader: .lineGrouping))
        #expect(p.note == "" && p.entries.isEmpty)
        // Saved again, no new keys appear until there is a memory.
        #expect(try sorted(p) == old)
    }

    @Test func noteAndEntriesRoundTrip() throws {
        let p = AppProfile(bundleID: "a.b", appName: "A", source: "ja", target: "ko", note: "Close friends, banmal.",
                           entries: [CtxFix.alice, CtxFix.tanaka])
        let back = try JSONDecoder().decode(AppProfile.self, from: JSONEncoder().encode(p))
        #expect(back == p)
        #expect(back.note == "Close friends, banmal." && back.entries == [CtxFix.alice, CtxFix.tanaka])
        #expect(ContextMemory(profile: back).user == back.entries && ContextMemory(profile: back).note == back.note)
        #expect(p.memoryFingerprint == back.memoryFingerprint && p.memoryFingerprint != jaEn.memoryFingerprint)
    }

    @Test func entriesAreCappedAtFortyAndTheNoteAtFiveHundred() throws {
        let many = (0..<60).map { MemoryEntry(src: "k\($0)", dst: "v\($0)") }
        var p = AppProfile(bundleID: "a.b", appName: "A", source: "ja", target: "en", note: String(repeating: "x", count: 900), entries: many)
        #expect(p.entries.count == 40 && p.entries.last?.src == "k39" && p.note.count == 500)
        p.entries.append(MemoryEntry(src: "extra", dst: "x"))
        p.note += "more"
        #expect(p.entries.count == 40 && p.note.count == 500)
        // The same caps on the way in from a file.
        let json = try JSONEncoder().encode(AppProfile(bundleID: "a.b", appName: "A", source: "ja", target: "en"))
        var raw = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        raw["note"] = String(repeating: "y", count: 800)
        raw["entries"] = many.map { ["src": $0.src, "dst": $0.dst] }
        let decoded = try JSONDecoder().decode(AppProfile.self, from: JSONSerialization.data(withJSONObject: raw))
        #expect(decoded.entries.count == 40 && decoded.note.count == 500)
    }

    @Test func aBadEntryIsSkippedNotTheProfile() throws {
        let json = #"{"bundleID":"a.b","source":"ja","target":"en","note":7,"entries":[{"src":"a","dst":"b"},{"src":"no dst"},"junk",{"src":"c","dst":"d","origin":"learned","uses":9},{"src":"A","dst":"dup"},{"src":"e","dst":"f","kind":"future"}]}"#
        let p = try JSONDecoder().decode(AppProfile.self, from: Data(json.utf8))
        #expect(p.bundleID == "a.b" && p.source == "ja" && p.note == "")
        // Kept: a→b, c→d and e→f. Skipped: the entry without dst, the junk, the duplicate src. `origin` and `uses` are not
        // settings-file keys: they are not read, and what comes from a file is a user entry.
        #expect(p.entries.map(\.src) == ["a", "c", "e"] && p.entries.allSatisfy { $0.origin == .user && $0.uses == 0 })
        #expect(p.entries[2].kind == .term)
        // Learned entries are never kept on a profile, even when put there in code.
        let q = AppProfile(bundleID: "a.b", appName: "A", source: "ja", target: "en",
                           entries: [MemoryEntry(src: "x", dst: "y", origin: .learned), MemoryEntry(src: "z", dst: "w")])
        #expect(q.entries.map(\.src) == ["z"])
    }

    // MARK: the settings-file shape (design §10)

    @Test func theCapsArePublicConstantsOnTheTypeTheAppEncodes() {
        #expect(AppProfile.maxEntries == 40 && AppProfile.maxNoteLength == 500)
        #expect(MemoryEntry.maxEntryNote == 40 && MemoryEntry.maxName == 80 && MemoryEntry.maxAddressing == 4)
        let p = AppProfile(bundleID: "a.b", appName: "A", source: "ja", target: "en", note: String(repeating: "n", count: 501),
                           entries: (0..<41).map { MemoryEntry(src: "k\($0)", dst: "v\($0)", note: String(repeating: "e", count: 41)) })
        #expect(p.note.count == AppProfile.maxNoteLength && p.entries.count == AppProfile.maxEntries)
        #expect(p.entries.allSatisfy { $0.note.count == MemoryEntry.maxEntryNote })
        // The same caps on the way in, for the entry note and an addressing target.
        let json = #"{"bundleID":"a.b","entries":[{"src":"a","dst":"b","note":"\#(String(repeating: "e", count: 90))","addressing":[{"to":"\#(String(repeating: "t", count: 200))","register":"polite"}]}]}"#
        let back = try? JSONDecoder().decode(AppProfile.self, from: Data(json.utf8))
        #expect(back?.entries.first?.note.count == MemoryEntry.maxEntryNote)
        #expect(back?.entries.first?.addressing.first?.to.count == MemoryEntry.maxName)
    }

    /// Round S1's validator rejects any other key, so what this type encodes is exactly this list.
    @Test func theEncodedKeysAreTheOnesTheSettingsFileSpecs() throws {
        // 2026-10-21 (round names-core, design names-and-context §10): `apply` is a field of a row. Set it to a non-hint
        // value here, or the fully populated value omits it while `CodingKeys` has it and this schema comparison cannot see it.
        let entry = MemoryEntry(src: "アリス", dst: "앨리스", kind: .person, gender: .f, note: "20s, shy", reading: "ありす",
                                origin: .user, uses: 7, lastSeen: Date(timeIntervalSince1970: 1_700_000_000),
                                addressing: [Addressing(to: "ボブ", register: .casual)], apply: .both)
        let full = AppProfile(bundleID: "a.b", appName: "A", source: "ja", target: "ko", customEngineID: UUID(), paragraphReader: .lineGrouping,
                              note: "Close friends.", entries: [entry], context: AppContextOverride(mode: .conversation, previousLines: 5))
        let root = try JSONSerialization.jsonObject(with: JSONEncoder().encode(full)) as! [String: Any]
        #expect(Set(root.keys) == ["bundleID", "appName", "source", "target", "customEngineID", "paragraphReader", "note", "entries", "context"])
        let e = try #require((root["entries"] as? [[String: Any]])?.first)
        #expect(Set(e.keys) == ["src", "dst", "kind", "gender", "note", "reading", "addressing", "apply"])
        let a = try #require((e["addressing"] as? [[String: Any]])?.first)
        #expect(Set(a.keys) == ["to", "register"])
        let c = try #require(root["context"] as? [String: Any])
        #expect(Set(c.keys) == ["mode", "previousLines"] && c["mode"] as? String == "conversation" && c["previousLines"] as? Int == 5)
        // The settings-file schema is compared with these encoded keys (App/Support/SettingsFileChecks.swift), so a key added to a
        // type's CodingKeys must appear in this fully populated value: otherwise it hides from that comparison and this fails.
        #expect(Set(root.keys) == Set(AppProfile.CodingKeys.allCases.map(\.rawValue)))
        #expect(Set(e.keys) == Set(MemoryEntry.CodingKeys.allCases.map(\.rawValue)))
        #expect(Set(a.keys) == Set(Addressing.CodingKeys.allCases.map(\.rawValue)))
        #expect(Set(c.keys) == Set(AppContextOverride.CodingKeys.allCases.map(\.rawValue)))
        // The enums are strings.
        #expect(e["kind"] as? String == "person" && e["gender"] as? String == "f" && e["apply"] as? String == "both"
                && a["register"] as? String == "casual")
        #expect(root["paragraphReader"] is String && root["customEngineID"] is String)
        // Nil and empty are omitted, not written as null or "".
        let bare = AppProfile(bundleID: "a.b", appName: "A", source: "ja", target: "ko", entries: [MemoryEntry(src: "x", dst: "y")])
        let small = try JSONSerialization.jsonObject(with: JSONEncoder().encode(bare)) as! [String: Any]
        #expect(Set(small.keys) == ["bundleID", "appName", "source", "target", "entries"])
        #expect(Set(try #require((small["entries"] as? [[String: Any]])?.first).keys) == ["src", "dst", "kind"])
        // What was written reads back as the same entry (the runtime-only fields start over).
        let back = try JSONDecoder().decode(AppProfile.self, from: JSONEncoder().encode(full))
        var expected = entry
        expected.uses = 0
        expected.lastSeen = nil
        #expect(back.entries == [expected] && back.note == full.note && back.context == full.context)
    }

    /// docs/settings-for-agents.md states the caps in words. They are the constants above, so a changed constant fails here
    /// until the page follows (the schema follows by itself: `SettingsFile.swift` reads the same constants).
    @Test func theAgentsGuideStatesTheCaps() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let guide = try String(contentsOf: root.appendingPathComponent("docs/settings-for-agents.md"), encoding: .utf8)
        let rows = [
            "| `note` | text, up to \(AppProfile.maxNoteLength) characters |",
            "| `entries` | up to \(AppProfile.maxEntries) rows; a second row with the same `src` is left out |",
            "| `entries[].src`, `dst` | text, 1 to \(MemoryEntry.maxName) characters |",
            "| `entries[].note` | text, up to \(MemoryEntry.maxEntryNote) characters |",
            "| `entries[].reading` | text, up to \(MemoryEntry.maxName) characters |",
            "| `entries[].addressing[]` | up to \(MemoryEntry.maxAddressing) rows; `to` (text, 1 to \(MemoryEntry.maxName) characters)",
            "| `context.previousLines` | whole number, 0 to \(AppContextOverride.maxPreviousLines); left out, \(AppContextOverride.defaultPreviousLines) |",
        ]
        for row in rows { #expect(guide.contains(row), "\(row)") }
    }
}
