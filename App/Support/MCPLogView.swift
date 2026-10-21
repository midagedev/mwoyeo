import Foundation

/// What the agent reads of the translation log: the lines of one view (an app, a time, a word) as rows. A lens reads the same text again
/// and again while it is drawn or scrolled in, and the log keeps every read, so by default a line read in pieces is its fullest read
/// and a line read again with the same translation is one row with a count. Both are the agent's context spent on nothing.
enum MCPLogRows {
    /// A later read of the same lens, within this many seconds, that starts with a line makes the line a piece of that read.
    static let foldWindow: TimeInterval = 3

    /// The newest line a row stands for, and how many lines it stands for (a line with the same app, original and translation).
    struct Row {
        var line: MCPLogLine
        var count: Int
    }

    struct View {
        var rows: [Row]
        /// Lines left out as pieces of a fuller read.
        var folded = 0
        /// Lines merged into the count of an earlier-read row.
        var repeats = 0
    }

    private struct Same: Hashable {
        let app: String?
        let original: String
        let translation: String

        init(_ line: MCPLogLine) {
            app = line.app
            original = line.original
            translation = line.translation
        }
    }

    /// `lines` are in log order. A line is a piece when a strictly later line of the same app and lens, within `foldWindow`, is longer and
    /// starts with it: the same instant is a name and its dialogue read in one batch, not a re-read, and a name that opens the next line
    /// stays. The same original with another translation is never folded or merged: it is what a drifting name looks like.
    static func make(_ lines: [MCPLogLine], distinct: Bool) -> View {
        guard distinct else { return View(rows: lines.map { Row(line: $0, count: 1) }) }
        var whole: [MCPLogLine] = []
        for (i, line) in lines.enumerated() {
            var later = i + 1
            var piece = false
            while later < lines.count, lines[later].time.timeIntervalSince(line.time) <= foldWindow {
                let next = lines[later]
                if next.time > line.time, next.app == line.app, next.lens == line.lens,
                   next.original.count > line.original.count, next.original.hasPrefix(line.original) {
                    piece = true
                    break
                }
                later += 1
            }
            if !piece { whole.append(line) }
        }
        var newest: [Same: Int] = [:], times: [Same: Int] = [:]
        for (i, line) in whole.enumerated() {
            newest[Same(line)] = i
            times[Same(line), default: 0] += 1
        }
        let rows = whole.enumerated().compactMap { i, line in
            newest[Same(line)] == i ? Row(line: line, count: times[Same(line)] ?? 1) : nil
        }
        return View(rows: rows, folded: lines.count - whole.count, repeats: whole.count - rows.count)
    }

    /// The rows with this text in the original or the translation, whatever the case.
    static func containing(_ text: String, in rows: [Row]) -> [Row] {
        rows.filter { $0.line.original.range(of: text, options: .caseInsensitive) != nil || $0.line.translation.range(of: text, options: .caseInsensitive) != nil }
    }
}

// MARK: - the table

/// Rows as a table: what never varies among them (the app, the profile, the languages, the engine, the day and its zone) once in the header,
/// the rest as columns, each row an array in the order of `columns`. A `names` column (design names-and-context §7: `[src, dst, from]` of each
/// row of the memory that occurs in the line) is there only when some row has names, so a log of a Mac with none is the table it was.
enum MCPLogTable {
    /// The fields of a line that are a header when they are the same on every row and a column when they are not.
    private static let fields: [(name: String, value: (MCPLogLine) -> String)] = [
        ("app", { $0.app ?? "" }), ("profile", { $0.profile ?? "" }), ("source", { $0.source }), ("target", { $0.target }), ("engine", { $0.engine }),
    ]

    static func render(_ rows: ArraySlice<MCPLogRows.Row>) -> [String: Any] {
        let lines = rows.map(\.line)
        var table: [String: Any] = [:]
        var columns = ["id", "time"]
        var varying: [(name: String, value: (MCPLogLine) -> String)] = []
        for field in fields {
            let values = Set(lines.map(field.value))
            if values.count > 1 { varying.append(field) } else if let only = values.first, !only.isEmpty { table[field.name] = only }
        }
        columns += varying.map(\.name)
        columns += ["original", "translation"]
        let named = lines.contains { !$0.names.isEmpty }
        if named { columns.append("names") }
        let parts = lines.map { timeParts($0.timeText) }
        let days = Set(parts.map(\.day)), zones = Set(parts.map(\.zone))
        if days.count == 1, let day = days.first, !day.isEmpty { table["day"] = day }
        if zones.count == 1, let zone = zones.first, !zone.isEmpty { table["zone"] = zone }
        let counted = rows.contains { $0.count > 1 }
        if counted { columns.append("count") }
        table["columns"] = columns
        table["rows"] = rows.map { row -> [Any] in
            let p = timeParts(row.line.timeText)
            // A time shows only what the header does not say: the day when the rows span days, the zone when they span zones.
            let time = (days.count > 1 ? String(p.day.dropFirst(5)) + " " : "") + p.clock + (zones.count > 1 ? p.zone : "")
            var cells: [Any] = [row.line.id, time]
            for field in varying { cells.append(field.value(row.line).isEmpty ? NSNull() : field.value(row.line)) }
            cells += [row.line.original, row.line.translation]
            if named { cells.append(row.line.names) }
            if counted { cells.append(row.count) }
            return cells
        }
        return table
    }

