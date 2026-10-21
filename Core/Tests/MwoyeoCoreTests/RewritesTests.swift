import Foundation
import Testing
@testable import MwoyeoCore

/// Rewrite rules and scripts (docs/design/rewrite-rules.md §2-§5, §9): the strict checks, the plain rows, the order of §4 over a chain, the
/// cache fingerprint and the wire. The service's JavaScript is not here: its gates run the real service (`App/Support/RewriteChecks.swift`).
@Suite struct RewritesTests {
    /// Stands for the service: regex rows append `[re:<find>]`, scripts append `[<stage>:<profile>]`, and it counts its calls.
    private final class Fake: RewriteRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        var calls: [String] { lock.withLock { log } }
        var cost: @Sendable (String) -> Double = { _ in 1 }
        var outcome: @Sendable (String, String) -> RewriteRun.Outcome? = { _, _ in nil }
        private(set) var contexts: [RewriteContext] = []
        /// What each call said about waiting for a held service (`waits`).
        private(set) var waits: [Bool] = []

        func regex(_ row: RewriteRow, on text: String, budgetMs: Double, waits: Bool) async -> RewriteRun {
            let name = "re:\(row.find)"
            lock.withLock { log.append(name); self.waits.append(waits) }
            return RewriteRun(outcome(name, text) ?? .text(text + "[\(name)]"), usedMs: cost(name))
        }

