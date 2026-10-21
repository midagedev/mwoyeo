#if !MAS
import Foundation
import MwoyeoCore

/// The rewrites in the translation path (docs/design/rewrite-rules.md §4, §5, §9; round rewrite-run, part B): the stages around the engine, the cache
/// namespace, the log's `sent`, the time limit's `on: false`, and the settings file's two keys. The engine is `tools/mock-openai/server.py` as in
/// `ContextChecks`; the script service is the real one, through the connection the caller hands in. Run by `RewriteChecks.run`, which also owns the deaths
/// of the service these checks cause (one, on a connection of its own: launchd holds a new start for what is left of 10 s, `ScriptConnection.launchThrottle`).
@MainActor
enum RewritePipelineChecks {
    private static let chat = ContextChecks.chat

    private static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

    /// The lines of one request body, in the order sent: `{"lines": [...]}` (today's request) or `{"translate": [{"id", "text"}]}` (the context layout).
    private static func linesSent(_ body: String) -> [String] {
        let root = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        let content = (root["messages"] as? [[String: Any]])?.last?["content"] as? String ?? ""
        let user = (try? JSONSerialization.jsonObject(with: Data(content.utf8))) as? [String: Any] ?? [:]
        if let lines = user["lines"] as? [String] { return lines }
        return ((user["translate"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }
    }

    /// A profile for the app of a lens with these rewrites.
    private static func profile(rows: [RewriteRow] = [], script: String? = nil) -> AppProfile {
        var p = ContextChecks.profile(chat)
        p.rewrites = rows
        p.script = script.map { RewriteScript(source: $0) }
        return p
    }

    private final class Done: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false
        var value: Bool { get { lock.withLock { on } } set { lock.withLock { on = newValue } } }
    }

    private final class Told: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [[RewriteUnit]] = []
        func add(_ units: [RewriteUnit]) { lock.withLock { all.append(units) } }
        var calls: [[RewriteUnit]] { lock.withLock { all } }
    }

