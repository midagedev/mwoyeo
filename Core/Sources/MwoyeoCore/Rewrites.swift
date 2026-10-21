import Foundation

// Rewrite rules and scripts (docs/design/rewrite-rules.md §1-§5, §9): free-form text rewriting that costs no tokens, before the engine (on
// the source) or after it (on the output). This file is the pure side: the types, the strict checks of §2 and §3, the engine of the plain
// rows, the order of §4 over a chain as a planner (`RewritePlan`, `RewriteSession`) and the cache fingerprint. The regex rows and the
// scripts run in the `MwoyeoScript` XPC service (`Script/`, wire in `RewriteWire.swift`), reached through `RewriteRunner`
// (`App/Script/ScriptConnection.swift`); nothing here loads JavaScript.

// MARK: Limits and words

/// Every number of rewrite-rules §2, §3 and §5 in one place: the checks, the service and the app read these.
public enum RewriteLimits {
    /// §2: rows of one profile's table.
    public static let maxRows = 32
    /// §2: characters of a row's `find`.
    public static let findLength = 1...200
    /// §2: characters of a row's `replace` (0 is allowed).
    public static let maxReplace = 200
    /// §3: characters of a script's `source`.
    public static let maxScript = 8_000
    /// §5: milliseconds one line may take, for a script and for a profile's regex rows together.
    public static let lineBudgetMs = 50.0
    /// Milliseconds a check of a profile's patterns and script may take (its top level runs once, in a fresh global). §5 times lines and says nothing of
    /// checks: 4 lines' worth.
    public static let checkBudgetMs = 200.0
    /// §5: a reply longer than `replyFactor` × the input + `replySlack` is an error (a guard against runaway output).
    public static let replyFactor = 4
    public static let replySlack = 200

    /// Whether a reply is a runaway (§5). Lengths in UTF-16 units: what JavaScript counts, so the service can ask before it converts the string.
    public static func replyTooLong(input: Int, output: Int) -> Bool { output > replyFactor * input + replySlack }
}

/// The user-facing English of this feature (§5, §7), as constants for the strings of the round that wires it (`Localizable.xcstrings`).
public enum RewriteText {
    /// §5: what the profile sheet shows beside a unit the time limit turned off.
    public static let turnedOff = "Turned off: took longer than \(Int(RewriteLimits.lineBudgetMs)) ms on a line."
    /// §5: shown when the service could not be reached, so the line was left as it was.
    public static let serviceUnavailable = "The script service did not answer; the line was left as it was."
    /// A line's rules left out because the service was restarting after a kill (§5): the line was left as it was, nothing was turned off.
    public static let skippedWhileRestarting = "The rules were skipped: the script service was restarting."
    /// A check (§2, §3) that took longer than its budget: the service was cut.
    public static let checkTookTooLong = "Checking took longer than \(Int(RewriteLimits.checkBudgetMs)) ms."
    /// §5: a script that returns something that is not text.
    public static func notText(_ function: String, _ type: String) -> String { "\(function)() returned \(type), not text." }
    /// §5: a runaway reply.
    public static func replyTooLong(_ function: String) -> String {
        "\(function)() returned more than \(RewriteLimits.replyFactor) times its input plus \(RewriteLimits.replySlack) characters."
    }
}

// MARK: Types

/// When a row runs (§2): on the source before the engine, or on the engine's output after it.
public enum RewriteStage: String, Codable, Sendable, CaseIterable {
    case before
    case after
}

/// One row of the rules table (§2): `stage`, `find` (1-200 characters), `replace` (0-200), `regex` (default false), `on` (absent = on).
/// A plain row replaces every occurrence, case-sensitive, no folding; a regex row is a JavaScript regular expression with flags `gu`
/// and `$1` … in `replace`.
public struct RewriteRow: Codable, Equatable, Sendable {
    public var stage: RewriteStage
    public var find: String
    public var replace: String
    public var regex: Bool
    public var on: Bool

    public init(_ stage: RewriteStage, _ find: String, _ replace: String = "", regex: Bool = false, on: Bool = true) {
        self.stage = stage; self.find = find; self.replace = replace; self.regex = regex; self.on = on
    }

    /// The row runs: it is on and has something to find (an empty `find` is a check failure, and never matches here).
    public var isActive: Bool { on && !find.isEmpty }

