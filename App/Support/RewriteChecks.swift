#if !MAS
import Foundation
import MwoyeoCore

/// The checks of the rewrite engine and the script service (docs/design/rewrite-rules.md §2-§5, §9; round rewrite-run), run by `--capture-ui … check-logic` and alone by
/// `rewrite-checks` (PASS/FAIL lines). The service is the real one, `Contents/XPCServices/MwoyeoScript.xpc`, driven through `ScriptConnection` and `RewriteSession`;
/// the time limit is a parameter of the session, so a gate shrinks it and waits for nothing but the cut itself. The request bytes of translation are part B's
/// (they need the stages in `TranslationService`).
@MainActor
enum RewriteChecks {
    /// What a gate allows beyond the limit for a cut (§9: "50 ms × lines + 100 ms").
    static let slackMs = 100.0

    private static let ctx = RewriteContext(app: "com.example.emu", profile: "p", source: "ja", target: "ko")

    private static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

    private static func gone(_ pid: Int32?) async -> Bool {
        guard let pid else { return false }
        // SIGKILL is at once, the reaping is launchd's: look until the pid is no longer there, with a bound for a pid that never goes.
        for _ in 0..<400 {
            if kill(pid, 0) != 0 { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    static func run() async -> Int {
        var failed = 0
        func check(_ what: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            print("check-logic: \(ok ? "PASS" : "FAIL") rewrite: \(what)" + (ok || detail().isEmpty ? "" : " [\(detail())]"))
            if !ok { failed += 1 }
        }
        /// What a gate measured, for the report (not a verdict).
        func measured(_ what: String) { print("check-logic: info rewrite: \(what)") }
        func layer(_ profile: String, rows: [RewriteRow] = [], script: String? = nil) -> RewriteLayer {
            RewriteLayer(profile: profile, rows: rows, script: script.map { RewriteScript(source: $0) })
        }
        func session(_ layers: [RewriteLayer], _ c: ScriptConnection, budget: Double = RewriteLimits.lineBudgetMs, context: RewriteContext = ctx, waits: Bool = true) -> RewriteSession {
            RewriteSession(plan: RewritePlan(chain: layers), context: context, runner: c, lineBudgetMs: budget, waitsForService: waits)
        }
        /// One line through `before` on the real service.
        func before(_ layers: [RewriteLayer], _ line: String, _ c: ScriptConnection) async -> (text: String, issues: [RewriteIssue]) {
            var s = session(layers, c)
            let text = await s.before(line)
            return (text, s.issues)
        }

        // MARK: The default path: nothing set, the service never starts

        let idle = ScriptConnection()
        var none = session([layer("p"), layer("all")], idle)
        let noneSent = await none.before("漢字（かんじ）"), noneShown = await none.after(src: noneSent, dst: "한자")
        check("no rows and no script: the lines are as they were and no connection is made", noneSent == "漢字（かんじ）" && noneShown == "한자" && idle.connectionsMade == 0 && idle.servicesStarted == 0,
              "connections \(idle.connectionsMade)")
        var plain = session([layer("p", rows: [RewriteRow(.before, "▼", ""), RewriteRow(.after, "...", "…")])], idle)
        let plainSent = await plain.before("▼次へ"), plainShown = await plain.after(src: plainSent, dst: "wait... what")
        check("plain rows only: they run in the app, and still no connection is made", plainSent == "次へ" && plainShown == "wait… what" && idle.connectionsMade == 0,
              "connections \(idle.connectionsMade): \(plainSent) / \(plainShown)")

        // MARK: The time limit, first death (§5, §9): a loop on a service as young as can be, and the call right after it (round rewrite-run, A3)

        // The service's first job is the loop, so it is killed as soon as it is up. launchd then holds the next start for what is left of ~10 s
        // (`ScriptConnection.launchThrottle`, measured 2026-10-21). A call that waits (the editor's try, `test_rules`) is answered after it, not turned away; a lens line (`waits` false,
        // A3b) is not made and passes as it was. That wait is launchd's: a gate
        // can shorten the number of times it waits (two deaths in this run, the idle exit after them), not the wait.
        // The start budget is a parameter, 5 s here: launchd's wait is ~10 s, so a hello that does not allow for it gives up well inside it (without the parameter the two are
        // within a few ms of each other, and the unfixed code passes by luck).
        let c = ScriptConnection(startBudget: 5)
        do {
            let lines = ["one", "two", "three"]
            let up = await c.start()
            let base = c.jobsSent
            let began = now()
            let loop = Task { () -> (out: [String], session: RewriteSession) in
                var s = session([layer("p", script: "function before(line, ctx) { while (true) {} }")], c)
                var out: [String] = []
                for line in lines { out.append(await s.before(line)) }
                return (out, s)
            }
            // The looping job is in the service. A lens call that comes now queues behind it (the gate), and when the loop is cut the service is down and launchd holds its
            // next start (round rewrite-run, A3b): the lens call is not made, it does not wait for the restart.
            for _ in 0..<200_000 where c.jobsSent == base { await Task.yield() }
            let queuedAt = now()
            let queued = await c.regex(RewriteRow(.before, "a", "b", regex: true), on: "a", budgetMs: RewriteLimits.lineBudgetMs, waits: false)
            let queuedMs = now() - queuedAt
            let (out, s) = await loop.value
            let took = now() - began
            let killed = c.lastKilledPid
            measured("while(true){} with limit \(Int(RewriteLimits.lineBudgetMs)) ms over \(lines.count) lines: cut after \(Int(took)) ms; the lens call queued behind it came back after \(Int(queuedMs)) ms")
            let unit = RewriteUnit(profile: "p", item: RewriteIssue.script)
            check("while(true){} is cut within \(Int(RewriteLimits.lineBudgetMs)) ms × \(lines.count) lines + \(Int(slackMs)) ms and the lines are as they were", up && took <= RewriteLimits.lineBudgetMs * Double(lines.count) + slackMs && out == lines, "\(Int(took)) ms")
            check("the looping script is turned off (once, not once per line) and its service is killed", s.turnedOff == [unit] && c.servicesKilled == 1 && killed != nil && s.issues.map(\.message) == [RewriteText.turnedOff],
                  "\(s.turnedOff) killed \(c.servicesKilled)")
            check("a lens call queued behind a call that is cut comes back held, within the line budget of the cut, and no service was started for it",
                  queued.outcome == .held && queuedMs <= RewriteLimits.lineBudgetMs + slackMs && c.servicesStarted == 1, "\(queued.outcome) after \(Int(queuedMs)) ms, started \(c.servicesStarted)")
            // A lens line right after the kill: unchanged, within the line budget, nothing turned off, and again no service started for it.
            var lens = session([layer("p", rows: [RewriteRow(.before, "a", "b", regex: true)], script: "function before(l) { return l + '!' }")], c, waits: false)
            let heldAt = now()
            let heldText = await lens.before("a")
            let heldMs = now() - heldAt
            check("a lens line right after a kill passes unchanged within the line budget: not waited for, nothing turned off, no error shown",
                  heldText == "a" && heldMs <= RewriteLimits.lineBudgetMs && lens.held.count == 2 && lens.turnedOff.isEmpty && lens.issues.isEmpty && c.servicesStarted == 1,
                  "\(heldText) after \(Int(heldMs)) ms held \(lens.held.count) off \(lens.turnedOff) issues \(lens.issues.count) started \(c.servicesStarted)")
            // The editor's try and `test_rules` wait. While one of them is waiting for the service, a lens line is not queued behind it.
            let asked = now()
            async let waiting = c.regex(RewriteRow(.before, "a", "b", regex: true), on: "a", budgetMs: 10_000)
            for _ in 0..<200_000 where !c.isStarting { await Task.yield() }
            let inFront = c.isStarting
            let behindAt = now()
            let behind = await c.regex(RewriteRow(.before, "a", "b", regex: true), on: "a", budgetMs: RewriteLimits.lineBudgetMs, waits: false)
            let behindMs = now() - behindAt
            let stillWaiting = c.isStarting
            let next = await waiting
            measured("the call right after the kill was answered after \(Int(now() - asked)) ms; a lens call beside it came back after \(Int(behindMs)) ms")
            let dead = await gone(killed)
            check("a lens call is not queued behind a call that is waiting out the restart: held within the line budget while that call is still waiting",
                  inFront && stillWaiting && behind.outcome == .held && behindMs <= RewriteLimits.lineBudgetMs, "front \(inFront) \(behind.outcome) after \(Int(behindMs)) ms, waiting \(stillWaiting)")
            check("the call right after a kill is answered by a fresh service, however young the killed one was", next.outcome == .text("b") && dead && c.servicePid != nil && c.servicePid != killed && c.servicesStarted == 2,
                  "\(next.outcome) old \(String(describing: killed)) gone \(dead), new \(String(describing: c.servicePid)), started \(c.servicesStarted)")
        }
        check("the hello is allowed the start's time and what is left of launchd's throttle, and no more",
              ScriptConnection.helloBudget(launchedAt: nil, now: 5, launchThrottle: 10, startBudget: 10) == 10 && abs(ScriptConnection.helloBudget(launchedAt: 4, now: 4.1, launchThrottle: 10, startBudget: 10) - 19.9) < 1e-9
              && ScriptConnection.helloBudget(launchedAt: 4, now: 14, launchThrottle: 10, startBudget: 10) == 10 && ScriptConnection.helloBudget(launchedAt: 4, now: 40, launchThrottle: 10, startBudget: 10) == 10)

        _ = await before([layer("p", rows: [RewriteRow(.before, "a", "b", regex: true)])], "a", idle)
        check("a regex row connects once (so the zeros above are not vacuous)", idle.connectionsMade == 1 && idle.servicesStarted == 1, "connections \(idle.connectionsMade), services \(idle.servicesStarted)")

        // MARK: Regex rows (§2): flags gu, $1, every occurrence

        let furigana = RewriteRow(.before, "（[ぁ-ゖ]+）", "", regex: true)
        let r1 = await before([layer("p", rows: [furigana])], "漢字（かんじ）と言葉（ことば）", c)
        check("a regex row drops the furigana after every kanji", r1.text == "漢字と言葉" && r1.issues.isEmpty, r1.text)
        let r2 = await before([layer("p", rows: [RewriteRow(.before, "第(\\d+)章", "Chapter $1", regex: true)])], "第12章と第3章", c)
        check("$1 is the first group of the match", r2.text == "Chapter 12とChapter 3", r2.text)
        let r3 = await before([layer("p", rows: [RewriteRow(.before, "^.$", "x", regex: true)])], "😀", c)
        check("the u flag is on: one astral character is one character", r3.text == "x", r3.text)
        let r4 = await before([layer("p", rows: [RewriteRow(.before, "A", "b", regex: true)])], "AaAa", c)
        check("a regex row is case-sensitive and global (flags gu)", r4.text == "baba", r4.text)

        // MARK: Scripts (§3): the two examples, ctx, nothing between lines

        let examples = "function before(line, ctx) { return line.replace(/（[ぁ-ゖ]+）/gu, \"\") }\nfunction after(src, dst, ctx) { return ctx.target === \"ko\" ? dst.replace(/\\.\\.\\./g, \"…\") : dst }"
        var ex = session([layer("p", script: examples)], c)
        let exSent = await ex.before("漢字（かんじ）"), exShown = await ex.after(src: exSent, dst: "한자...")
        check("the two examples of §3 run: furigana dropped before, ... → … after", exSent == "漢字" && exShown == "한자…" && ex.issues.isEmpty, "\(exSent) / \(exShown) \(ex.issues)")
        var ko = session([layer("p", script: examples)], c, context: RewriteContext(app: "", profile: "p", source: "auto", target: "en"))
        let enShown = await ko.after(src: "x", dst: "a...")
        check("ctx.target is the lens's target (en keeps the dots)", enShown == "a...", enShown)
        let seeCtx = "function before(line, ctx) { return [ctx.app, ctx.profile, ctx.source, ctx.target, Object.keys(ctx).length].join('|') }"
        let seen = await before([layer("prof-7", script: seeCtx)], "x", c)
        check("ctx is {app, profile, source, target} and nothing else", seen.text == "com.example.emu|prof-7|ja|ko|4", seen.text)
        let counter = "var n = (typeof n === 'number' ? n : 0) + 1; globalThis.kept = (globalThis.kept || 0) + 1; function before(line, ctx) { return line + kept + n }"
        var twice = session([layer("p", script: counter)], c)
        let first = await twice.before("x"), second = await twice.before("x")
        check("a fresh global object per call: no state is kept between lines", first == "x11" && second == "x11", "\(first) \(second)")
        let clock = await before([layer("p", script: "function before(line, ctx) { return typeof Date + ',' + typeof Math.random + ',' + typeof setTimeout + ',' + typeof fetch }")], "x", c)
        check("no clock, no random, no timers and no network in the global", clock.text == "undefined,undefined,undefined,undefined", clock.text)
        let arrow = await before([layer("p", script: "const before = (line) => line + '!'")], "x", c)
        check("a function declared with const is found", arrow.text == "x!", arrow.text)
        let afterOnly = await before([layer("p", script: "function after(src, dst) { return dst }")], "keep", c)
        check("a script with only after leaves the source as it is, with no error", afterOnly.text == "keep" && afterOnly.issues.isEmpty, "\(afterOnly)")

        // MARK: Errors (§5): the line stays, the script stays on

        let pidBefore = c.servicePid, killedBefore = c.servicesKilled
        let thrown = await before([layer("p", script: "function before(line, ctx) {\n  var x = 1;\n    throw new Error('boom');\n}")], "keep", c)
        check("a throw leaves the line unchanged and says where", thrown.text == "keep" && thrown.issues.count == 1 && thrown.issues[0].message == "Error: boom"
              && thrown.issues[0].line == 3 && thrown.issues[0].column != nil && thrown.issues[0].item == RewriteIssue.script && thrown.issues[0].stage == .before, "\(thrown)")
        var staysOn = session([layer("p", script: "function before(line, ctx) { throw new Error('boom') }")], c)
        _ = await staysOn.before("a"); _ = await staysOn.before("b")
        check("a throw does not turn the script off, and the service lives on", staysOn.turnedOff.isEmpty && staysOn.issues.count == 2 && c.servicePid == pidBefore && c.servicesKilled == killedBefore,
              "pid \(String(describing: pidBefore)) → \(String(describing: c.servicePid))")
        let number = await before([layer("p", script: "function before(line, ctx) { return 42 }")], "keep", c)
        check("a return that is not text leaves the line and says so", number.text == "keep" && number.issues.map(\.message) == [RewriteText.notText("before", "number")], "\(number)")
        let nothing = await before([layer("p", script: "function before(line, ctx) { }")], "keep", c)
        check("a function that returns nothing is an error too", nothing.text == "keep" && nothing.issues.map(\.message) == [RewriteText.notText("before", "undefined")], "\(nothing)")
        func repeating(_ n: Int) -> String { "function before(line, ctx) { return 'x'.repeat(\(n)) }" }
        let edge = 4 * 3 + RewriteLimits.replySlack
        let atLimit = await before([layer("p", script: repeating(edge))], "abc", c)
        let over = await before([layer("p", script: repeating(edge + 1))], "abc", c)
        check("a reply of 4 × the input + 200 passes and one more character is an error", atLimit.text.count == edge && atLimit.issues.isEmpty && over.text == "abc" && over.issues.map(\.message) == [RewriteText.replyTooLong("before")],
              "\(atLimit.text.count) \(over.text.count) \(over.issues)")
        let deep = await before([layer("p", script: "function before(line, ctx) { return before(line) }")], "keep", c)
        check("runaway recursion is an error, not a crash", deep.text == "keep" && deep.issues.count == 1 && deep.issues[0].message.contains("RangeError") && c.servicesKilled == killedBefore, "\(deep)")

        // MARK: Check time (§2, §3): the pure rules and the service's

        let bad = await c.check(rows: [RewriteRow(.before, "(", regex: true), RewriteRow(.before, "ok", regex: true), RewriteRow(.after, "", "x")], script: nil)
        check("a pattern that does not compile is reported with its row and JavaScriptCore's words; a good one is not", bad.issues.count == 2 && bad.issues.contains { $0.item == 0 && $0.message.contains("Invalid regular expression") }
              && bad.issues.contains { $0.item == 2 && $0.message == "find is empty" }, "\(bad.issues)")
        let syntax = await c.check(rows: [], script: RewriteScript(source: "function before(line, ctx) {\n  return line.replace(/a/g, \n  ;\n}\n"))
        check("a syntax error is reported with its line", syntax.issues.count == 1 && syntax.issues[0].item == RewriteIssue.script && syntax.issues[0].line == 3 && syntax.issues[0].message.contains("SyntaxError"), "\(syntax.issues)")
        let neither = await c.check(rows: [], script: RewriteScript(source: "var x = 1;"))
        check("a script that defines neither function is reported", neither.issues.count == 1 && neither.issues[0].message.contains("neither"), "\(neither.issues)")
        let both = await c.check(rows: [RewriteRow(.before, "a", "b")], script: RewriteScript(source: examples))
        let onlyAfter = await c.check(rows: [], script: RewriteScript(source: "function after(src, dst) { return dst }"))
        check("a good script and table pass, and the functions it defines are named", both.issues.isEmpty && both.defines == [.before, .after] && onlyAfter.issues.isEmpty && onlyAfter.defines == [.after],
              "\(both) \(onlyAfter)")
        let started = c.jobsSent
        let tooLong = await c.check(rows: [RewriteRow(.before, "a", "b")], script: RewriteScript(source: String(repeating: "a", count: 8_001)))
        check("a script over 8,000 characters is reported and not sent; plain rows alone ask nothing of the service", tooLong.issues.map(\.message) == ["script is 8001 characters; the most is 8000"] && c.jobsSent == started,
              "\(tooLong.issues) sent \(c.jobsSent - started)")

        // MARK: The order of §4 on a two-profile chain, through the real service (§9)

        // line 0: all's table (plain, regex), all's script, app's table (plain needs all's plain row, regex), app's script. Then the answer T: app's script, app's
        // table (plain, regex), all's script, all's table (plain needs app's plain row, regex). A row of the other stage sits between the rows of each table.
        let tag = "function before(l, c) { return l + '{b:' + c.profile + '}' }\nfunction after(s, d, c) { return d + '{a:' + c.profile + '|' + s.length + '}' }"
        let all = layer("all", rows: [RewriteRow(.before, "0", "0a"), RewriteRow(.after, "Tt", "TtX"), RewriteRow(.before, "a$", "a<R1>", regex: true), RewriteRow(.after, "\\}$", "}<R4>", regex: true)], script: tag)
        let app = layer("app", rows: [RewriteRow(.before, "0a", "0ab"), RewriteRow(.after, "T", "Tt"), RewriteRow(.before, "\\{b:all\\}$", "{b:all}<R2>", regex: true), RewriteRow(.after, "\\}$", "}<R3>", regex: true)], script: tag)
        var ordered = session([app, all], c)
        let sent = await ordered.before("0")
        let shown = await ordered.after(src: sent, dst: "T")
        let n = sent.utf16.count
        check("before runs broad → narrow: all's table then script, then app's", sent == "0ab<R1>{b:all}<R2>{b:app}", sent)
        check("after runs narrow → broad: app's script then table, then all's", shown == "TtX{a:app|\(n)}<R3>{a:all|\(n)}<R4>", shown)
        check("the order run raised no error and turned nothing off", ordered.issues.isEmpty && ordered.turnedOff.isEmpty, "\(ordered.issues)")


        // MARK: The rewrites in the translation path, and the time limit's second death (§4, §5, §9): (a+)+$ on a long "aaaa…b" line through the pipeline

        failed += await RewritePipelineChecks.run(through: c)

        // MARK: The settings file's keys (§1-§3), and `profilePin` taking null (A5)

        failed += SettingsFileChecks.rewriteKeys()

        // MARK: Exit when idle (§5)

        do {
            // Last, because the service is the app's one: its exit is every connection's. The next call after it is a fresh start as after a kill (the gates above).
            let t = ScriptConnection(idleAfter: 0.05)
            let events = t.events()
            _ = await t.regex(RewriteRow(.before, "a", "b", regex: true), on: "a", budgetMs: 10_000)
            let pid = t.servicePid
            let exited: Bool = await withTaskGroup(of: Bool.self) { group in
                group.addTask { for await event in events { if case .idleExit = event { return true } }; return false }
                group.addTask { try? await Task.sleep(nanoseconds: 20_000_000_000); return false }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            let dead = await gone(pid)
            check("an idle service exits after idleAfter, and its connection forgets it", exited && dead && pid != nil && t.servicePid == nil, "exited \(exited) gone \(dead) pid \(String(describing: t.servicePid))")
        }

        return failed
    }
}
#endif
