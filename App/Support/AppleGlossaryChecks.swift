#if !MAS
import AppKit
import MwoyeoCore
import MwoyeoEngines

/// The global glossary with Apple's pinned names (design names-and-context §1.3, G7, the user's Q3): with "Use my names and terms with
/// Apple Translation" on, the glossary's pairs go into the source like the app's own names, and the app's own row wins when both have
/// the same source. The switch off is today's path: nothing of the glossary is pre-inserted.
///
/// The plan is asked directly (the rows it carries), and the harness Apple (`MWOYEO_FAKE_ENGINE`, which answers "⟦<target>⟧ " + the
/// text it was given) shows what Apple really receives.
enum AppleGlossaryChecks {
    final class Tally {
        var failures = 0
        func check(_ what: String, _ ok: Bool, _ note: @autoclosure () -> String = "") {
            print("check-logic: \(ok ? "PASS" : "FAIL") glossary: \(what)" + (ok ? "" : note().isEmpty ? "" : " [\(note())]"))
            if !ok { failures += 1 }
        }
    }

    @MainActor
    static func run() async -> Int {
        let t = Tally()
        planChecks(t)
        await sourceChecks(t)
        return t.failures
    }

    // MARK: the plan

    /// The glossary the checks use: two pairs, so a row that the app's memory has can win over one of them.
    private static let glossary = "token = 토큰\nother = 다른 것"

    private static func settings(profiles: [AppProfile] = [], pins: Bool = true, glossary: String) -> AppSettings {
        var s = AppSettings()
        s.sourceLanguage = "en"
        s.targetLanguage = "ko"
        s.glossary = glossary
        s.appProfiles = profiles
        s.appleUsesPinnedTerms = pins
        return s
    }

    private static func profile(_ entries: [MemoryEntry], app: String = "com.example.chat") -> AppProfile {
        AppProfile(bundleID: app, appName: app, source: "en", target: "ko", entries: entries)
    }

    private static func plan(_ s: AppSettings, _ p: AppProfile? = nil) -> ContextPlan? {
        ContextPlan.decide(settings: s, engine: nil, engineRests: false, profile: p)
    }

    @MainActor
    static func planChecks(_ t: Tally) {
        let only = settings(glossary: glossary)
        let rows = [MemoryEntry(src: "token", dst: "토큰", kind: .term), MemoryEntry(src: "other", dst: "다른 것", kind: .term)]
        t.check("the switch on and only a glossary: the plan carries the glossary's rows", plan(only) == .applePins(rows),
                "\(String(describing: plan(only)))")

        t.check("the switch off: the plan is nothing", plan(settings(pins: false, glossary: glossary)) == nil)
        t.check("the switch on with nothing to insert: the plan is nothing", plan(settings(glossary: "")) == nil)

        // The app's own row wins over the glossary's row of the same source; the glossary's other pair still joins.
        let mine = MemoryEntry(src: "token", dst: "앱의 토큰", kind: .term)
        let app = profile([mine])
        t.check("the app's row wins over the glossary's row of the same source",
                plan(settings(profiles: [app], glossary: glossary), app) == .applePins([mine, rows[1]]),
                "\(String(describing: plan(settings(profiles: [app], glossary: glossary), app)))")

        // The app's rows come first, then the glossary's, each in the order it is written.
        let alpha = MemoryEntry(src: "alpha", dst: "알파", kind: .term)
        let both = profile([alpha])
        t.check("the app's rows come first, then the glossary's",
                plan(settings(profiles: [both], glossary: glossary), both) == .applePins([alpha] + rows),
                "\(String(describing: plan(settings(profiles: [both], glossary: glossary), both)))")

        // Foundation Models is not Apple Translation: nothing is pre-inserted there.
        var foundation = only
        foundation.engine = .customModel
        t.check("Foundation Models is not Apple Translation: the glossary does not go in", plan(foundation) == nil)

        // The lens reads the window it covers only where something can use it; the glossary is something (the plan needs a lens).
        t.check("the lens reads the window for the glossary too",
                ContextPlan.needsWindow(only) && !ContextPlan.needsWindow(settings(pins: false, glossary: glossary)))
    }

    // MARK: what Apple receives

    @MainActor
    static func sourceChecks(_ t: Tally) async {
        setenv("MWOYEO_FAKE_ENGINE", "slow:5", 1)
        defer { unsetenv("MWOYEO_FAKE_ENGINE") }
        // A plural: the pre-insertion takes the plural with the term ("All 토큰 were shuffled."), the output patch of today's path
        // leaves the "s" ("All 토큰s were shuffled."). The two are told apart by the text the engine is given.
        let line = "All tokens were shuffled."
        let lens = LensContext(bundleID: "com.example.chat", appName: "Example Chat", categoryWord: "social",
                               confirmedTitle: "Alice", lensID: "L1", screen: [line], above: [], below: [])

        func answer(_ s: AppSettings, _ p: AppProfile? = nil) async -> String? {
            let service = TranslationService(settings: s, secrets: MemorySecrets([:]))
            return await service.translate([line], context: lens).translations[line]
        }

        let on = await answer(settings(glossary: glossary))
        t.check("the glossary's pair goes into the source Apple sees", on == "⟦ko⟧ All 토큰 were shuffled.", "\(String(describing: on))")

        let off = await answer(settings(pins: false, glossary: glossary))
        t.check("the switch off: the source Apple sees is untouched", off == "⟦ko⟧ All tokens were shuffled.", "\(String(describing: off))")

        // The app's own row wins in the source too.
        let mine = MemoryEntry(src: "token", dst: "앱의 토큰", kind: .term)
        let app = profile([mine])
        let withApp = await answer(settings(profiles: [app], glossary: glossary), app)
        t.check("the app's own row is the one that goes into the source", withApp == "⟦ko⟧ All 앱의 토큰 were shuffled.",
                "\(String(describing: withApp))")
    }
}
#endif