    private enum CodingKeys: String, CodingKey { case stage, find, replace, regex, on }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stage = try c.decode(RewriteStage.self, forKey: .stage)
        find = try c.decode(String.self, forKey: .find)
        replace = try c.decodeIfPresent(String.self, forKey: .replace) ?? ""
        regex = try c.decodeIfPresent(Bool.self, forKey: .regex) ?? false
        on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? true
    }

    /// `regex` is written only when true and `on` only when false: absent means the default (§2).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(stage, forKey: .stage)
        try c.encode(find, forKey: .find)
        try c.encode(replace, forKey: .replace)
        if regex { try c.encode(true, forKey: .regex) }
        if !on { try c.encode(false, forKey: .on) }
    }
}

/// A profile's script (§3): JavaScript `source` (≤ 8,000 characters) that may define `before(line, ctx)` and `after(src, dst, ctx)`. `on`
/// is absent = on, as on a row; the editor writes `on: false` for a script it has not been told to run.
public struct RewriteScript: Codable, Equatable, Sendable {
    public var source: String
    public var on: Bool

    public init(source: String, on: Bool = true) {
        self.source = source; self.on = on
    }

    /// The script runs: it is on and has a source.
    public var isActive: Bool { on && !source.isEmpty }

    private enum CodingKeys: String, CodingKey { case source, on }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(String.self, forKey: .source)
        on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(source, forKey: .source)
        if !on { try c.encode(false, forKey: .on) }
    }
}

/// What a script is told (§3): the app's bundle ID or "", the profile's id or "all", the source language code or "auto", the target
/// language code. Nothing else: no lens, no window title, no memory, no clock, no state between lines.
public struct RewriteContext: Codable, Equatable, Sendable {
    public var app: String
    public var profile: String
    public var source: String
    public var target: String

    public init(app: String = "", profile: String = AppProfile.allAppsID, source: String = "auto", target: String) {
        self.app = app; self.profile = profile; self.source = source; self.target = target
    }
}

/// What went wrong with one row or script, as `test_rules` reports it (§8: `{stage, item, line, column, message}`): `item` is the row's index in
/// its profile's table, or `script` (-1). `line` and `column` come from JavaScriptCore, which gives a syntax error a line and no column, and a
/// pattern error neither (probed 2026-10-21); a runtime throw has both.
public struct RewriteIssue: Codable, Equatable, Sendable, CustomStringConvertible {
    public static let script = -1

    public var stage: RewriteStage?
    public var item: Int
    public var line: Int?
    public var column: Int?
    public var message: String

    public init(stage: RewriteStage? = nil, item: Int, line: Int? = nil, column: Int? = nil, message: String) {
        self.stage = stage; self.item = item; self.line = line; self.column = column; self.message = message
    }

    public init(stage: RewriteStage? = nil, item: Int, _ failure: RewriteFailure) {
        self.init(stage: stage, item: item, line: failure.line, column: failure.column, message: failure.message)
    }

    /// One line, for a log or a check's detail: `rewrites[3] (after): …` or `script, line 3, column 12 (before): …`.
    public var description: String {
        var place = item == Self.script ? "script" : "rewrites[\(item)]"
        if let line { place += ", line \(line)" }
        if let column { place += ", column \(column)" }
        if let stage { place += " (\(stage.rawValue))" }
        return "\(place): \(message)"
    }
}

/// A failure inside the service (a throw, a bad return, a syntax error), before it is placed on a row or a script.
public struct RewriteFailure: Codable, Equatable, Sendable {
    public var message: String
    public var line: Int?
    public var column: Int?

    public init(_ message: String, line: Int? = nil, column: Int? = nil) {
        self.message = message; self.line = line; self.column = column
    }
}

// MARK: Strict checks (§2, §3)

/// The strict checks of §2 and §3 that need no JavaScript: counts, lengths, stages, fields. Pure functions returning precise lines; a regex that
/// compiles and a script that parses are the service's (`ScriptConnection.check`), at check time and never run.
public enum RewriteCheck {
    private static let rowKeys: Set<String> = ["stage", "find", "replace", "regex", "on"]