    /// `2026-10-20T19:14:17.833+09:00` as the day, the clock to the second and the zone; a time in another form is its own clock.
    static func timeParts(_ text: String) -> (day: String, clock: String, zone: String) {
        guard text.count >= 19, let t = text.firstIndex(of: "T"), text.distance(from: t, to: text.endIndex) >= 9 else { return ("", text, "") }
        let clock = text[text.index(after: t)...].prefix(8)
        let rest = text[text.index(t, offsetBy: 9)...]
        let zone = rest.firstIndex(where: { "+-Z".contains($0) }).map { String(rest[$0...]) } ?? ""
        return (String(text[..<t]), String(clock), zone)
    }
}

// MARK: - the tools

extension MCPLog {
    static func read(_ a: [String: Any], _ world: MCPWorld) throws -> [String: Any] {
        let settings = world.settings()
        let log = load(settings)
        if let gap = log.gap { throw MCPToolError(gap.message) }
        var since: Date?
        if let text = a["since"] as? String {
            guard let date = parseTime(text) else {
                throw MCPToolError("read_translation_log was not run: since: \"\(text)\" is not an ISO 8601 time with a zone, such as 2026-10-20T09:00:00+09:00")
            }
            since = date
        }
        let app = a["app"] as? String
        let distinct = a["distinct"] as? Bool ?? true
        let limit = (a["limit"] as? NSNumber)?.intValue ?? defaultLimit
        let view = MCPLogRows.make(log.lines.filter { (app == nil || $0.app == app) && $0.time >= (since ?? .distantPast) }, distinct: distinct)
        let wanted = (a["contains"] as? String).map { MCPLogRows.containing($0, in: view.rows) } ?? view.rows
        let newest = wanted.suffix(limit)
        var result = MCPLogTable.render(newest)
        result["returned"] = newest.count
        if wanted.count > newest.count { result["older"] = wanted.count - newest.count }
        if view.folded > 0 { result["folded"] = view.folded }
        if view.repeats > 0 { result["repeats"] = view.repeats }
        if log.skipped > 0 { result["skipped"] = log.skipped }
        if !settings.savesTranscripts { result["note"] = "Save transcripts is off now: these lines were written earlier." }
        return result
    }

    /// How many distinct translations of one term are listed, the most often used first: a term in a whole log would otherwise be the log.
    static let maxRenderings = 30

    static func termRenderings(_ a: [String: Any], _ world: MCPWorld) throws -> [String: Any] {
        let terms = a["terms"] as? [String] ?? []
        if terms.isEmpty { throw MCPToolError("term_renderings was not run: terms holds no term") }
        let settings = world.settings()
        let log = load(settings)
        if let gap = log.gap { throw MCPToolError(gap.message) }
        let app = a["app"] as? String ?? ""
        let examples = (a["limit_examples"] as? NSNumber)?.intValue ?? 2
        let view = MCPLogRows.make(log.lines.filter { $0.app == app }, distinct: true)
        var result: [String: Any] = ["app": app, "rows": view.rows.count, "each": "[count, translation, example row ids]"]
        if view.rows.isEmpty { result["note"] = "No line of this app is in the log; list_apps lists the apps that have one." }
        result["terms"] = terms.map { term -> [String: Any] in
            let rows = view.rows.filter { $0.line.original.range(of: term, options: .caseInsensitive) != nil }
            var byTranslation: [String: (count: Int, ids: [Int])] = [:]
            for row in rows {
                let seen = byTranslation[row.line.translation] ?? (0, [])
                byTranslation[row.line.translation] = (seen.count + row.count, seen.ids + [row.line.id])
            }
            let ranked = byTranslation.sorted { ($0.value.count, $0.value.ids.last ?? 0, $1.key) > ($1.value.count, $1.value.ids.last ?? 0, $0.key) }
            var entry: [String: Any] = ["term": term, "lines": rows.reduce(0) { $0 + $1.count },
                                        "renderings": ranked.prefix(maxRenderings).map { [$0.value.count, $0.key, Array($0.value.ids.suffix(examples))] as [Any] }]
            if ranked.count > maxRenderings { entry["more"] = ranked.count - maxRenderings }
            return entry
        }
        return result
    }
}
