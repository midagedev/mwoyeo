import Foundation
import Testing
@testable import MwoyeoCore

/// The converter of the 1.1.4 file (design §5.2): the table row by row, and the four exceptions.
@Suite struct ProfileMigrationTests {
    private let engineA = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
    private let engineB = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func engine(_ id: UUID, _ context: EngineContext?, kind: EngineKind = .anthropic(
        baseURL: EngineKind.anthropicDefaultBaseURL, model: "claude", thinking: .off)) -> EngineConfig {
        EngineConfig(id: id, name: "E", kind: kind, context: context)
    }

    private func json(_ value: some Encodable) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
    }

    // MARK: the table, row by row

    @Test func anAppProfileBecomesAProfileOfTheNewShape() {
        let old = LegacySettings(appProfiles: [AppProfile(bundleID: "com.example.chat", appName: "Example Chat",
                                                            source: "ja", target: "en", note: "casual",
                                                            entries: [MemoryEntry(src: "ハク", dst: "하쿠")],
                                                            context: AppContextOverride(mode: .nearby))])
        let profiles = ProfileMigration.convert(old).value.profiles
        #expect(profiles.count == 1)
        #expect(profiles[0].id == "com.example.chat")
        #expect(profiles[0].name == "Example Chat")
        #expect(profiles[0].when == [ProfileCondition(app: "com.example.chat")])
        #expect(profiles[0].source == "ja" && profiles[0].target == "en")
        #expect(profiles[0].note == "casual" && profiles[0].entries.map(\.src) == ["ハク"])
        #expect(profiles[0].context == AppContextOverride(mode: .nearby))
    }

    @Test func theTopLevelAmountComesFromTheEngineInUse() {
        // The engine in use is off: no key, and the amount is `memory`.
        let off = LegacySettings(customEngineID: engineA, engines: [engine(engineA, EngineContext(enabled: false, previousLines: 3))])
        #expect(ProfileMigration.convert(off).value.context == nil)
        // On with no earlier lines: nearby.
        let nearby = LegacySettings(customEngineID: engineA, engines: [engine(engineA, EngineContext(enabled: true, previousLines: 0))])
        #expect(ProfileMigration.convert(nearby).value.context?.mode == .nearby)
        // On with earlier lines: conversation n.
        let conversation = LegacySettings(customEngineID: engineA, engines: [engine(engineA, EngineContext(enabled: true, previousLines: 3))])
        #expect(ProfileMigration.convert(conversation).value.context?.mode == AppContextOverride.Mode.conversation)
        #expect(ProfileMigration.convert(conversation).value.context?.previousLines == 3)
        // No engine in use: the first engine that was on.
        let first = LegacySettings(engines: [engine(engineA, EngineContext(enabled: false, previousLines: 3)),
                                             engine(engineB, EngineContext(enabled: true, previousLines: 2))])
        #expect(ProfileMigration.convert(first).value.context?.previousLines == 2)
    }

    @Test func aProfileOfItsOwnEngineKeepsThatAmount() {
        // The profile's engine had another amount than the top-level one: the profile keeps it.
        let old = LegacySettings(customEngineID: engineA,
                                 appProfiles: [AppProfile(bundleID: "com.example.chat", appName: "Chat", source: "ja",
                                                          target: "en", customEngineID: engineB)],
                                 engines: [engine(engineA, EngineContext(enabled: true, previousLines: 3)),
                                           engine(engineB, EngineContext(enabled: true, previousLines: 5))])
        let profiles = ProfileMigration.convert(old).value.profiles
        #expect(profiles[0].context?.mode == .conversation && profiles[0].context?.previousLines == 5)
        // The same amount as the top-level one: nothing is written for the profile.
        let same = LegacySettings(customEngineID: engineA,
                                  appProfiles: [AppProfile(bundleID: "com.example.chat", appName: "Chat", source: "ja",
                                                           target: "en", customEngineID: engineB)],
                                  engines: [engine(engineA, EngineContext(enabled: true, previousLines: 3)),
                                            engine(engineB, EngineContext(enabled: true, previousLines: 3))])
        #expect(ProfileMigration.convert(same).value.profiles[0].context == nil)
    }

    @Test func theEnginesGetTheirPermissionsAndLoseTheirOldContext() {
        let old = LegacySettings(customEngineID: engineA,
                                 engines: [engine(engineA, EngineContext(enabled: true, previousLines: 3, includeTitle: true,
                                                                      useLearned: true, deepLInstructions: true)),
                                           engine(engineB, EngineContext(enabled: false, previousLines: 3, includeTitle: true))])
        let result = ProfileMigration.convert(old)
        let engines = result.value.engines ?? []
        #expect(engines.count == 2)
        // The engine that was on keeps its title and its DeepL instructions.
        #expect(engines[0].allow == EngineAllow(lines: true, title: true, deepLInstructions: true))
        // The engine that was off gets no title and no instructions (they did nothing), and it keeps the line only:
        // the top-level amount sends the lines and no profile does.
        #expect(engines[1].allow == EngineAllow(lines: false, title: false, deepLInstructions: false))
        // The old context is read, never written.
        #expect(engines.allSatisfy { $0.context == nil })
        // The chain's learn switch comes from the engine the amount comes from.
        #expect(result.value.useLearned == true)
    }

    @Test func anEngineThatWasOffLosesTheLinesWhenTheTopLevelSendsThem() {
        // The top-level amount sends the lines and no profile does: the engine that was off keeps the line only.
        let old = LegacySettings(customEngineID: engineB,
                                 engines: [engine(engineA, EngineContext(enabled: false, previousLines: 3)),
                                           engine(engineB, EngineContext(enabled: true, previousLines: 3))])
        let engines = ProfileMigration.convert(old).value.engines ?? []
        #expect(engines[0].allow.lines == false)
        #expect(engines[1].allow.lines == true)
        // With a profile that sends lines of its own, the engine gets them.
        let withProfile = LegacySettings(customEngineID: engineB,
                                          appProfiles: [AppProfile(bundleID: "com.example.chat", appName: "Chat", source: "ja",
                                                                   target: "en", context: AppContextOverride(mode: .nearby))],
                                          engines: [engine(engineA, EngineContext(enabled: false, previousLines: 3)),
                                                    engine(engineB, EngineContext(enabled: true, previousLines: 3))])
        #expect((ProfileMigration.convert(withProfile).value.engines ?? [])[0].allow.lines == true)
    }

    @Test func theAppleSwitchMakesEveryRowUsedInBothWays() {
        let row = MemoryEntry(src: "ハク", dst: "하쿠")
        let on = LegacySettings(appleUsesPinnedTerms: true,
                                appProfiles: [AppProfile(bundleID: "com.example.chat", appName: "Chat", source: "ja",
                                                         target: "en", entries: [row])])
        let result = ProfileMigration.convert(on)
        #expect(result.value.profiles[0].entries.map(\.apply) == [.both])
        #expect(result.value.glossaryApply == .both)
        #expect(result.exceptions.contains(.applePinsBecomeBoth))
        // The switch off: nothing is written, and Apple stays exactly as today.
        let off = LegacySettings(appleUsesPinnedTerms: false,
                                 appProfiles: [AppProfile(bundleID: "com.example.chat", appName: "Chat", source: "ja",
                                                          target: "en", entries: [row])])
        let offResult = ProfileMigration.convert(off)
        // 2026-10-21, prof-file: the mode is `MemoryEntry.apply` (one owner), so "no mode written" reads `.hint`, the same fact as the `nil` it was.
        #expect(offResult.value.profiles[0].entries.map(\.apply) == [.hint])
        #expect(offResult.value.glossaryApply == nil)
        #expect(!offResult.exceptions.contains(.applePinsBecomeBoth))
    }

    @Test func theKeysOfAllAppsAreUnchanged() {
        let old = LegacySettings(sourceLanguage: "ja", targetLanguage: "ko", engine: "auto", customEngineID: engineA,
                                 glossary: "Tarou = タロウ", paragraphReader: .documentLayout)
        let value = ProfileMigration.convert(old).value
        #expect(value.sourceLanguage == "ja" && value.targetLanguage == "ko" && value.engine == "auto")
        #expect(value.customEngineID == engineA && value.glossary == "Tarou = タロウ")
        #expect(value.paragraphReader == .documentLayout)
    }

    @Test func withBothShapesTheOldProfilesAreIgnored() {
        let old = LegacySettings(appProfiles: [AppProfile(bundleID: "com.example.chat", appName: "Old", source: "ja", target: "en")],
                                 profiles: [ProfileFile(id: "profile-1", name: "New", source: "ja", target: "ko")])
        let profiles = ProfileMigration.convert(old).value.profiles
        #expect(profiles.count == 1 && profiles[0].id == "profile-1" && profiles[0].name == "New")
    }

    @Test func aFileThatIsAlreadyInTheNewShapeKeepsItsPermissions() {
        // The converter runs on every read: a file it wrote itself keeps what it wrote.
        let withAllow = EngineConfig(id: engineA, name: "E",
                                     kind: .anthropic(baseURL: EngineKind.anthropicDefaultBaseURL, model: "claude", thinking: .off),
                                     allow: EngineAllow(lines: true, title: true, deepLInstructions: false))
        let old = LegacySettings(engines: [withAllow],
                                 profiles: [ProfileFile(id: "profile-1", name: "New", source: "ja", target: "ko")])
        let value = ProfileMigration.convert(old).value
        #expect((value.engines ?? [])[0].allow == EngineAllow(lines: true, title: true, deepLInstructions: false))
    }

    // MARK: the exceptions (design §5.2)

    @Test func theExceptionsAreTheOnesOfTheFile() {
        // (a): a profile with an app condition.
        let withApp = LegacySettings(appProfiles: [AppProfile(bundleID: "com.example.chat", appName: "Chat", source: "ja", target: "en")])
        #expect(ProfileMigration.convert(withApp).exceptions.contains(.lensUsesItsOwnProfile))
        // (b): a spare engine with an amount of its own.
        let spare = LegacySettings(customEngineID: engineA,
                                   engines: [engine(engineA, EngineContext(enabled: true, previousLines: 3)),
                                             engine(engineB, EngineContext(enabled: true, previousLines: 5))])
        #expect(ProfileMigration.convert(spare).exceptions.contains(.spareEnginePreviousLines))
        // (c): an engine off, an app that sends lines, another engine on.
        let three = LegacySettings(customEngineID: engineB,
                                   appProfiles: [AppProfile(bundleID: "com.example.chat", appName: "Chat", source: "ja",
                                                            target: "en", context: AppContextOverride(mode: .nearby))],
                                   engines: [engine(engineA, EngineContext(enabled: false, previousLines: 3)),
                                             engine(engineB, EngineContext(enabled: true, previousLines: 3))])
        #expect(ProfileMigration.convert(three).exceptions.contains(.engineOffWithAppOverride))
        // A file with nothing in it has none of them.
        #expect(ProfileMigration.convert(LegacySettings()).exceptions.isEmpty)
    }

    // MARK: the default path (design §8, row R1)

    /// A 1.1.4 file with no app profile, no engine context and the Apple switch off converts to a value that writes
    /// no new key.
    @Test func aFileWithNothingToConvertWritesNoNewKey() throws {
        let old = LegacySettings(sourceLanguage: "ja", targetLanguage: "ko", glossary: "Tarou = タロウ",
                                 appleUsesPinnedTerms: false,
                                 engines: [engine(engineA, nil)])
        let value = ProfileMigration.convert(old).value
        let out = try json(value)
        #expect(Set(out.keys) == ["sourceLanguage", "targetLanguage", "glossary", "engines"])
        // The engine that said nothing keeps saying nothing: no `allow`, and no `context`.
        let engines = try #require(out["engines"] as? [[String: Any]])
        #expect(engines[0]["allow"] == nil && engines[0]["context"] == nil)
    }

    /// The file of 1.1.4 is read as it is written, and the new value is the one of the new shape.
    @Test func theFileOf1_1_4IsReadAndConverted() throws {
        let json = """
        {"sourceLanguage":"ja","targetLanguage":"ko","glossary":"Tarou = タロウ","appleUsesPinnedTerms":true,
         "engines":[{"id":"\(engineA.uuidString)","name":"Cloud Chat","kind":"anthropic","baseURL":"https://api.anthropic.com",
                     "model":"claude","thinking":"off","context":{"enabled":true,"previousLines":3,"includeTitle":true,"useLearned":true,"deepLInstructions":false}}],
         "appProfiles":[{"bundleID":"com.example.chat","appName":"Example Chat","source":"ja","target":"en",
                         "note":"casual","entries":[{"src":"ハク","dst":"하쿠"}]}]}
        """
        let old = try JSONDecoder().decode(LegacySettings.self, from: Data(json.utf8))
        #expect(old.appProfiles?.count == 1 && old.engines?.count == 1)
        let result = ProfileMigration.convert(old)
        #expect(result.value.profiles[0].id == "com.example.chat" && result.value.profiles[0].name == "Example Chat")
        #expect(result.value.context?.mode == AppContextOverride.Mode.conversation && result.value.context?.previousLines == 3)
        #expect(result.value.useLearned == true)
        #expect(result.value.glossaryApply == .both)
        #expect(result.value.profiles[0].entries.map(\.apply) == [.both])
        #expect((result.value.engines ?? [])[0].allow == EngineAllow(lines: true, title: true, deepLInstructions: false))
        #expect(result.exceptions.contains(.lensUsesItsOwnProfile))
        #expect(result.exceptions.contains(.applePinsBecomeBoth))
    }
}