    /// Typed rows: the 33rd row (`item` 32: it and the rest are dropped by `decode`), an empty `find`, a field over 200.
    public static func rows(_ rows: [RewriteRow]) -> [RewriteIssue] {
        var issues = rows.count > RewriteLimits.maxRows ? [tooMany(rows.count)] : []
        for (i, row) in rows.prefix(RewriteLimits.maxRows).enumerated() { issues += problems(of: row, at: i) }
        return issues
    }

    /// The script's length (§3). Its syntax and "neither function" are the service's.
    public static func script(_ script: RewriteScript) -> [RewriteIssue] {
        let n = script.source.count
        return n > RewriteLimits.maxScript
            ? [RewriteIssue(item: RewriteIssue.script, message: "script is \(n) characters; the most is \(RewriteLimits.maxScript)")] : []
    }

    /// A profile's `rewrites` as the settings file holds it (§2, "lenient decode"): a bad row is reported and dropped, the rest are kept in order.
    /// A row that is not an object, a `stage` outside the two, a missing or empty `find`, a field of the wrong type, a field this file does not
    /// know (a typo of `regex` would silently make a plain row), a field over its limit; and every row after the 32nd.
    public static func decode(rows raw: [Any]) -> (rows: [RewriteRow], issues: [RewriteIssue]) {
        var kept: [RewriteRow] = []
        var issues: [RewriteIssue] = raw.count > RewriteLimits.maxRows ? [tooMany(raw.count)] : []
        for (i, element) in raw.prefix(RewriteLimits.maxRows).enumerated() {
            let (row, found) = parse(element, at: i)
            issues += found
            if let row { kept.append(row) }
        }
        return (kept, issues)
    }

    private static func tooMany(_ n: Int) -> RewriteIssue {
        RewriteIssue(item: RewriteLimits.maxRows, message: "rewrites has \(n) rows; the most is \(RewriteLimits.maxRows), and row \(RewriteLimits.maxRows + 1) and the rest are dropped")
    }

    /// One row's value problems (the lengths), by index.
    private static func problems(of row: RewriteRow, at i: Int) -> [RewriteIssue] {
        var issues: [RewriteIssue] = []
        if row.find.isEmpty {
            issues.append(RewriteIssue(stage: row.stage, item: i, message: "find is empty"))
        } else if row.find.count > RewriteLimits.findLength.upperBound {
            issues.append(RewriteIssue(stage: row.stage, item: i, message: "find is \(row.find.count) characters; the most is \(RewriteLimits.findLength.upperBound)"))
        }
        if row.replace.count > RewriteLimits.maxReplace {
            issues.append(RewriteIssue(stage: row.stage, item: i, message: "replace is \(row.replace.count) characters; the most is \(RewriteLimits.maxReplace)"))
        }
        return issues
    }

    private static func parse(_ element: Any, at i: Int) -> (RewriteRow?, [RewriteIssue]) {
        func bad(_ message: String, stage: RewriteStage? = nil) -> RewriteIssue { RewriteIssue(stage: stage, item: i, message: message) }
        guard let object = element as? [String: Any] else { return (nil, [bad("a row must be an object")]) }
        var issues: [RewriteIssue] = []
        for key in object.keys.sorted() where !rowKeys.contains(key) { issues.append(bad("unknown field \"\(key)\"")) }
        let stage = (object["stage"] as? String).flatMap(RewriteStage.init(rawValue:))
        if stage == nil { issues.append(bad("stage must be \"before\" or \"after\"")) }
        let find = object["find"] as? String
        if find == nil { issues.append(bad("find must be a string")) }
        var replace = ""
        if let value = object["replace"] {
            if let s = value as? String { replace = s } else { issues.append(bad("replace must be a string", stage: stage)) }
        }
        func flag(_ key: String, default fallback: Bool) -> Bool {
            guard let value = object[key] else { return fallback }
            guard isBool(value), let b = value as? Bool else { issues.append(bad("\(key) must be true or false", stage: stage)); return fallback }
            return b
        }
        let regex = flag("regex", default: false), on = flag("on", default: true)
        guard let stage, let find else { return (nil, issues) }
        let row = RewriteRow(stage, find, replace, regex: regex, on: on)
        issues += problems(of: row, at: i)
        return (issues.isEmpty ? row : nil, issues)
    }

    /// A JSON `true`/`false`, not a number that bridges to Bool.
    private static func isBool(_ value: Any) -> Bool { CFGetTypeID(value as AnyObject) == CFBooleanGetTypeID() }
}

