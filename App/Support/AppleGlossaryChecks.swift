#if !MAS
import AppKit
import MwoyeoCore
import MwoyeoEngines

/// The names and the glossary written into the source (design names-and-context §10, the user's Q3: "Apple's glossary on the mechanical
/// side"): a row whose `apply` is replace or both, and the glossary's pairs while `glossaryApply` is not hint, go into the source of every kind
/// that takes no hints (Apple Translation first); the narrowest row wins when two have the same source. Hint, the default, is today's path:
/// nothing is written. Round prof-file, 2026-10-21: the switch of 1.1.4 (`appleUsesPinnedTerms`, §1.3) is each row's mode and `glossaryApply`
/// now (the converter, §5.2); these are the checks of the switch, ported to the modes (each says what it was).
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

    /// `apply` is the mode of the glossary (`glossaryApply`): `.both` is what the 1.1.4 switch turned on, `.hint` is the default.
    private static func settings(profiles: [AppProfile] = [], apply: EntryApply = .both, glossary: String) -> AppSettings {
        var s = AppSettings()
        s.sourceLanguage = "en"
        s.targetLanguage = "ko"
        s.glossary = glossary
        s.appProfiles = profiles
        s.glossaryApply = apply
        return s
    }

    /// An app's profile whose rows are `apply` (`.both`: what the switch converted them to).
    private static func profile(_ entries: [MemoryEntry], app: String = "com.example.chat", apply: EntryApply = .both) -> AppProfile {
        AppProfile(bundleID: app, appName: app, source: "en", target: "ko", entries: entries.map { var e = $0; e.apply = apply; return e })
    }

    /// The glossary's pair as the plan carries it: a user row of kind term in the glossary's mode.
    private static func pair(_ src: String, _ dst: String, _ apply: EntryApply = .both) -> MemoryEntry {
        MemoryEntry(src: src, dst: dst, kind: .term, origin: .user, apply: apply)
    }

    /// The plan of a lens over `app` (the chain of its window: the app's profile, then All apps).
    private static func plan(_ s: AppSettings, _ p: AppProfile? = nil) -> ContextPlan? {
        let pairing = ContextRoute.pair(settings: s, lens: p?.bundleID ?? "com.example.chat")
        return ContextPlan.decide(settings: s, engine: nil, engineRests: false, chain: pairing.chain)
    }

    @MainActor
    static func planChecks(_ t: Tally) {
        let only = settings(glossary: glossary)
        let rows = [pair("token", "토큰"), pair("other", "다른 것")]
        t.check("the glossary used both ways and only a glossary: the plan carries the glossary's rows", plan(only) == .replaceOnly(rows),
                "\(String(describing: plan(only)))")

        // 1.1.4: "the switch off: the plan is nothing". Now: a glossary that is a hint (the default) writes nothing into the source.
        t.check("the glossary as a hint, the default: the plan is nothing", plan(settings(apply: .hint, glossary: glossary)) == nil)
        t.check("nothing to insert: the plan is nothing", plan(settings(glossary: "")) == nil)
        let replaced = plan(settings(apply: .replace, glossary: glossary))
        t.check("the glossary used only as a replacement: its rows are replace rows", replaced == .replaceOnly([pair("token", "토큰", .replace), pair("other", "다른 것", .replace)]),
                "\(String(describing: replaced))")

        // The app's own row wins over the glossary's row of the same source; the glossary's other pair still joins.
        let mine = MemoryEntry(src: "token", dst: "앱의 토큰", kind: .term, apply: .both)
        let app = profile([mine])
        t.check("the app's row wins over the glossary's row of the same source",
                plan(settings(profiles: [app], glossary: glossary), app) == .replaceOnly([mine, rows[1]]),
                "\(String(describing: plan(settings(profiles: [app], glossary: glossary), app)))")

        // The app's rows come first, then the glossary's, each in the order it is written.
        let alpha = MemoryEntry(src: "alpha", dst: "알파", kind: .term, apply: .both)
        let both = profile([alpha])
        t.check("the app's rows come first, then the glossary's",
                plan(settings(profiles: [both], glossary: glossary), both) == .replaceOnly([alpha] + rows),
                "\(String(describing: plan(settings(profiles: [both], glossary: glossary), both)))")

        // A row that is a hint writes nothing into the source: a profile of hints, the glossary a hint, is today's path.
        let hints = profile([MemoryEntry(src: "alpha", dst: "알파", kind: .term)], apply: .hint)
        t.check("rows that are hints and a glossary that is a hint write nothing into the source",
                plan(settings(profiles: [hints], apply: .hint, glossary: glossary), hints) == nil)

        // Foundation Models has the glossary in its instructions: the glossary's pairs do not go into its source, a profile's replace rows do
        // (1.1.4's check said "nothing is pre-inserted there"; §10 gives it the profiles' rows, §5.2's case (d)).
        var foundation = only
        foundation.engine = .customModel
        t.check("Foundation Models: the glossary does not go into the source", plan(foundation) == nil)
        var foundationWithRows = settings(profiles: [app], glossary: glossary)
        foundationWithRows.engine = .customModel
        t.check("Foundation Models: a profile's replace rows do", plan(foundationWithRows, app) == .replaceOnly([mine]),
                "\(String(describing: plan(foundationWithRows, app)))")

        // The lens reads the window it covers only where something can use it; a replace row is something (the plan needs a lens).
        t.check("the lens reads the window for the glossary too",
                ContextPlan.needsWindow(only) && !ContextPlan.needsWindow(settings(apply: .hint, glossary: glossary)))
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

        let off = await answer(settings(apply: .hint, glossary: glossary))
        t.check("the glossary as a hint, the default: the source Apple sees is untouched", off == "⟦ko⟧ All tokens were shuffled.", "\(String(describing: off))")

        // The app's own row wins in the source too.
        let mine = MemoryEntry(src: "token", dst: "앱의 토큰", kind: .term)
        let app = profile([mine])
        let withApp = await answer(settings(profiles: [app], glossary: glossary), app)
        t.check("the app's own row is the one that goes into the source", withApp == "⟦ko⟧ All 앱의 토큰 were shuffled.",
                "\(String(describing: withApp))")
    }
}
#endif
