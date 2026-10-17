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

    @Test func decodesLeniently() throws {
        let p = try JSONDecoder().decode(AppProfile.self, from: Data(#"{"bundleID":"a.b","future":1}"#.utf8))
        #expect(p.bundleID == "a.b" && p.appName == "a.b" && p.source == "auto" && p.customEngineID == nil)
    }
}