// MARK: Plain rows

/// The plain rows of §2, run in the app: every occurrence, case-sensitive, no folding, non-overlapping from the left. Linear: Knuth-Morris-Pratt
/// over UTF-8 (a valid needle can only match at scalar boundaries), so a line and a 200-character `find` cost O(line + find), not their product.
public enum RewriteEngine {
    public static func apply(_ row: RewriteRow, to text: String) -> String {
        var steps = 0
        return replaceAll(in: text, find: row.find, with: row.replace, steps: &steps)
    }

    /// `steps` counts the byte comparisons, so a gate can say "linear" in numbers (at most 2 × the haystack).
    static func replaceAll(in text: String, find: String, with replacement: String, steps: inout Int) -> String {
        let hay = Array(text.utf8), needle = Array(find.utf8), put = Array(replacement.utf8)
        guard !needle.isEmpty, hay.count >= needle.count else { return text }
        var fail = [Int](repeating: 0, count: needle.count)
        var k = 0
        for i in 1..<needle.count {
            while k > 0, needle[i] != needle[k] { k = fail[k - 1]; steps += 1 }
            steps += 1
            if needle[i] == needle[k] { k += 1 }
            fail[i] = k
        }
        var out: [UInt8] = []
        out.reserveCapacity(hay.count)
        var copied = 0, matched = 0
        for i in 0..<hay.count {
            while matched > 0, hay[i] != needle[matched] { matched = fail[matched - 1]; steps += 1 }
            steps += 1
            if hay[i] == needle[matched] { matched += 1 }
            if matched == needle.count {
                out.append(contentsOf: hay[copied..<(i + 1 - needle.count)])
                out.append(contentsOf: put)
                copied = i + 1
                matched = 0
            }
        }
        guard copied > 0 else { return text }
        out.append(contentsOf: hay[copied...])
        return String(decoding: out, as: UTF8.self)
    }
}

// MARK: The plan: order over a chain (§4)

/// What a layer of the chain can be: a profile's rewrites, or All apps' (`profile` is its id, or `all`).
public struct RewriteLayer: Equatable, Sendable {
    public var profile: String
    public var rows: [RewriteRow]
    public var script: RewriteScript?

    public init(profile: String, rows: [RewriteRow] = [], script: RewriteScript? = nil) {
        self.profile = profile; self.rows = rows; self.script = script
    }
}

/// A thing the time limit can turn off (§5): a row of a profile's table (`item` its index), or its script (`RewriteIssue.script`).
public struct RewriteUnit: Hashable, Sendable {
    public var profile: String
    public var item: Int

    public init(profile: String, item: Int) {
        self.profile = profile; self.item = item
    }
}

/// One step of a stage, in the order it runs (§4).
public enum RewriteStep: Equatable, Sendable {
    /// A plain row: run in the app.
    case plain(RewriteUnit, RewriteRow)
    /// A regex row: run in the service.
    case regex(RewriteUnit, RewriteRow)
    /// A script: run in the service, its `before` or its `after` by the stage.
    case script(RewriteUnit, RewriteScript)

    public var unit: RewriteUnit {
        switch self {
        case .plain(let u, _), .regex(let u, _), .script(let u, _): return u
        }
    }
}

/// The rewrites of a chain, in the order of rewrite-rules §4. `layers` are the chain as it is (the head first, All apps last, names-and-context
/// §1.3). Per line: `before` runs broad → narrow (All apps first), in each profile the table and then the script; `after` runs narrow → broad
/// (the head first), in each profile the script and then the table. A table runs its rows in order; the rows of the other stage are skipped.
public struct RewritePlan: Equatable, Sendable {
    public let layers: [RewriteLayer]

    public init(chain layers: [RewriteLayer]) { self.layers = layers }

    /// The plan of a chain of profiles (names-and-context §1.3, §2.1: the head first, All apps last): each profile's own rows and script, and for the All apps
    /// link the top-level ones. The only place that reads `AppProfile.rewrites` and `.script` into a plan.
    public init(links: [ChainLink], allAppsRows: [RewriteRow], allAppsScript: RewriteScript?) {
        self.init(chain: links.map { link in
            link.profile.map { RewriteLayer(profile: $0.id, rows: $0.rewrites, script: $0.script) }
                ?? RewriteLayer(profile: AppProfile.allAppsID, rows: allAppsRows, script: allAppsScript)
        })
    }

