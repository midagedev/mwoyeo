import Foundation
import Testing
@testable import MwoyeoCore

/// The profile of the new shape (design §1.1, §5.1, §5.3): its id, its name, its conditions, its engine and the
/// keys of today's `appProfiles` items, which are still read.
@Suite struct ProfileFileTests {
    private func json(_ value: some Encodable) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
    }

    // MARK: the new keys (design §5.1)

    @Test func theNewShapeIsRead() throws {
        let p = try JSONDecoder().decode(AppProfile.self, from: Data(#"{"id":"profile-1","name":"月涙譚","when":[{"app":"com.example.emu","titleContains":"月涙譚"}],"source":"ja","target":"ko","useLearned":true}"#.utf8))
        #expect(p.id == "profile-1" && p.name == "月涙譚")
        #expect(p.when.count == 1 && p.when[0].app == "com.example.emu" && p.when[0].titleContains == "月涙譚")
        #expect(p.source == "ja" && p.target == "ko" && p.useLearned == true)
        // The App's own names still say what they said: the app the profile is keyed by, and its name.
        #expect(p.bundleID == "com.example.emu" && p.appName == "月涙譚")
    }

    @Test func theEngineMayBeApple() throws {
        let p = try JSONDecoder().decode(AppProfile.self, from: Data(#"{"bundleID":"a.b","customEngineID":"apple"}"#.utf8))
        #expect(p.engine == .apple && p.customEngineID == nil)
        let added = try JSONDecoder().decode(AppProfile.self, from: Data(#"{"bundleID":"a.b","customEngineID":"3F2504E0-4F89-11D3-9A0C-0305E82C3301"}"#.utf8))
        #expect(added.engine == .added(UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!))
        // A value this build does not know keeps the base choice.
        let unknown = try JSONDecoder().decode(AppProfile.self, from: Data(#"{"bundleID":"a.b","customEngineID":"nope"}"#.utf8))
        #expect(unknown.engine == nil && unknown.customEngineID == nil)
        // And it is written back the way it was read.
        let back = try JSONDecoder().decode(AppProfile.self, from: JSONEncoder().encode(p))
        #expect(back.engine == .apple)
        #expect(try json(p)["customEngineID"] as? String == "apple")
    }

    @Test func todaysAppProfileIsStillTheAppProfile() throws {
        // Today's keys, today's values: the App's call sites read the same names.
        let p = try JSONDecoder().decode(AppProfile.self, from: Data(#"{"bundleID":"com.example.chat","appName":"Example Chat","source":"ja","target":"en"}"#.utf8))
        #expect(p.bundleID == "com.example.chat" && p.appName == "Example Chat")
        #expect(p.id == "com.example.chat")
        #expect(p.when == [ProfileCondition(app: "com.example.chat")])
        // And it is written as it always was: no new key appears in an `appProfiles` item.
        let out = try json(p)
        #expect(Set(out.keys) == ["bundleID", "appName", "source", "target"])
        // The name of a profile is its app's name; the id of an app's profile is its bundle ID.
        #expect(AppProfile(bundleID: "com.example.chat", appName: "Example Chat", source: "ja", target: "en").id == "com.example.chat")
    }

    @Test func theNewKeysAreWrittenOnlyWhenTheOldOnesCannotSayIt() throws {
        // A profile with a title condition and its own id: the old keys cannot say that.
        let p = AppProfile(bundleID: "com.example.emu", appName: "Game", source: "ja", target: "ko",
                           id: "profile-1", name: "Game", when: [ProfileCondition(app: "com.example.emu", titleContains: "月涙譚")])
        let out = try json(p)
        #expect(out["id"] as? String == "profile-1")
        #expect((out["when"] as? [[String: Any]])?.first?["titleContains"] as? String == "月涙譚")
        // What was written reads back as the same profile.
        let back = try JSONDecoder().decode(AppProfile.self, from: JSONEncoder().encode(p))
        #expect(back == p)
    }

    @Test func theCapsAreTheOnesOfTheSchema() throws {
        #expect(AppProfile.maxNameLength == 40 && AppProfile.maxConditions == 8 && AppProfile.maxEntries == 40)
        // The name is cut at 40, the conditions at 8.
        let p = AppProfile(bundleID: "a.b", appName: String(repeating: "n", count: 60), source: "ja", target: "en")
        #expect(p.name.count == 40)
        let many = (0..<12).map { ProfileCondition(app: "a\($0)") }
        let capped = AppProfile(bundleID: "a.b", appName: "A", source: "ja", target: "en", id: "p", name: "P", when: many)
        #expect(capped.when.count == 8)
    }

    @Test func theIdRulesAreTheOnesOfTheSchema() {
        #expect(AppProfile.isValidID("com.example.chat"))
        #expect(AppProfile.isValidID("profile-1"))
        #expect(!AppProfile.isValidID(""))
        #expect(!AppProfile.isValidID("all"))
        #expect(!AppProfile.isValidID("has space"))
        #expect(!AppProfile.isValidID(String(repeating: "a", count: 256)))
        #expect(AppProfile.isValidID(String(repeating: "a", count: 255)))
    }

    // MARK: the conditions (design §1.2)

    @Test func aConditionNeedsAnAppOrAPhrase() {
        #expect(ProfileCondition(app: "a.b").narrowness == 1)
        #expect(ProfileCondition(titleContains: "T").narrowness == 2)
        #expect(ProfileCondition(app: "a.b", titleContains: "T").narrowness == 3)
        // An empty condition is invalid (§5.3) and matches nothing.
        #expect(ProfileCondition().isEmpty)
        #expect(!ProfileCondition().matches(app: "a.b", title: "T"))
        #expect(ProfileCondition().narrowness == 0)
    }

    @Test func aTitleConditionNeedsTheConfirmedTitle() {
        let c = ProfileCondition(titleContains: "月涙譚")
        #expect(c.matches(app: nil, title: "月涙譚 — 第二章"))
        // Until the title is confirmed, only app conditions match (design §1.2).
        #expect(!c.matches(app: nil, title: nil))
        // The phrase is folded: case, accents and width do not matter.
        #expect(ProfileCondition(titleContains: "PREPRINT").matches(app: nil, title: "preprint"))
    }

    // MARK: the engine's permissions (design §4.1)

    @Test func theAllowIsTheDefaultAndIsWrittenOnlyWhenItIsNot() throws {
        #expect(EngineAllow.default == EngineAllow(lines: true, title: false, deepLInstructions: false))
        let engine = EngineConfig(name: "E", kind: .anthropic(baseURL: EngineKind.anthropicDefaultBaseURL, model: "m", thinking: .off))
        // An engine that says nothing is saved as before.
        #expect(Set(try json(engine).keys) == ["id", "name", "kind", "baseURL", "model", "thinking"])
        // An engine that allows the title says so.
        let allowed = EngineConfig(name: "E", kind: engine.kind, allow: EngineAllow(lines: true, title: true))
        let out = try json(allowed)
        #expect((out["allow"] as? [String: Any])?["title"] as? Bool == true)
        // A missing field is its default.
        let read = try JSONDecoder().decode(EngineConfig.self, from: Data(#"{"name":"E","kind":"anthropic","allow":{"title":true}}"#.utf8))
        #expect(read.allow == EngineAllow(lines: true, title: true, deepLInstructions: false))
    }
}