        func script(_ script: RewriteScript, stage: RewriteStage, text: String, src: String, context: RewriteContext, budgetMs: Double, waits: Bool) async -> RewriteRun {
            let name = "\(stage.rawValue):\(context.profile)"
            lock.withLock { log.append(name); contexts.append(context); self.waits.append(waits) }
            return RewriteRun(outcome(name, text) ?? .text(text + "[\(name)]"), usedMs: cost(name))
        }
    }

    private let ctx = RewriteContext(app: "com.example.emu", profile: "ignored", source: "ja", target: "ko")

    /// A chain of two profiles of every kind of step in both stages, the head first: the row order puts a stage-skipped row in the middle.
    private var chain: [RewriteLayer] {
        [RewriteLayer(profile: "app",
                      rows: [RewriteRow(.before, "0a", "0ab"), RewriteRow(.before, "R2", regex: true),
                             RewriteRow(.after, "T", "Tt"), RewriteRow(.after, "R3", regex: true)],
                      script: RewriteScript(source: "function before(l){return l}")),
         RewriteLayer(profile: "all",
                      rows: [RewriteRow(.before, "0", "0a"), RewriteRow(.before, "R1", regex: true),
                             RewriteRow(.after, "Tt", "TtX"), RewriteRow(.after, "R4", regex: true)],
                      script: RewriteScript(source: "function after(s,d){return d}"))]
    }

    // MARK: The types

    @Test func aRowKeepsItsDefaultsOutOfTheFile() throws {
        let plain = RewriteRow(.before, "▼")
        let json = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(!json.contains("regex") && !json.contains("\"on\""))
        #expect(try JSONDecoder().decode(RewriteRow.self, from: Data(#"{"stage":"after","find":"...","replace":"…"}"#.utf8)) == RewriteRow(.after, "...", "…"))
        let all = RewriteRow(.after, "（[ぁ-ゖ]+）", "", regex: true, on: false)
        #expect(try JSONDecoder().decode(RewriteRow.self, from: JSONEncoder().encode(all)) == all)
        // A script is on unless the file says it is not.
        #expect(try JSONDecoder().decode(RewriteScript.self, from: Data(#"{"source":"function before(l){return l}"}"#.utf8)).on)
        #expect(try JSONDecoder().decode(RewriteScript.self, from: Data(#"{"source":"x","on":false}"#.utf8)).on == false)
    }

    // MARK: Strict checks (§2, §3)

    @Test func aThirtyThirdRowIsReportedAndTheRestDropped() {
        let rows = (0..<33).map { RewriteRow(.before, "f\($0)", "r") }
        let issues = RewriteCheck.rows(rows)
        #expect(issues.map(\.item) == [32])
        #expect(issues.first?.message.contains("the most is 32") == true)
        #expect(RewriteCheck.rows(Array(rows.prefix(32))).isEmpty)
        let decoded = RewriteCheck.decode(rows: rows.map { ["stage": "before", "find": $0.find, "replace": "r"] as [String: Any] })
        #expect(decoded.rows.count == 32 && decoded.issues.count == 1)
    }

    @Test func anEmptyFindAndFieldsOverTwoHundredAreReported() {
        let long = String(repeating: "あ", count: 201)
        #expect(RewriteCheck.rows([RewriteRow(.before, "")]).map(\.message) == ["find is empty"])
        #expect(RewriteCheck.rows([RewriteRow(.before, long)]).map(\.message) == ["find is 201 characters; the most is 200"])
        #expect(RewriteCheck.rows([RewriteRow(.before, String(repeating: "あ", count: 200), String(repeating: "x", count: 200))]).isEmpty)
        #expect(RewriteCheck.rows([RewriteRow(.after, "a", long)]).map(\.message) == ["replace is 201 characters; the most is 200"])
        // Characters, not bytes: 200 Japanese characters are 600 bytes.
        #expect(RewriteCheck.rows([RewriteRow(.before, String(repeating: "あ", count: 200))]).isEmpty)
        #expect(RewriteCheck.rows([RewriteRow(.before, "a", "")]).isEmpty)
    }

    @Test func aScriptOverEightThousandCharactersIsReported() {
        #expect(RewriteCheck.script(RewriteScript(source: String(repeating: "a", count: 8_000))).isEmpty)
        let issues = RewriteCheck.script(RewriteScript(source: String(repeating: "a", count: 8_001)))
        #expect(issues.map(\.message) == ["script is 8001 characters; the most is 8000"] && issues.first?.item == RewriteIssue.script)
    }

    @Test func aFileRowThatIsWrongIsReportedAndDroppedTheOthersStay() throws {
        // As the settings file is read: JSON through JSONSerialization, where a number bridges to Bool unless it is looked at.
        let raw = try #require(JSONSerialization.jsonObject(with: Data("""
            [{"stage":"before","find":"▼","replace":""},
             {"stage":"during","find":"a"},
             {"stage":"after","find":""},
             {"stage":"after"},
             {"stage":"after","find":"a","regexp":true},
             {"stage":"after","find":"a","regex":1},
             {"stage":"after","find":"a","on":"yes"},
             {"stage":"after","find":"a","replace":3},
             "text",
             {"stage":"after","find":"...","replace":"…","regex":false,"on":true}]
            """.utf8)) as? [Any])
        let decoded = RewriteCheck.decode(rows: raw)
        #expect(decoded.rows == [RewriteRow(.before, "▼"), RewriteRow(.after, "...", "…")])
        #expect(Set(decoded.issues.map(\.item)) == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(decoded.issues.first { $0.item == 1 }?.message == "stage must be \"before\" or \"after\"")
        #expect(decoded.issues.first { $0.item == 4 }?.message == "unknown field \"regexp\"")
        #expect(decoded.issues.first { $0.item == 5 }?.message == "regex must be true or false")
        #expect(decoded.issues.first { $0.item == 6 }?.message == "on must be true or false")
    }

    @Test func anIssueReadsAsOneLine() {
        #expect(RewriteIssue(stage: .after, item: 3, message: "boom").description == "rewrites[3] (after): boom")
        #expect(RewriteIssue(stage: .before, item: RewriteIssue.script, line: 3, column: 12, message: "boom").description == "script, line 3, column 12 (before): boom")
    }

    @Test func aRunawayReplyIsFourTimesTheInputPlusTwoHundred() {
        #expect(!RewriteLimits.replyTooLong(input: 10, output: 240))
        #expect(RewriteLimits.replyTooLong(input: 10, output: 241))
        #expect(!RewriteLimits.replyTooLong(input: 0, output: 200) && RewriteLimits.replyTooLong(input: 0, output: 201))
    }

    // MARK: Plain rows (§2)

    @Test func aPlainRowReplacesEveryOccurrenceCaseSensitiveWithNoFolding() {
        func apply(_ find: String, _ replace: String, _ text: String) -> String { RewriteEngine.apply(RewriteRow(.before, find, replace), to: text) }
        #expect(apply("▼", "", "▼次へ▼") == "次へ")
        #expect(apply("セーブしますか？", "Save?", "セーブしますか？ はい セーブしますか？") == "Save? はい Save?")
        #expect(apply("a", "b", "aAaA") == "bAbA")
        #expect(apply("...", "…", "wait... what.... no") == "wait… what…. no")
        // Non-overlapping from the left, as a JavaScript replace does it.
        #expect(apply("aa", "b", "aaa") == "ba")
        #expect(apply("aa", "b", "aaaa") == "bb")
        // No folding: width, accents and canonical equivalence are not merged.
        #expect(apply("é", "e", "e\u{301}é") == "e\u{301}e")
        #expect(apply("ａ", "x", "aａ") == "ax")
        #expect(apply("x", "y", "") == "" && apply("long needle", "y", "short") == "short")
        // The replacement is text, not a template: `$1` and `\` stay as written.
        #expect(apply("a", "$1\\n", "a") == "$1\\n")
    }

    @Test func aPlainRowIsLinearInTheLinePlusTheFind() {
        // The worst line for a naive search: n a's and a find of 199 a's and a b. Naive compares ~ 199 × n; KMP at most 2 × n.
        let n = 100_000
        let text = String(repeating: "a", count: n)
        let find = String(repeating: "a", count: 199) + "b"
        var steps = 0
        #expect(RewriteEngine.replaceAll(in: text, find: find, with: "x", steps: &steps) == text)
        #expect(steps <= 2 * n + 2 * find.utf8.count, "steps \(steps)")
        var many = 0
        let hit = RewriteEngine.replaceAll(in: String(repeating: "ab", count: n / 2), find: "ab", with: "", steps: &many)
        #expect(hit.isEmpty && many <= 2 * n)
    }

    // MARK: The order (§4)

    @Test func beforeRunsBroadToNarrowAndAfterNarrowToBroadTableAndScriptEachWay() async {
        let fake = Fake()
        var session = RewriteSession(plan: RewritePlan(chain: chain), context: ctx, runner: fake)
        let sent = await session.before("0")
        // all: table (plain, regex), script; then app: table, script. The plain row of app needs all's plain row's result.
        #expect(sent == "0ab[re:R1][before:all][re:R2][before:app]")
        #expect(fake.calls == ["re:R1", "before:all", "re:R2", "before:app"])
        let shown = await session.after(src: sent, dst: "T")
        // app: script, table (plain, regex); then all: script, table. all's plain row needs app's plain row's result.
        #expect(shown == "TtX[after:app][re:R3][after:all][re:R4]")
        #expect(Array(fake.calls.dropFirst(4)) == ["after:app", "re:R3", "after:all", "re:R4"])
        #expect(session.issues.isEmpty && session.turnedOff.isEmpty)
    }

    @Test func aScriptIsToldItsOwnProfileAndTheLenssAppAndLanguages() async {
        let fake = Fake()
        var session = RewriteSession(plan: RewritePlan(chain: chain), context: ctx, runner: fake)
        _ = await session.before("0")
        #expect(fake.contexts.map(\.profile) == ["all", "app"])
        #expect(fake.contexts.allSatisfy { $0.app == "com.example.emu" && $0.source == "ja" && $0.target == "ko" })
    }

    @Test func aRowOfTheOtherStageIsSkippedAndAnOffRowOrScriptIsNotRun() async {
        let fake = Fake()
        let layers = [RewriteLayer(profile: "p",
                                   rows: [RewriteRow(.before, "a", "b", on: false), RewriteRow(.after, "x", "y"), RewriteRow(.before, "R", regex: true, on: false)],
                                   script: RewriteScript(source: "function before(l){return l}", on: false))]
        var session = RewriteSession(plan: RewritePlan(chain: layers), context: ctx, runner: fake)
        #expect(await session.before("a x") == "a x")
        #expect(await session.after(src: "a x", dst: "a x") == "a y")
        #expect(fake.calls.isEmpty)
    }

    // MARK: The default path (§5)

    @Test func noRewriteAndNoScriptNeedsNoServiceAndTheRunnerIsNeverCalled() async {
        let none = RewritePlan(chain: [RewriteLayer(profile: "app"), RewriteLayer(profile: "all")])
        #expect(none.isEmpty && !none.needsService && none.fingerprint(app: "x") == nil && none.namespaceSuffix(app: "x") == "")
        // Plain rows run in the app: the plan is not empty but needs no service.
        let plain = RewritePlan(chain: [RewriteLayer(profile: "all", rows: [RewriteRow(.before, "a", "b"), RewriteRow(.after, "c", "d")])])
        #expect(!plain.isEmpty && !plain.needsService)
        let fake = Fake()
        var session = RewriteSession(plan: plain, context: ctx, runner: fake)
        #expect(await session.before("aaa") == "bbb")
        #expect(await session.after(src: "bbb", dst: "ccc") == "ddd")
        #expect(fake.calls.isEmpty)
        // Only an active regex row or script needs the service.
        #expect(RewritePlan(chain: [RewriteLayer(profile: "all", rows: [RewriteRow(.before, "a", regex: true)])]).needsService)
        #expect(RewritePlan(chain: [RewriteLayer(profile: "all", script: RewriteScript(source: "x"))]).needsService)
        #expect(!RewritePlan(chain: [RewriteLayer(profile: "all", rows: [RewriteRow(.before, "a", regex: true, on: false)],
                                                  script: RewriteScript(source: "x", on: false))]).needsService)
        #expect(!RewritePlan(chain: [RewriteLayer(profile: "all", script: RewriteScript(source: ""))]).needsService)
    }

    // MARK: Time, failures (§5)

    @Test func aFailureLeavesThatStepsTextAndTheUnitOn() async {
        let fake = Fake()
        fake.outcome = { name, _ in name == "before:app" ? .failed(RewriteFailure("Error: boom", line: 3, column: 20)) : nil }
        var session = RewriteSession(plan: RewritePlan(chain: chain), context: ctx, runner: fake)
        let sent = await session.before("0")
        #expect(sent == "0ab[re:R1][before:all][re:R2]")
        #expect(session.issues == [RewriteIssue(stage: .before, item: RewriteIssue.script, line: 3, column: 20, message: "Error: boom")])
        #expect(session.turnedOff.isEmpty)
        // The next line runs it again.
        _ = await session.before("0")
        #expect(fake.calls.filter { $0 == "before:app" }.count == 2)
    }

    @Test func aUnitThatTimesOutIsTurnedOffAndSkippedForTheRestOfTheBatch() async {
        let fake = Fake()
        fake.outcome = { name, _ in name == "before:all" ? .timedOut : nil }
        var session = RewriteSession(plan: RewritePlan(chain: chain), context: ctx, runner: fake)
        #expect(await session.before("0") == "0ab[re:R1][re:R2][before:app]")
        #expect(session.turnedOff == [RewriteUnit(profile: "all", item: RewriteIssue.script)])
        #expect(session.issues.map(\.message) == [RewriteText.turnedOff])
        _ = await session.before("0")
        _ = await session.after(src: "x", dst: "T")
        // One call in the whole batch, not one per line and stage: its script is off in `after` too.
        #expect(fake.calls.filter { $0.hasSuffix(":all") }.count == 1)
    }

    @Test func aHeldCallPassesTheTextAndTurnsNothingOffAndTheSessionSaysWhichUnits() async {
        let fake = Fake()
        // The service is held back for the script of "all"; the regex rows of both profiles and the script of "app" still run.
        fake.outcome = { name, _ in name == "before:all" ? .held : nil }
        var session = RewriteSession(plan: RewritePlan(chain: chain), context: ctx, runner: fake, waitsForService: false)
        #expect(await session.before("0") == "0ab[re:R1][re:R2][before:app]")
        #expect(session.held == [RewriteUnit(profile: "all", item: RewriteIssue.script)])
        #expect(session.turnedOff.isEmpty && session.issues.isEmpty)
        // Asked again on the next line (a held call is not a verdict on the unit): one more call, one more entry.
        _ = await session.before("0")
        #expect(fake.calls.filter { $0 == "before:all" }.count == 2 && session.held.count == 2 && session.turnedOff.isEmpty)
        // The lens's session says it does not wait, the default one does.
        #expect(fake.waits.allSatisfy { $0 == false } && !fake.waits.isEmpty)
        let patient = Fake()
        var waiting = RewriteSession(plan: RewritePlan(chain: chain), context: ctx, runner: patient)
        _ = await waiting.before("0")
        #expect(patient.waits.allSatisfy { $0 } && !patient.waits.isEmpty && waiting.held.isEmpty)
    }

    @Test func aProfilesRegexRowsShareOneLineBudgetAndTheOneThatRunsOutIsTurnedOff() async {
        let fake = Fake()
        fake.cost = { _ in 20 }
        let rows = (1...3).map { RewriteRow(.before, "R\($0)", regex: true) }
        var session = RewriteSession(plan: RewritePlan(chain: [RewriteLayer(profile: "p", rows: rows)]), context: ctx, runner: fake, lineBudgetMs: 50)
        // 20 + 20 = 40 ms spent, 10 ms left for the third; it takes 20 and is not cut here (the fake does not cut), but a fourth would have none.
        #expect(await session.before("x") == "x[re:R1][re:R2][re:R3]")
        let four = (1...4).map { RewriteRow(.before, "R\($0)", regex: true) }
        var other = RewriteSession(plan: RewritePlan(chain: [RewriteLayer(profile: "p", rows: four)]), context: ctx, runner: fake, lineBudgetMs: 50)
        #expect(await other.before("x") == "x[re:R1][re:R2][re:R3]")
        #expect(other.turnedOff == [RewriteUnit(profile: "p", item: 3)])
        // The budget is per profile and per line: another profile, or the next line, starts again.
        var two = RewriteSession(plan: RewritePlan(chain: [RewriteLayer(profile: "a", rows: Array(rows.prefix(2))), RewriteLayer(profile: "b", rows: Array(rows.prefix(2)))]),
                                 context: ctx, runner: fake, lineBudgetMs: 50)
        #expect(await two.before("x") == "x[re:R1][re:R2][re:R1][re:R2]" && two.turnedOff.isEmpty)
        #expect(await two.before("y") == "y[re:R1][re:R2][re:R1][re:R2]" && two.turnedOff.isEmpty)
    }

    // MARK: Cache namespace (§4)

    @Test func theFingerprintIsNilWithNothingOnAndMovesWithAnythingThatChangesAnAnswer() {
        func fp(_ layers: [RewriteLayer], app: String? = nil) -> String? { RewritePlan(chain: layers).fingerprint(app: app) }
        let base = RewriteLayer(profile: "all", rows: [RewriteRow(.before, "a", "b"), RewriteRow(.after, "c", "d", regex: true)])
        #expect(fp([]) == nil && fp([RewriteLayer(profile: "all")]) == nil)
        let one = fp([base])
        #expect(one != nil && one == fp([base]) && one?.count ?? 0 > 0)
        #expect(RewritePlan(chain: [base]).namespaceSuffix(app: nil) == "|rw:\(one ?? "")")
        // Each field of a row, the order of rows and the order of layers.
        var edited = base
        edited.rows[0].replace = "c"
        #expect(fp([edited]) != one)
        edited = base; edited.rows[1].regex = false
        #expect(fp([edited]) != one)
        edited = base; edited.rows[0].stage = .after
        #expect(fp([edited]) != one)
        edited = base; edited.rows.reverse()
        #expect(fp([edited]) != one)
        let other = RewriteLayer(profile: "p", rows: [RewriteRow(.before, "x", "y")])
        #expect(fp([base, other]) != fp([other, base]))
        // A row that is off is a row that is not there.
        var off = base
        off.rows.append(RewriteRow(.before, "z", "q", on: false))
        #expect(fp([off]) == one)
        // Pieces do not run together: two rows are not one row of their joined text.
        #expect(fp([RewriteLayer(profile: "a", rows: [RewriteRow(.before, "ab", "c")])]) != fp([RewriteLayer(profile: "a", rows: [RewriteRow(.before, "a", "bc")])]))
        // A script: its source and its profile (ctx.profile) and, with a script only, the app (ctx.app).
        let scripted = RewriteLayer(profile: "p", script: RewriteScript(source: "function before(l){return l}"))
        #expect(fp([scripted], app: "x") != fp([scripted], app: "y") && fp([scripted], app: "x") == fp([scripted], app: "x"))
        var moved = scripted; moved.profile = "q"
        #expect(fp([moved], app: "x") != fp([scripted], app: "x"))
        var changed = scripted; changed.script?.source += " "
        #expect(fp([changed], app: "x") != fp([scripted], app: "x"))
        #expect(fp([base], app: "x") == fp([base], app: "y"))
    }

    // MARK: The chain and the file (part B)

    private func profile(_ id: String, rows: [RewriteRow] = [], script: RewriteScript? = nil) -> AppProfile {
        var p = AppProfile(bundleID: id, appName: id, source: "ja", target: "ko")
        p.rewrites = rows
        p.script = script
        return p
    }

    @Test func aChainsPlanTakesEachProfilesOwnRewritesAndAllAppsForTheBase() async {
        let narrow = profile("game", rows: [RewriteRow(.before, "1", "g")], script: RewriteScript(source: "function before(l){return l}"))
        let broad = profile("emu", rows: [RewriteRow(.before, "2", "e")])
        let plan = RewritePlan(links: [.profile(narrow), .profile(broad), .allApps], allAppsRows: [RewriteRow(.before, "3", "a")], allAppsScript: nil)
        #expect(plan.layers.map(\.profile) == ["game", "emu", "all"])
        #expect(plan.layers.map(\.rows) == [narrow.rewrites, broad.rewrites, [RewriteRow(.before, "3", "a")]] && plan.layers[0].script?.source == "function before(l){return l}")
        // `before` is broad → narrow over it: All apps' row first, then the app's, then the game's.
        let fake = Fake()
        var session = RewriteSession(plan: plan, context: ctx, runner: fake)
        #expect(await session.before("123") == "gea[before:game]" && fake.calls == ["before:game"])
        #expect(plan.steps(.before).map(\.unit.profile) == ["all", "emu", "game", "game"])
        #expect(plan.isEmpty == false && plan.needsService)
    }

    @Test func aChainWithNothingSetIsEmptyAndHasNoNamespace() {
        let plan = RewritePlan(links: [.profile(profile("game")), .allApps], allAppsRows: [], allAppsScript: nil)
        #expect(plan.isEmpty && !plan.needsService && plan.namespaceSuffix(app: "x") == "")
        // A script or a row that is off is not set.
        let off = RewritePlan(links: [.profile(profile("game", rows: [RewriteRow(.before, "a", "b", on: false)], script: RewriteScript(source: "x", on: false))), .allApps],
                              allAppsRows: [], allAppsScript: RewriteScript(source: "", on: true))
        #expect(off.isEmpty)
    }

    @Test func aProfileFileKeepsRewritesAndScriptAndWritesThemOnlyWhenSet() throws {
        let plain = ProfileFile(id: "p", name: "P", source: "ja", target: "ko")
        let plainJSON = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(!plainJSON.contains("rewrites") && !plainJSON.contains("script"))
        let set = ProfileFile(id: "p", name: "P", source: "ja", target: "ko", rewrites: [RewriteRow(.before, "▼"), RewriteRow(.after, "...", "…", regex: true, on: false)],
                              script: RewriteScript(source: "function before(l){return l}", on: false))
        let back = try JSONDecoder().decode(ProfileFile.self, from: JSONEncoder().encode(set))
        #expect(back == set && back.profile.rewrites == set.rewrites && back.profile.script == set.script)
        #expect(ProfileFile(set.profile).rewrites == set.rewrites)
        // A row this build cannot read is left out and the others stay, in order; a script that cannot be read is none.
        let json = #"{"id":"p","name":"P","source":"ja","target":"ko","rewrites":[{"stage":"before","find":"a"},{"stage":"during","find":"b"},{"stage":"after","find":"c","replace":"d"}],"script":{"on":true}}"#
        let lenient = try JSONDecoder().decode(ProfileFile.self, from: Data(json.utf8))
        #expect(lenient.rewrites == [RewriteRow(.before, "a"), RewriteRow(.after, "c", "d")] && lenient.script == nil)
    }

    @Test func aLogLineHasSentOnlyWhereBeforeChangedTheLine() {
        func line(sent: String?) -> String {
            TranscriptFormat.jsonlLine(time: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!, lens: "L", app: "a", source: "ja", target: "ko", engine: "apple",
                                       original: "漢字（かんじ）", translation: "한자", sent: sent)
        }
        let plain = line(sent: nil)
        #expect(!plain.contains("sent") && line(sent: "漢字（かんじ）") == plain)
        #expect(line(sent: "漢字").contains(#""original":"漢字（かんじ）","sent":"漢字","translation":"한자""#))
    }

    @Test func aLogLineSaysWhenItsRulesWereSkipped() {
        func line(skipped: Bool) -> String {
            TranscriptFormat.jsonlLine(time: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!, lens: "L", app: "a", source: "ja", target: "ko", engine: "apple",
                                       original: "漢字（かんじ）", translation: "한자", rulesSkipped: skipped)
        }
        #expect(!line(skipped: false).contains("rules"))
        #expect(line(skipped: true).contains(#""original":"漢字（かんじ）","rules":"skipped","translation":"한자""#))
    }

    // MARK: The wire

    @Test func aJobAndAReplySurviveTheWire() throws {
        let job = ScriptJob(id: 9, kind: .after, text: "한자", src: "漢字（かんじ）", pattern: "(a+)+$", replacement: "$1", source: "function after(s,d){return d}",
                            patterns: [ScriptPattern(item: 2, pattern: "（[ぁ-ゖ]+）")], context: ctx)
        #expect(try ScriptWire.decode(ScriptJob.self, from: ScriptWire.encode(job)) == job)
        let reply = ScriptReply(id: 9, pid: 4242, text: "x", failure: RewriteFailure("boom", line: 3, column: 5),
                                issues: [RewriteIssue(stage: .before, item: 1, message: "m")], defines: [.before, .after], ms: 0.25)
        #expect(try ScriptWire.decode(ScriptReply.self, from: ScriptWire.encode(reply)) == reply)
        #expect(ScriptWire.serviceName(appID: "dev.midagedev.mwoyeo") == "dev.midagedev.mwoyeo.script")
    }
}