    /// The steps of `stage`, in the order they run.
    public func steps(_ stage: RewriteStage) -> [RewriteStep] {
        switch stage {
        case .before: return layers.reversed().flatMap { table($0, stage) + script($0) }
        case .after: return layers.flatMap { script($0) + table($0, stage) }
        }
    }

    /// No row and no script is on: nothing runs, nothing is loaded, the service never starts (§5 "Default path").
    public var isEmpty: Bool { layers.allSatisfy { $0.script?.isActive != true && !$0.rows.contains(where: \.isActive) } }

    /// Some step runs in the service (a regex row or a script). Plain rows run in the app.
    public var needsService: Bool {
        layers.contains { $0.script?.isActive == true || $0.rows.contains { $0.isActive && $0.regex } }
    }

    private func table(_ layer: RewriteLayer, _ stage: RewriteStage) -> [RewriteStep] {
        layer.rows.enumerated().compactMap { i, row in
            guard row.stage == stage, row.isActive else { return nil }
            let unit = RewriteUnit(profile: layer.profile, item: i)
            return row.regex ? .regex(unit, row) : .plain(unit, row)
        }
    }

    private func script(_ layer: RewriteLayer) -> [RewriteStep] {
        guard let script = layer.script, script.isActive else { return [] }
        return [.script(RewriteUnit(profile: layer.profile, item: RewriteIssue.script), script)]
    }

    // MARK: Cache namespace (§4)

    /// A fingerprint of everything that changes what a line becomes: per layer in chain order, the rows that are on (stage, kind, find, replace) and the
    /// script that is on (with the layer's profile id, which `ctx.profile` shows it); with a script, also `app`, which `ctx.app` shows it. nil with
    /// nothing on, so today's namespace is today's. 64-bit FNV-1a of the text, as `LensRoute.fingerprint`.
    public func fingerprint(app: String?) -> String? {
        guard !isEmpty else { return nil }
        var canon = ""
        func put(_ s: String) { canon += "\(s.utf8.count):\(s)" }
        if layers.contains(where: { $0.script?.isActive == true }) { put(app ?? "") }
        for layer in layers {
            canon += "|"
            for row in layer.rows where row.isActive { put(row.stage.rawValue); put(row.regex ? "r" : "p"); put(row.find); put(row.replace) }
            if let script = layer.script, script.isActive { canon += "s"; put(layer.profile); put(script.source) }
        }
        var h: UInt64 = 0xcbf29ce484222325
        for b in canon.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// What `LensRoute.namespace` appends: `""` with nothing on, else `|rw:<fingerprint>`.
    public func namespaceSuffix(app: String?) -> String { fingerprint(app: app).map { "|rw:\($0)" } ?? "" }
}

// MARK: Running a plan

/// One call to the service, as the app's `ScriptConnection` makes it. `budgetMs` is what the app lets the call take: over it the app kills the
/// service and says `.timedOut`.
public struct RewriteRun: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The new text. A script that does not define the stage's function returns its input.
        case text(String)
        /// A throw, a non-text return, a runaway reply, a syntax error: the text stays as it was.
        case failed(RewriteFailure)
        /// Over the budget: the service was killed, and the unit is to be turned off.
        case timedOut
        /// The call was not made: the service is down, launchd holds its next start for a few seconds (§5), and the caller said it will not wait for it
        /// (`RewriteSession.waitsForService`). The text stays as it was and nothing is turned off; the line is not what its rules say, so it is kept nowhere.
        case held
    }

    public var outcome: Outcome
    /// What the call took, as the caller timed it (the regex rows of a profile share one budget).
    public var usedMs: Double

    public init(_ outcome: Outcome, usedMs: Double = 0) {
        self.outcome = outcome; self.usedMs = usedMs
    }
}