    static func run(through c: ScriptConnection) async -> Int {
        var failed = 0
        func check(_ what: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            print("check-logic: \(ok ? "PASS" : "FAIL") rewrite: \(what)" + (ok || detail().isEmpty ? "" : " [\(detail())]"))
            if !ok { failed += 1 }
        }
        func measured(_ what: String) { print("check-logic: info rewrite: \(what)") }

        guard let mock = ContextChecks.Mock(mode: "ok") else { check("the pipeline checks' mock engine starts", false); return failed }
        defer { mock.stop() }
        let engine = ContextChecks.engine("openai", base: mock.base)
        let context = ContextChecks.lens(chat, title: nil)
        let line = "A cat sat"

        func service(_ s: AppSettings, runner: any RewriteRunner) async -> (TranslationService, LensRoute) {
            let svc = ContextChecks.service(s)
            await svc.useRewriteRunner(runner)
            return (svc, LensRoute(base: s, over: chat))
        }
        func requests(since start: Int) -> [[String]] { mock.bodies.dropFirst(start).map(linesSent) }

        // MARK: Nothing set: the service is never asked, and the engine is sent the lines as they are (§5, §9)

        let none = ContextChecks.settings(engine, profiles: [profile()])
        let asked = ScriptConnection()
        let shared = ScriptConnection.shared.connectionsMade
        let (plainSvc, plainRoute) = await service(none, runner: asked)
        var start = mock.bodies.count
        let first = await plainSvc.translate([line, "See you tomorrow at nine"], route: plainRoute, context: context)
        check("nothing set: no connection is made, the engine is sent the lines as they are, and nothing is recorded as sent",
              asked.connectionsMade == 0 && asked.jobsSent == 0 && ScriptConnection.shared.connectionsMade == shared && requests(since: start) == [[line, "See you tomorrow at nine"]]
              && first.translations.count == 2 && plainSvc.sentText(for: line, route: plainRoute) == nil && !plainSvc.storeCounts.keys.contains { $0.contains("|rw:") },
              "connections \(asked.connectionsMade), requests \(requests(since: start)), stores \(plainSvc.storeCounts.keys.sorted())")
        let hits = plainSvc.cached(line, route: plainRoute) != nil
        check("nothing set: the cache answers a line it has, as before", hits && plainSvc.cachedCount == 2)

        // Rows and a script that are all off are nothing set.
        var offRows = none
        offRows.appProfiles[0].rewrites = [RewriteRow(.before, "A", "B", on: false), RewriteRow(.before, "A", "C", regex: true, on: false)]
        offRows.appProfiles[0].script = RewriteScript(source: "function before(l) { return 'x' }", on: false)
        offRows.rewrites = [RewriteRow(.after, "a", "b", on: false)]
        check("rows and a script that are off are nothing set", !offRows.hasRewrites && !none.hasRewrites)

        // MARK: Plain rows only: run in the app, no connection; the engine is sent the changed line, the answer is changed after

        var tidy = none
        tidy.appProfiles[0].rewrites = [RewriteRow(.before, "A cat", "The cat"), RewriteRow(.after, "⟦", "[")]
        let tidied = ScriptConnection()
        let (tidySvc, tidyRoute) = await service(tidy, runner: tidied)
        start = mock.bodies.count
        let untouched = "See you tomorrow at nine"
        let tidyOut = await tidySvc.translate([line, untouched], route: tidyRoute, context: context)
        let shown = tidyOut.translations[line] ?? ""
        check("plain rows: the engine is sent what `before` left, the answer is what `after` made of it, and no connection is made",
              requests(since: start) == [["The cat sat", untouched]] && shown.hasPrefix("[") && !shown.contains("⟦") && shown.contains("The cat sat") && (tidyOut.translations[untouched] ?? "").hasPrefix("[") && tidied.connectionsMade == 0,
              "\(requests(since: start)) \(shown) connections \(tidied.connectionsMade)")
        check("what was sent is kept for the log, only where it differs", tidySvc.sentText(for: line, route: tidyRoute) == "The cat sat" && tidySvc.sentText(for: "other", route: tidyRoute) == nil)
        start = mock.bodies.count
        let again = await tidySvc.translate([line], route: tidyRoute, context: context)
        check("a line the call kept is answered from its cache: no request", requests(since: start).isEmpty && again.translations[line] == shown)
        check("a lens does not read the engine's raw entry as its line, which `before` left as it was: `cached` has nothing while rewrites are on",
              tidySvc.cached(untouched, route: tidyRoute) == nil && tidySvc.cached(line, route: tidyRoute) == nil)
        let namespaces = tidySvc.storeCounts.keys.sorted()
        check("the lens's cache is under the chain's fingerprint, the engine's raw answer under today's namespace",
              namespaces.count == 2 && namespaces.filter { $0.contains("|rw:") }.count == 1 && namespaces.contains { !$0.contains("|rw:") && $0.hasPrefix("en>ko|ext:") }, "\(namespaces)")
        var moved = tidy
        moved.appProfiles[0].rewrites[1] = RewriteRow(.after, "⟦", "<")
        await tidySvc.update(settings: moved)
        start = mock.bodies.count
        let movedOut = await tidySvc.translate([line], route: LensRoute(base: moved, over: chat), context: context)
        check("changing a row moves the namespace: the line is answered again (the engine's raw answer is reused, so no request) and shows the new row",
              (movedOut.translations[line] ?? "").hasPrefix("<") && requests(since: start).isEmpty, "\(movedOut.translations[line] ?? "-") \(requests(since: start))")
        let back = await tidySvc.translate([line], route: tidyRoute, context: context)
        check("and switching back finds the first answer where it was", back.translations[line] == shown)

        // MARK: An engine that fails: Apple stands in, and what it answered is not kept as the engine's

        guard let failing = ContextChecks.Mock(mode: "401") else { check("the pipeline checks' failing mock engine starts", false); return failed }
        defer { failing.stop() }
        setenv("MWOYEO_FAKE_ENGINE", "slow:10", 1)
        var fallback = ContextChecks.settings(ContextChecks.engine("openai", base: failing.base), profiles: [profile(rows: [RewriteRow(.before, "A cat", "The cat"), RewriteRow(.after, "⟦", "[")])])
        fallback.cacheSize = 100
        let (fallbackSvc, fallbackRoute) = await service(fallback, runner: ScriptConnection())
        let stood = await fallbackSvc.translate([line], route: fallbackRoute, context: context)
        unsetenv("MWOYEO_FAKE_ENGINE")
        check("an engine that fails is stood in for by Apple: the line is answered and rewritten, and none of it is kept under the engine's chain namespace",
              (stood.translations[line] ?? "").hasPrefix("[") && fallbackSvc.translatedBy("The cat sat", route: fallbackRoute) == "apple" && !fallbackSvc.storeCounts.keys.contains { $0.contains("|rw:") },
              "\(stood.translations) by \(String(describing: fallbackSvc.translatedBy("The cat sat", route: fallbackRoute))) stores \(fallbackSvc.storeCounts.keys.sorted())")

        // MARK: Regex rows and scripts across a chain, through the real service: before broad → narrow, after narrow → broad

        var layered = ContextChecks.settings(engine, profiles: [profile(rows: [RewriteRow(.before, "B", "C", regex: true)], script: "function after(s, d, c) { return d + ' |chat' }")])
        layered.rewrites = [RewriteRow(.before, "A", "B")]
        layered.script = RewriteScript(source: "function after(s, d, c) { return d + ' |all' }")
        let (chainSvc, chainRoute) = await service(layered, runner: c)
        start = mock.bodies.count
        let jobs = c.jobsSent
        let chainOut = await chainSvc.translate([line], route: chainRoute, context: context)
        let chained = chainOut.translations[line] ?? ""
        check("a chain: All apps' row (A → B) runs first, then the app's regex row sees its result (B → C): the engine is sent C cat sat",
              requests(since: start) == [["C cat sat"]], "\(requests(since: start))")
        check("a chain: the app's script runs first after, then All apps' script, on the engine's answer", chained.hasSuffix(" |chat |all") && chained.contains("C cat sat"), chained)
        let jobsAfter = c.jobsSent
        start = mock.bodies.count
        let chainAgain = await chainSvc.translate([line], route: chainRoute, context: context)
        check("a line the call kept costs no request and no service call the second time",
              requests(since: start).isEmpty && c.jobsSent == jobsAfter && chainAgain.translations[line] == chained && jobsAfter > jobs, "\(requests(since: start)) jobs \(jobs) \(jobsAfter) \(c.jobsSent)")
        let loggedLine = TranscriptFormat.jsonlLine(time: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!, lens: "L", app: chat, source: "en", target: "ko",
                                                    engine: "O", original: line, translation: chained, sent: chainSvc.sentText(for: line, route: chainRoute))
        check("the log line keeps the screen text as `original` and adds `sent` where `before` changed it", loggedLine.contains("\"original\":\"A cat sat\",\"sent\":\"C cat sat\",\"translation\"")
              && !TranscriptFormat.jsonlLine(time: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!, lens: "L", app: chat, source: "en", target: "ko", engine: "O",
                                             original: line, translation: "x", sent: nil).contains("sent"), loggedLine)

        // MARK: A pattern that never returns is cut at the limit, turned off on the file's row, and the line goes on as it was (§5, §9)

        // On a connection of its own whose service is as young as can be, so launchd's hold on the next start (A3b) is there to be seen whatever the checks before took.
        let long = String(repeating: "a", count: 40) + "b"
        let d = ScriptConnection(startBudget: 5)
        let looped = ContextChecks.settings(engine, profiles: [profile(rows: [RewriteRow(.before, "(a+)+$", "s", regex: true)])])
        let told = Told()
        let (loopSvc, loopRoute) = await service(looped, runner: d)
        await loopSvc.setRewriteHandler { told.add($0) }
        _ = await d.start()
        let base = d.jobsSent, killsBefore = d.servicesKilled, startedBefore = d.servicesStarted
        start = mock.bodies.count
        let finished = Done()
        let hung = Task { () -> TranslationOutcome in
            let out = await loopSvc.translate([long], route: loopRoute, context: context)
            finished.value = true
            return out
        }
        // Until the service has the job, or the call is over (a pipeline that never asks it ends the wait, and the checks below say so).
        while d.jobsSent == base && !finished.value { await Task.yield() }
        // A call that waits behind the looping one is not timed while it waits, is not cut with it, and is answered by the fresh service.
        async let fine = d.regex(RewriteRow(.before, "x", "y", regex: true), on: "x", budgetMs: RewriteLimits.lineBudgetMs)
        let loopOut = await hung.value
        let cutTime = d.lastCutMs
        measured("(a+)+$ through the pipeline, limit \(Int(RewriteLimits.lineBudgetMs)) ms: cut after \(cutTime.map { String(Int($0)) } ?? "never") ms")
        check("(a+)+$ on a long aaaa…b line is cut within \(Int(RewriteLimits.lineBudgetMs)) ms + \(Int(RewriteChecks.slackMs)) ms, and the service is killed once",
              cutTime.map { $0 <= RewriteLimits.lineBudgetMs + RewriteChecks.slackMs } == true && d.servicesKilled == killsBefore + 1, "\(String(describing: cutTime)) killed \(d.servicesKilled - killsBefore)")
        check("the engine is sent the line as it was, and the translation comes back", requests(since: start) == [[long]] && loopOut.translations[long] != nil, "\(requests(since: start).map(\.count)) \(loopOut.translations.count)")
        var written = looped
        for unit in told.calls.flatMap({ $0 }) { written.turnOff(unit) }
        check("the unit that ran too long is reported once, and `on: false` goes on that row of the profile in the file's settings",
              told.calls == [[RewriteUnit(profile: chat, item: 0)]] && written.appProfiles[0].rewrites[0].on == false && !written.hasRewrites, "\(told.calls)")
        check("the cut call kept nothing of its own: no entry under the chain's fingerprint", !loopSvc.storeCounts.keys.contains { $0.contains("|rw:") }, "\(loopSvc.storeCounts.keys.sorted())")

        // A3b: the line right after the kill (the row is still on in these settings: the handler's `on: false` is in `written` only) is not held up by launchd's ~10 s. Its
        // rule is skipped, the engine is sent the line as it was, nothing is turned off, and the line is neither kept under the fingerprint nor passed off as rewritten.
        let ends = "I like banana"
        start = mock.bodies.count
        let rightAfter = now()
        let skipped = await loopSvc.translate([ends], route: loopRoute, context: context)
        let skippedMs = now() - rightAfter
        let skippedStores = loopSvc.storeCounts.keys.filter { $0.contains("|rw:") }
        measured("a lens line right after the kill: answered after \(Int(skippedMs)) ms with its rule skipped")
        check("a lens line right after a kill is not held up by launchd's restart: answered within 2 s (the wait is ~10 s), the engine sent the line as it was",
              skipped.translations[ends] != nil && skippedMs < 2_000 && requests(since: start) == [[ends]], "\(Int(skippedMs)) ms \(requests(since: start))")
        check("a line whose rules were skipped is said so in the log, is turned off nowhere, and is not kept under the fingerprint",
              loopSvc.rulesSkipped(for: ends, route: loopRoute) && told.calls.count == 1 && skippedStores.isEmpty
              && TranscriptFormat.jsonlLine(time: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!, lens: "L", app: chat, source: "en", target: "ko", engine: "O", original: ends,
                                            translation: "x", sent: loopSvc.sentText(for: ends, route: loopRoute), rulesSkipped: loopSvc.rulesSkipped(for: ends, route: loopRoute)).contains("\"rules\":\"skipped\""),
              "skipped \(loopSvc.rulesSkipped(for: ends, route: loopRoute)) told \(told.calls.count) stores \(skippedStores)")
        let answered = await fine
        check("a call queued behind a looping one is not cut with it, and the fresh service answers it", answered.outcome == .text("y") && d.servicesStarted == startedBefore + 1,
              "\(answered.outcome) started \(d.servicesStarted - startedBefore)")
        // The restart is over: the same line is rewritten now, from the engine's point of view too (the line skipped before was not kept, so it is asked again).
        start = mock.bodies.count
        let restored = await loopSvc.translate([ends], route: loopRoute, context: context)
        check("once the service is back the same line is rewritten (the final a becomes an s: banana → banans), and it is no longer marked skipped",
              requests(since: start) == [["I like banans"]] && restored.translations[ends] != nil && !loopSvc.rulesSkipped(for: ends, route: loopRoute),
              "\(requests(since: start)) skipped \(loopSvc.rulesSkipped(for: ends, route: loopRoute))")

        // MARK: Turning off, in the settings (§5)

        var all = ContextChecks.settings(engine, profiles: [profile(rows: [RewriteRow(.before, "a", "b"), RewriteRow(.after, "c", "d")], script: "function before(l) { return l }")])
        all.rewrites = [RewriteRow(.before, "x", "y")]
        all.script = RewriteScript(source: "function after(s, d) { return d }")
        var off = all
        off.turnOff(RewriteUnit(profile: chat, item: 1))
        off.turnOff(RewriteUnit(profile: chat, item: RewriteIssue.script))
        off.turnOff(RewriteUnit(profile: AppProfile.allAppsID, item: 0))
        off.turnOff(RewriteUnit(profile: AppProfile.allAppsID, item: RewriteIssue.script))
        check("turning a unit off writes `on: false` on that row or script and no other",
              off.appProfiles[0].rewrites.map(\.on) == [true, false] && off.appProfiles[0].script?.on == false && off.rewrites.map(\.on) == [false] && off.script?.on == false)
        var stale = all
        for unit in [RewriteUnit(profile: "gone", item: 0), RewriteUnit(profile: chat, item: 9), RewriteUnit(profile: AppProfile.allAppsID, item: 3)] { stale.turnOff(unit) }
        check("a unit that is not there any more is left alone", stale == all)

        return failed
    }
}
#endif