/// The side that runs regex rows and scripts (§5): the app's `ScriptConnection`, or a fake in a gate. One regex row per call, so a call that is cut says
/// which row to turn off. `waits` false: a service that is down and held back by launchd is not waited for, the call answers `.held` at once.
public protocol RewriteRunner: Sendable {
    /// A regex row (flags `gu`, `$1` in `replace`) over `text`.
    func regex(_ row: RewriteRow, on text: String, budgetMs: Double, waits: Bool) async -> RewriteRun
    /// The script's `before(text, ctx)` or, at `.after`, `after(src, text, ctx)`; `text` is the line (before) or the engine's answer so far (after).
    func script(_ script: RewriteScript, stage: RewriteStage, text: String, src: String, context: RewriteContext, budgetMs: Double, waits: Bool) async -> RewriteRun
}

/// The rewrites of one batch of lines: `before` on each source line, `after` on each answer. Sequential: one value, used by one task.
///
/// A unit turned off is skipped for the rest of the session (`turnedOff` is what the caller writes `on: false` on, §5), so a looping script costs
/// its budget once per batch, not once per line. A failure leaves the text as it was at that step and shows in `issues`; the unit stays on.
/// A profile's regex rows share `lineBudgetMs` per line and stage: a row that would run with none of it left is turned off without running.
/// With a plan that needs no service the runner is never called.
///
/// A service that was just killed is not up again for a few seconds (launchd's throttle, `ScriptConnection`). A session that waits for it (the default: the
/// editor's try, `test_rules`) is answered late. A lens's session does not (`waitsForService` false): a regex row or script call made while the service is held
/// back is `held` — the text passes as it was, nothing is turned off, and the caller knows not to keep the line.
public struct RewriteSession: Sendable {
    public let plan: RewritePlan
    public let context: RewriteContext
    public let lineBudgetMs: Double
    public let waitsForService: Bool
    private let runner: any RewriteRunner
    public private(set) var issues: [RewriteIssue] = []
    public private(set) var turnedOff: [RewriteUnit] = []
    /// The units whose call was not made because the service was held back, one entry per call.
    public private(set) var held: [RewriteUnit] = []

    /// `context.profile` is set per layer; the rest is the lens's. `lineBudgetMs` is a parameter so a gate can shrink it.
    public init(plan: RewritePlan, context: RewriteContext, runner: any RewriteRunner, lineBudgetMs: Double = RewriteLimits.lineBudgetMs, waitsForService: Bool = true) {
        self.plan = plan; self.context = context; self.runner = runner; self.lineBudgetMs = lineBudgetMs; self.waitsForService = waitsForService
    }

    /// The line to translate (§4 step 1).
    public mutating func before(_ line: String) async -> String {
        await run(.before, text: line, src: line)
    }

    /// The line to show (§4 step 4): `src` is the line sent, `dst` the engine's answer.
    public mutating func after(src: String, dst: String) async -> String {
        await run(.after, text: dst, src: src)
    }

    private mutating func run(_ stage: RewriteStage, text start: String, src: String) async -> String {
        var text = start
        var spent: [String: Double] = [:]
        for step in plan.steps(stage) where !turnedOff.contains(step.unit) {
            switch step {
            case .plain(_, let row):
                text = RewriteEngine.apply(row, to: text)
            case .regex(let unit, let row):
                let left = lineBudgetMs - spent[unit.profile, default: 0]
                guard left > 0 else { turnOff(unit, stage); continue }
                let run = await runner.regex(row, on: text, budgetMs: left, waits: waitsForService)
                spent[unit.profile, default: 0] += run.usedMs
                text = absorb(run, unit, stage, text)
            case .script(let unit, let script):
                var ctx = context
                ctx.profile = unit.profile
                let run = await runner.script(script, stage: stage, text: text, src: src, context: ctx, budgetMs: lineBudgetMs, waits: waitsForService)
                text = absorb(run, unit, stage, text)
            }
        }
        return text
    }

    private mutating func absorb(_ run: RewriteRun, _ unit: RewriteUnit, _ stage: RewriteStage, _ text: String) -> String {
        switch run.outcome {
        case .text(let new): return new
        case .failed(let failure): issues.append(RewriteIssue(stage: stage, item: unit.item, failure)); return text
        case .timedOut: turnOff(unit, stage); return text
        case .held: held.append(unit); return text
        }
    }

    private mutating func turnOff(_ unit: RewriteUnit, _ stage: RewriteStage) {
        turnedOff.append(unit)
        issues.append(RewriteIssue(stage: stage, item: unit.item, message: RewriteText.turnedOff))
    }
}
