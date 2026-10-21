#if !MAS
import Foundation
import MwoyeoCore
import MwoyeoEngines

/// The checks of `Mwoyeo --mcp`, run by `--capture-ui … check-logic` and alone by `mcp-checks` (PASS/FAIL lines). The server is driven in
/// process with JSON-RPC lines, over a scratch settings.json and a scratch Transcripts folder written by the app's own `TranscriptWriter`,
/// so a change to the log's line or to the file's checks shows here. The process itself (stdout, the end at EOF) is `tools/mcp/smoke.sh`.
@MainActor
enum MCPChecks {
    /// A tool's answer: whether it is an error, its text (the one copy of the payload) and that text read as JSON.
    private struct Answer {
        var isError: Bool
        var text: String
        var data: [String: Any]
        /// The reply carried a `structuredContent` beside the text, or more than one content block.
        var doubled = false

        var columns: [String] { data["columns"] as? [String] ?? [] }
        var rows: [[Any]] { data["rows"] as? [[Any]] ?? [] }
        func column(_ name: String) -> [Any] { columns.firstIndex(of: name).map { i in rows.map { $0[i] } } ?? [] }
        var originals: [String] { column("original").compactMap { $0 as? String } }
        func list(_ key: String) -> [String] { data[key] as? [String] ?? [] }
    }

    /// A client of one server: sends lines, keeps what came back.
    @MainActor private final class Client {
        let server: MCPServer
        var replies: [String] = []
        var sent = 0

        init(_ server: MCPServer) { self.server = server }

        @discardableResult
        func send(_ method: String, _ params: [String: Any]? = nil, notification: Bool = false) -> [String: Any]? {
            var message: [String: Any] = ["jsonrpc": "2.0", "method": method]
            if !notification { message["id"] = sent + 1 }
            message["params"] = params
            return raw(MCPServer.json(message))
        }

        func raw(_ line: String) -> [String: Any]? {
            sent += 1
            guard let reply = server.handle(line) else { return nil }
            replies.append(reply)
            return (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any]
        }

        func call(_ tool: String, _ arguments: [String: Any] = [:]) -> Answer {
            let result = send("tools/call", ["name": tool, "arguments": arguments])?["result"] as? [String: Any] ?? [:]
            let blocks = result["content"] as? [[String: Any]] ?? []
            let text = (blocks.first?["text"] as? String) ?? ""
            let isError = result["isError"] as? Bool ?? false
            return Answer(isError: isError, text: text, data: isError ? [:] : (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:],
                          doubled: result["structuredContent"] != nil || blocks.count != 1)
        }
    }

    /// Keys that cannot be reached, as the Keychain is not from a process that has no access to it.
    private struct Unreachable: SecretStore {
        struct Denied: Error, CustomStringConvertible { var description: String { "access denied" } }
        func secret(for engine: UUID) throws -> String? { throw Denied() }
        func setSecret(_ secret: String?, for engine: UUID) throws { throw Denied() }
    }

    static func run(_ model: AppModel) -> Int {
        var failed = 0
        func check(_ what: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            print("check-logic: \(ok ? "PASS" : "FAIL") mcp: \(what)" + (ok || detail().isEmpty ? "" : " [\(detail())]"))
            if !ok { failed += 1 }
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mwoyeo-mcp-checks-\(getpid())")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // The log: two lenses on two apps, written by the app's writer (times are the writer's: its start plus the seconds given).
        let export = dir.appendingPathComponent("export")
        let transcripts = LensExport.transcriptsFolder(export)
        let t0 = Date(timeIntervalSince1970: 1_792_400_000)
        func lens(_ name: String, app: String, engine: String, at start: Date, _ lines: [(Double, String, String)]) {
            let writer = TranscriptWriter(directory: transcripts, lens: name, sourceCode: "ja", targetCode: "ko", formats: [.jsonl], engine: engine, started: start, onError: {})
            writer.setApp(app)
            var seen: [TranscriptRecorder.Observed] = []
            for (time, original, translation) in lines {
                seen.append(.init(source: original, translation: translation, inLens: true))
                writer.observe(time: time, lines: seen)
            }
            writer.finishAndWait(time: (lines.last?.0 ?? 0) + 1)
        }
        lens("Chat", app: "com.example.chat", engine: "Ollama", at: t0,
             [(1, "こんにちは", "안녕하세요"), (3, "田中さんは来ましたか", "다나카 씨는 왔어요?"), (5, "ありがとう", "고마워")])
        lens("Game", app: "com.example.game", engine: "apple", at: t0.addingTimeInterval(3600),
             [(1, "勇者アレンは魔王城へ向かった", "용사 알렌은 마왕성으로 향했다"), (4, "九十九の剣", "쓰쿠모의 검")])

        // Settings: the base is ja → ko; the game's profile is en → ja, so a new profile that takes ja → ko took the base.
        let gameEntries = [MemoryEntry(src: "九十九", dst: "Tsukumo", kind: .person), MemoryEntry(src: "魔王城", dst: "Demon King's Castle", kind: .place)]
        var base = AppSettings()
        base.sourceLanguage = "ja"
        base.targetLanguage = "ko"
        base.savesTranscripts = true
        base.exportFolder = export.path
        base.transcriptFormats = [.jsonl]
        base.agentConnection = true
        base.appProfiles = [AppProfile(bundleID: "com.example.game", appName: "Example Game", source: "en", target: "ja",
                                       note: "Fantasy RPG. Keep it formal.", entries: gameEntries)]
        let file = dir.appendingPathComponent("settings.json")
        func write(_ s: AppSettings, to url: URL? = nil) { try? SettingsFileFormat.render(s).write(to: url ?? file) }
        write(base)
        // The app keeps the whole settings in its preferences too (`AppModel.mirror`): a file with no key for the switch is read over that copy.
        func world(_ url: URL? = nil, saved: AppSettings = AppSettings()) -> MCPWorld {
            MCPWorld(settingsURL: url ?? file, saved: { saved }, appName: { $0 == "com.example.chat" ? "Example Chat" : nil })
        }
        func stored(_ id: String, at url: URL? = nil) -> AppProfile? {
            AppProfiles.profile(for: id, in: SettingsFileCheck.read((try? Data(contentsOf: url ?? file)) ?? Data(), over: AppSettings()).settings.appProfiles)
        }
        func bytes(_ url: URL? = nil) -> Data? { try? Data(contentsOf: url ?? file) }

        var traces: [String] = []
        let client = Client(MCPServer(world: world(), trace: { traces.append($0) }))

        // The protocol
        let hello = client.send("initialize", ["protocolVersion": "2025-06-18", "capabilities": [String: Any](), "clientInfo": ["name": "check", "version": "1"]])?["result"] as? [String: Any]
        check("initialize answers protocol 2025-06-18 with the tools capability, a server name and instructions",
              hello?["protocolVersion"] as? String == "2025-06-18" && (hello?["capabilities"] as? [String: Any])?["tools"] != nil
              && (hello?["serverInfo"] as? [String: Any])?["name"] as? String == "mwoyeo" && (hello?["instructions"] as? String)?.contains("glossary") == true)
        let steps = (hello?["instructions"] as? String) ?? ""
        let named = ["list_apps", "read_translation_log", "term_renderings", "set_memory", "translate_text"].map { steps.range(of: $0)?.lowerBound }
        check("the instructions are a workflow of at most 8 lines that names list_apps, read_translation_log, term_renderings, set_memory and translate_text in that order",
              steps.split(separator: "\n").count <= 8 && !named.contains { $0 == nil } && named.compactMap { $0 } == named.compactMap { $0 }.sorted())
        let initialized = client.send("notifications/initialized", notification: true)
        let ping = client.send("ping")?["result"] as? [String: Any]
        check("notifications/initialized has no reply and ping an empty result", initialized == nil && ping?.isEmpty == true)
        let listed = (client.send("tools/list")?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        func sentences(_ text: String?) -> Int { (text ?? "").components(separatedBy: ". ").count }
        check("tools/list: the nine tools, each with a description of at most two sentences and an object schema",
              listed.compactMap { $0["name"] as? String } == ["list_apps", "read_translation_log", "term_renderings", "get_memory", "set_memory", "translate_text", "get_settings", "set_settings", "get_settings_schema"]
              && listed.allSatisfy { sentences($0["description"] as? String) <= 2 && ($0["description"] as? String)?.isEmpty == false && ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" },
              "\(listed.map { "\($0["name"] as? String ?? "?"): \(sentences($0["description"] as? String))" })")
        let setter = listed.first { $0["name"] as? String == "set_memory" }
        let entriesSchema = ((setter?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?["entries"] as? [String: Any]
        let entryKind = (((entriesSchema?["items"] as? [String: Any])?["properties"] as? [String: Any])?["kind"] as? [String: Any])?["enum"] as? [String]
        check("set_memory says the glossary is for every app, and its entries are the settings file's own (40 rows, the kinds of MemoryEntry)",
              (setter?["description"] as? String)?.contains("glossary is for every app") == true && entriesSchema?["maxItems"] as? Int == AppProfile.maxEntries
              && entryKind == EntryKind.allCases.map(\.rawValue))
        let unknown = client.send("resources/list")?["error"] as? [String: Any]
        let unknownTool = client.send("tools/call", ["name": "delete_everything"])?["error"] as? [String: Any]
        let garbage = client.raw("{ not json")
        check("an unknown method is -32601, an unknown tool -32602 and a line that is not JSON -32700 with a null id",
              unknown?["code"] as? Int == -32601 && unknownTool?["code"] as? Int == -32602
              && (garbage?["error"] as? [String: Any])?["code"] as? Int == -32700 && garbage?["id"] is NSNull)

        // The switch (Settings > General, `agentConnection`): off, the server answers the handshake and refuses every tool call
        var offBase = base
        offBase.agentConnection = false
        let switchURL = dir.appendingPathComponent("switch/settings.json")
        try? FileManager.default.createDirectory(at: switchURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        write(offBase, to: switchURL)
        let switched = Client(MCPServer(world: world(switchURL), trace: { _ in }))
        let switchBefore = bytes(switchURL)
        let refusedCalls = [switched.call("list_apps"), switched.call("read_translation_log"), switched.call("get_memory", ["app": "com.example.game"]),
                            switched.call("set_memory", ["app": "com.example.game", "note": "x"]), switched.call("get_settings"),
                            switched.call("set_settings", ["values": ["lensStyle": "subtle"]]), switched.call("get_settings_schema"),
                            switched.call("term_renderings", ["app": "com.example.game", "terms": ["九十九"]]), switched.call("translate_text", ["lines": ["x"]])]
        let offText = "Agent connection is off. Turn it on in Mwoyeo Settings → \(String(localized: "Connect an agent (MCP)"))."
        check("switch off: all nine tools are refused with the name of the row to turn on, and nothing is written",
              refusedCalls.count == 9 && refusedCalls.allSatisfy { $0.isError && $0.text == offText } && bytes(switchURL) == switchBefore)
        let handshake = switched.send("initialize")?["result"] as? [String: Any]
        let toolsOff = ((switched.send("tools/list")?["result"] as? [String: Any])?["tools"] as? [Any])?.count
        check("switch off: initialize and tools/list still answer", handshake?["protocolVersion"] as? String == "2025-06-18" && toolsOff == 9)
        write(base, to: switchURL)
        let nowOn = switched.call("list_apps")
        check("switch on: the same server works at the next call, without a restart (the setting is read at each call)", !nowOn.isError && (nowOn.data["loggedApps"] as? [Any])?.count == 2)
        check("the switch is off in a file without the key, in no file at all and by default, and the file holds the key only while it is on",
              !SettingsFileCheck.read(Data("{}".utf8), over: AppSettings()).settings.agentConnection && !AppSettings().agentConnection
              && Client(MCPServer(world: world(dir.appendingPathComponent("no/such/settings.json")), trace: { _ in })).call("list_apps").isError
              && !String(decoding: SettingsFileFormat.render(AppSettings()), as: UTF8.self).contains("agentConnection")
              && String(decoding: SettingsFileFormat.render(base), as: UTF8.self).contains("\"agentConnection\": true"))

        // read_translation_log: a table under a header
        let all = client.call("read_translation_log")
        let timeCells = all.column("time").compactMap { $0 as? String }
        check("read_translation_log: the five lines of the writer's files, oldest first, as rows named by columns; what varies (app, engine) is a column, what does not (languages) is in the header",
              !all.isError && all.originals == ["こんにちは", "田中さんは来ましたか", "ありがとう", "勇者アレンは魔王城へ向かった", "九十九の剣"]
              && all.columns == ["id", "time", "app", "engine", "original", "translation"] && all.data["source"] as? String == "ja" && all.data["target"] as? String == "ko"
              && all.data["app"] == nil && all.data["engine"] == nil && all.column("id").compactMap { $0 as? Int } == [1, 2, 3, 4, 5]
              && all.column("app").first as? String == "com.example.chat" && all.column("engine").first as? String == "Ollama"
              && all.column("translation").last as? String == "쓰쿠모의 검" && all.data["returned"] as? Int == 5 && all.data["older"] == nil)
        // The day and the zone are in the header when every row has them; else a time says them (MM-DD before the clock, the zone after).
        check("read_translation_log: a time is the clock to the second, and the day and the zone are in the header when they never vary",
              timeCells.count == 5 && (all.data["day"] != nil ? timeCells.allSatisfy { $0.count == 8 } : timeCells.allSatisfy { $0.count == 14 })
              && (all.data["zone"] as? String)?.isEmpty == false)
        let chat = client.call("read_translation_log", ["app": "com.example.chat"])
        check("read_translation_log filters by app, and the header then holds the app, the languages and the engine once",
              chat.originals == ["こんにちは", "田中さんは来ましたか", "ありがとう"] && chat.columns == ["id", "time", "original", "translation"]
              && chat.data["app"] as? String == "com.example.chat" && chat.data["engine"] as? String == "Ollama" && chat.data["source"] as? String == "ja"
              && chat.data["day"] as? String != nil && chat.column("time").compactMap { $0 as? String }.allSatisfy { $0.count == 8 })
        let newest = client.call("read_translation_log", ["app": "com.example.chat", "limit": 2])
        check("read_translation_log limit gives the newest rows, still oldest first, and says how many older ones there are",
              newest.originals == ["田中さんは来ましたか", "ありがとう"] && newest.data["returned"] as? Int == 2 && newest.data["older"] as? Int == 1)
        let since = ISO8601DateFormatter().string(from: t0.addingTimeInterval(3600))
        let late = client.call("read_translation_log", ["since": since])
        check("read_translation_log since keeps the lines from that time on", late.originals == ["勇者アレンは魔王城へ向かった", "九十九の剣"])
        let sought = client.call("read_translation_log", ["contains": "九十九"]), soughtTranslation = client.call("read_translation_log", ["contains": "알렌"])
        check("read_translation_log contains keeps the rows with the text in the original or in the translation",
              sought.originals == ["九十九の剣"] && soughtTranslation.originals == ["勇者アレンは魔王城へ向かった"]
              && client.call("read_translation_log", ["contains": "no such text"]).rows.isEmpty)
        let badLimit = client.call("read_translation_log", ["limit": 0]), bigLimit = client.call("read_translation_log", ["limit": 501])
        let badSince = client.call("read_translation_log", ["since": "yesterday"]), badType = client.call("read_translation_log", ["limit": "ten"])
        check("a limit of 0 or 501, a limit that is not a number and a since that is not a time are tool errors naming the argument",
              badLimit.isError && badLimit.text.contains("limit:") && bigLimit.isError && bigLimit.text.contains("500")
              && badSince.isError && badSince.text.contains("since") && badType.isError && badType.text.contains("limit:"))
        let extra = client.call("read_translation_log", ["lines": 3])
        check("an argument the tool does not take is a tool error that names the ones it takes",
              extra.isError && extra.text.contains("unknown key lines") && extra.text.contains("limit") && extra.text.contains("distinct"))

        // distinct: the pieces of a line being read are folded into the fullest read, an exact repeat is counted, and a drifting name stays
        let readerDir = dir.appendingPathComponent("reader")
        let readerLog = LensExport.transcriptsFolder(readerDir)
        try? FileManager.default.createDirectory(at: readerLog, withIntermediateDirectories: true)
        func entry(_ lens: String, _ app: String, _ at: Double, _ original: String, _ translation: String) -> String {
            TranscriptFormat.jsonlLine(time: t0.addingTimeInterval(at), timeZone: TimeZone(secondsFromGMT: 9 * 3600) ?? .current, lens: lens, app: app,
                                       source: "ja", target: "ko", engine: "Ollama", original: original, translation: translation)
        }
        // Lens "A": a line read three times as it is drawn; a name and its dialogue in one batch (the dialogue opens with the name); the name
        // read again with the same translation, then with another; a name and a longer line 3.5 s later. Lens "B": a read of the same
        // text as A's fragment, which is no piece of A's line; and a title with the name's translation (the name and the title share one).
        let readerRows = [entry("A", "com.example.reader", 0.0, "九十九、こ", "구십구, 여"), entry("A", "com.example.reader", 0.6, "九十九、ここが", "구십구, 여기가"),
                          entry("B", "com.example.reader", 0.8, "九十九", "구십구"),
                          entry("A", "com.example.reader", 1.2, "九十九、ここが月影のよ。間違いないわ", "쓰쿠모, 여기가 달그림자야. 틀림없어"),
                          entry("A", "com.example.reader", 5.0, "シュザンヌ", "수잔"), entry("A", "com.example.reader", 5.0, "シュザンヌ様、ありました", "수잔 님, 찾았습니다"),
                          entry("A", "com.example.reader", 20.0, "シュザンヌ", "수잔"), entry("A", "com.example.reader", 40.0, "シュザンヌ", "슈잔느"),
                          entry("A", "com.example.reader", 60.0, "ハク", "하쿠"), entry("A", "com.example.reader", 63.5, "ハクと言ったわね", "하쿠라고 했지"),
                          entry("A", "com.example.reader", 80.0, "シュザンヌ嬢", "수잔")]
        try? Data(readerRows.joined().utf8).write(to: readerLog.appendingPathComponent("Reader 2026-10-20 10-00.jsonl"))
        var readerBase = base
        readerBase.exportFolder = readerDir.path
        readerBase.appProfiles = []
        let readerFile = dir.appendingPathComponent("reader-settings.json")
        write(readerBase, to: readerFile)
        let reader = Client(MCPServer(world: world(readerFile), trace: { _ in }))
        let distinct = reader.call("read_translation_log", ["app": "com.example.reader"])
        check("distinct: the two pieces of a line are folded into the fullest read, and a read of another lens that opens the same way is no piece",
              distinct.originals.first(where: { $0.hasPrefix("九十九、") }) == "九十九、ここが月影のよ。間違いないわ" && !distinct.originals.contains("九十九、こ") && !distinct.originals.contains("九十九、ここが")
              && distinct.originals.contains("九十九") && distinct.data["folded"] as? Int == 2)
        check("distinct: a name and the dialogue that opens with it, read in one batch, stay two rows; a longer line more than 3 s later is no fuller read",
              distinct.originals.contains("シュザンヌ様、ありました") && distinct.originals.contains("ハク") && distinct.originals.contains("ハクと言ったわね"))
        let nameRows = zip(distinct.originals, distinct.column("translation")).filter { $0.0 == "シュザンヌ" }.map { $0.1 as? String }
        check("distinct: an exact repeat is one row with its count, and the same original with another translation is another row (a drifting name)",
              nameRows == ["수잔", "슈잔느"] && distinct.columns.last == "count" && distinct.rows.first(where: { ($0[distinct.columns.firstIndex(of: "original") ?? 0] as? String) == "シュザンヌ" && ($0[distinct.columns.firstIndex(of: "translation") ?? 0] as? String) == "수잔" })?.last as? Int == 2
              && distinct.data["repeats"] as? Int == 1)
        let raw = reader.call("read_translation_log", ["app": "com.example.reader", "distinct": false])
        check("distinct false returns every logged line, no count column and no folded or repeats", raw.rows.count == 11 && raw.columns.last == "translation" && raw.data["folded"] == nil && raw.data["repeats"] == nil)
        check("a row's id is the line's place in the whole log, the same in every view",
              raw.column("id").compactMap { $0 as? Int } == Array(1...11) && distinct.column("id").compactMap { $0 as? Int }.allSatisfy { (1...11).contains($0) }
              && reader.call("read_translation_log", ["app": "com.example.reader", "contains": "ハク"]).column("id").compactMap { $0 as? Int } == [9, 10])

        // term_renderings
        let terms = reader.call("term_renderings", ["app": "com.example.reader", "terms": ["シュザンヌ", "九十九", "存在しない"]])
        let termList = terms.data["terms"] as? [[String: Any]] ?? []
        func renderings(_ i: Int) -> [[Any]] { termList.count > i ? termList[i]["renderings"] as? [[Any]] ?? [] : [] }
        check("term_renderings: for a name, every distinct translation of the rows that contain it, grouped by exact text, with counts and example ids, the most used first",
              !terms.isError && termList.count == 3 && termList[0]["term"] as? String == "シュザンヌ" && termList[0]["lines"] as? Int == 5
              && renderings(0).map { $0[1] as? String } == ["수잔", "슈잔느", "수잔 님, 찾았습니다"] && renderings(0).map { $0[0] as? Int } == [3, 1, 1]
              && renderings(0).map { $0[2] as? [Int] } == [[7, 11], [8], [6]] && termList[0]["more"] == nil)
        check("term_renderings: a piece of a line being read is not a rendering of the name, a term that is nowhere has no renderings, and the answer says how its entries read",
              renderings(1).map { $0[1] as? String } == ["쓰쿠모, 여기가 달그림자야. 틀림없어", "구십구"] && renderings(2).isEmpty && termList[2]["lines"] as? Int == 0
              && (terms.data["each"] as? String)?.contains("count") == true && terms.data["rows"] as? Int == 8)
        let oneExample = reader.call("term_renderings", ["app": "com.example.reader", "terms": ["シュザンヌ"], "limit_examples": 1])
        check("term_renderings limit_examples limits the example ids of each translation, the newest first kept",
              ((oneExample.data["terms"] as? [[String: Any]])?.first?["renderings"] as? [[Any]])?.first?[2] as? [Int] == [11])
        let noApp = reader.call("term_renderings", ["app": "com.example.nothing", "terms": ["x"]])
        let noTerms = reader.call("term_renderings", ["app": "com.example.reader", "terms": [String]()])
        let manyTerms = reader.call("term_renderings", ["app": "com.example.reader", "terms": (0..<51).map { "t\($0)" }])
        check("term_renderings: an app that is not in the log says so, and no term, or more than 50, is a tool error",
              !noApp.isError && (noApp.data["note"] as? String)?.contains("list_apps") == true && noTerms.isError && noTerms.text.contains("no term") && manyTerms.isError)
        let wide = (0..<40).map { entry("W", "com.example.wide", Double($0) * 10, "名前\($0)", "이름\($0)") + entry("W", "com.example.wide", Double($0) * 10 + 5, "名前", "별\($0)") }
        try? Data(wide.joined().utf8).write(to: readerLog.appendingPathComponent("Wide 2026-10-20 11-00.jsonl"))
        let capped = reader.call("term_renderings", ["app": "com.example.wide", "terms": ["名前"]])
        let cappedEntry = (capped.data["terms"] as? [[String: Any]])?.first
        check("term_renderings lists at most 30 translations of a term and says how many more there are",
              (cappedEntry?["renderings"] as? [Any])?.count == MCPLog.maxRenderings && cappedEntry?["more"] as? Int == 80 - MCPLog.maxRenderings && cappedEntry?["lines"] as? Int == 80)

        // list_apps
        let apps = client.call("list_apps")
        let logged = apps.data["loggedApps"] as? [[String: Any]] ?? []
        let profiles = apps.data["profiles"] as? [[String: Any]] ?? []
        check("list_apps: the apps of the log with their names, line counts and last time, newest first",
              logged.map { $0["bundleID"] as? String } == ["com.example.game", "com.example.chat"] && logged.map { $0["lines"] as? Int } == [2, 3]
              && logged.map { $0["appName"] as? String } == ["Example Game", "Example Chat"] && logged.first?["last"] as? String == MCPLog.lines(in: transcripts).lines.last?.timeText
              && (apps.data["log"] as? [String: Any])?["available"] as? Bool == true)
        check("list_apps: the apps with a profile, whether each has a memory and how many names",
              profiles.count == 1 && profiles[0]["bundleID"] as? String == "com.example.game" && profiles[0]["hasMemory"] as? Bool == true && profiles[0]["entries"] as? Int == 2)

        // No log to read: each reason says how to turn it on
        func gap(_ edit: (inout AppSettings) -> Void, _ name: String) -> (Answer, Answer) {
            var s = base
            edit(&s)
            let url = dir.appendingPathComponent("gap-\(name)/settings.json")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            write(s, to: url)
            let c = Client(MCPServer(world: world(url), trace: { _ in }))
            return (c.call("read_translation_log"), c.call("list_apps"))
        }
        let off = gap({ $0.savesTranscripts = false; $0.exportFolder = dir.appendingPathComponent("none").path }, "off")
        let noJSONL = gap({ $0.transcriptFormats = [.markdown, .srt]; $0.exportFolder = dir.appendingPathComponent("none").path }, "nojsonl")
        let empty = gap({ $0.exportFolder = dir.appendingPathComponent("none").path }, "empty")
        let noFolder = gap({ $0.exportFolder = "" }, "nofolder")
        check("a log that is off says to turn on Save transcripts and to add jsonl",
              off.0.isError && off.0.text.contains("Save transcripts") && off.0.text.contains("jsonl"))
        check("a log without jsonl in transcriptFormats says to add it", noJSONL.0.isError && noJSONL.0.text.contains("transcriptFormats") && noJSONL.0.text.contains("\"jsonl\""))
        check("a log with no lines yet says so", empty.0.isError && empty.0.text.contains("no lines yet"))
        check("no folder says where to choose one", noFolder.0.isError && noFolder.0.text.contains("choose the folder"))
        check("list_apps still lists the profiles when there is no log, and says why",
              (off.1.data["log"] as? [String: Any])?["available"] as? Bool == false && ((off.1.data["log"] as? [String: Any])?["reason"] as? String)?.contains("Save transcripts") == true
              && (off.1.data["profiles"] as? [[String: Any]])?.count == 1)
        var offWithLines = base
        offWithLines.savesTranscripts = false
        let offURL = dir.appendingPathComponent("off-with-lines.json")
        write(offWithLines, to: offURL)
        let old = Client(MCPServer(world: world(offURL), trace: { _ in })).call("read_translation_log")
        check("lines written earlier are still read while the log is off, with a note", !old.isError && old.rows.count == 5 && (old.data["note"] as? String)?.contains("off") == true)

        // The App Store build has no folder path: the folder is a security-scoped bookmark in the preferences, never in the file
        var bookmarked = base
        bookmarked.exportFolder = ""
        bookmarked.exportBookmark = ExportFolder.makeBookmark(for: export)
        let bookmarkURL = dir.appendingPathComponent("bookmark/settings.json")
        try? FileManager.default.createDirectory(at: bookmarkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        write(bookmarked, to: bookmarkURL)
        let viaBookmark = Client(MCPServer(world: world(bookmarkURL, saved: bookmarked), trace: { _ in })).call("read_translation_log")
        let noBookmark = Client(MCPServer(world: world(bookmarkURL, saved: base), trace: { _ in })).call("read_translation_log")
        check("the log opens through the folder bookmark of the preferences when the file names no folder, and says to choose one when there is none",
              bookmarked.exportBookmark != nil && !viaBookmark.isError && viaBookmark.rows.count == 5 && noBookmark.isError && noBookmark.text.contains("choose the folder"))

        // get_memory
        let game = client.call("get_memory", ["app": "com.example.game"])
        check("get_memory: the note, the names and the languages of the profile",
              !game.isError && game.data["note"] as? String == "Fantasy RPG. Keep it formal." && game.data["appName"] as? String == "Example Game"
              && game.data["source"] as? String == "en" && game.data["target"] as? String == "ja"
              && (game.data["entries"] as? [[String: Any]])?.map({ $0["src"] as? String }) == ["九十九", "魔王城"]
              && (game.data["entries"] as? [[String: Any]])?.first?["kind"] as? String == "person")
        let none = client.call("get_memory", ["app": "com.example.nothing"])
        check("get_memory: an app without a profile is not an error and says set_memory creates it", !none.isError && none.data["exists"] as? Bool == false && (none.data["note"] as? String)?.contains("set_memory") == true)
        check("get_memory without an app, and with an empty one, is a tool error", client.call("get_memory").isError && client.call("get_memory", ["app": ""]).isError)

        // set_memory: merge
        let merged = client.call("set_memory", ["app": "com.example.game", "entries": [
            ["src": "魔王城", "dst": "the Demon Castle", "kind": "place"], ["src": "アレン", "dst": "Allen", "kind": "person", "gender": "m"]]])
        let afterMerge = stored("com.example.game")
        check("set_memory merge: a new name is added, one with the same src is replaced, the others and the note stay",
              !merged.isError && merged.list("added") == ["アレン"] && merged.list("updated") == ["魔王城"] && merged.list("removed").isEmpty && merged.data["created"] as? Bool == false
              && afterMerge?.entries.map(\.src) == ["九十九", "魔王城", "アレン"] && afterMerge?.entries[1].dst == "the Demon Castle" && afterMerge?.entries[2].gender == .m
              && afterMerge?.note == "Fantasy RPG. Keep it formal." && afterMerge?.appName == "Example Game" && afterMerge?.source == "en")
        check("set_memory answers with what changed by name and the count of names, not with the memory it was given",
              merged.data["entries"] as? Int == 3 && merged.data["note"] == nil && merged.data["issues"] == nil && merged.text.utf8.count < 300, "\(merged.text.utf8.count) bytes")
        check("get_memory returns the stored memory, which is what the file holds",
              afterMerge.map { client.call("get_memory", ["app": "com.example.game"]).text == MCPServer.json(MCPMemory.json($0)) } == true)
        let noted = client.call("set_memory", ["app": "com.example.game", "note": "Dark fantasy."])
        check("set_memory merge with a note replaces the note and leaves the names", !noted.isError && stored("com.example.game")?.note == "Dark fantasy." && stored("com.example.game")?.entries.count == 3)

        // set_memory: replace
        let replaced = client.call("set_memory", ["app": "com.example.game", "mode": "replace", "entries": [["src": "九十九", "dst": "Tsukumo", "kind": "person"]]])
        check("set_memory replace makes the memory exactly these names and clears the note that was left out",
              !replaced.isError && replaced.list("removed") == ["魔王城", "アレン"] && stored("com.example.game")?.entries.map(\.src) == ["九十九"] && stored("com.example.game")?.note == "")
        let cleared = client.call("set_memory", ["app": "com.example.game", "mode": "replace"])
        check("set_memory replace with nothing clears the memory", !cleared.isError && stored("com.example.game")?.hasMemory == false)
        let nothing = client.call("set_memory", ["app": "com.example.game"])
        check("set_memory merge with nothing to set is a tool error", nothing.isError && nothing.text.contains("give a note, entries or an appName"))

        // set_memory: rejected, nothing written
        let before = bytes()
        let badKind = client.call("set_memory", ["app": "com.example.game", "entries": [["src": "a", "dst": "b"], ["src": "c", "dst": "d", "kind": "villain"]]])
        check("set_memory with a bad entry is rejected with its path, and nothing is written",
              badKind.isError && badKind.text.contains("entries[1].kind") && badKind.text.contains("villain") && !badKind.text.contains("dropped") && bytes() == before
              && !FileManager.default.fileExists(atPath: file.appendingPathExtension("broken").path))
        let badKey = client.call("set_memory", ["app": "com.example.game", "entries": [["src": "a", "translation": "b"]]])
        check("set_memory with a src and no dst, or a key the entry does not have, names the path of each",
              badKey.isError && badKey.text.contains("entries[0]: missing \"dst\"") && badKey.text.contains("entries[0].translation") && bytes() == before)
        let badShape = client.call("set_memory", ["app": "com.example.game", "entries": "九十九 = Tsukumo"])
        let badNote = client.call("set_memory", ["app": "com.example.game", "note": String(repeating: "x", count: AppProfile.maxNoteLength + 1)])
        let badMode = client.call("set_memory", ["app": "com.example.game", "mode": "append", "note": "x"])
        check("set_memory with entries that are not a list, a note over the limit or a mode that is not one is rejected",
              badShape.isError && badShape.text.contains("entries:") && badNote.isError && badNote.text.contains("note:") && badMode.isError && badMode.text.contains("merge, replace") && bytes() == before)
        let tooMany = (0...AppProfile.maxEntries).map { ["src": "n\($0)", "dst": "m\($0)"] }
        let over = client.call("set_memory", ["app": "com.example.game", "entries": tooMany])
        check("set_memory with more than 40 names is rejected", over.isError && over.text.contains("the limit is \(AppProfile.maxEntries)") && bytes() == before)
        _ = client.call("set_memory", ["app": "com.example.game", "mode": "replace", "entries": Array(tooMany.prefix(AppProfile.maxEntries))])
        let full = bytes()
        let beyond = client.call("set_memory", ["app": "com.example.game", "entries": [["src": "extra", "dst": "more"]]])
        check("set_memory that would take the memory past 40 names is rejected and says how to make room",
              stored("com.example.game")?.entries.count == AppProfile.maxEntries && beyond.isError && beyond.text.contains("mode replace") && bytes() == full)

        // set_memory: a new profile
        let created = client.call("set_memory", ["app": "com.example.chat", "note": "Casual chat.", "entries": [["src": "田中", "dst": "Tanaka"]]])
        let chatProfile = stored("com.example.chat")
        check("set_memory on an app without a profile makes one on the base languages, named as installed",
              !created.isError && created.data["created"] as? Bool == true && chatProfile?.source == "ja" && chatProfile?.target == "ko" && chatProfile?.appName == "Example Chat"
              && chatProfile?.entries.first?.kind == .term && stored("com.example.game") != nil)
        let anon = client.call("set_memory", ["app": "com.example.unnamed", "appName": "Unnamed Game", "note": "x"])
        let anonymous = client.call("set_memory", ["app": "com.example.other", "note": "x"])
        check("a new profile takes the appName given, else the bundle ID", !anon.isError && stored("com.example.unnamed")?.appName == "Unnamed Game" && stored("com.example.other")?.appName == "com.example.other" && !anonymous.isError)
        let command = SettingsFileCommand.check(file)
        check("the file after these writes passes --check-settings", command.code == 0 && command.lines == ["ok"])

        // get_settings, set_settings, get_settings_schema
        let wanted = client.call("get_settings", ["keys": ["targetLanguage", "lensStyle", "customEngineID"]])
        let wantedValues = wanted.data["settings"] as? [String: Any] ?? [:]
        check("get_settings returns the named keys as settings.json holds them, a null id included",
              !wanted.isError && Set(wantedValues.keys) == ["targetLanguage", "lensStyle", "customEngineID"] && wantedValues["targetLanguage"] as? String == "ko"
              && wantedValues["lensStyle"] as? String == "glow" && wantedValues["customEngineID"] is NSNull)
        let everything = client.call("get_settings")
        let everyValue = everything.data["settings"] as? [String: Any] ?? [:]
        check("get_settings without keys returns every setting of the table the app writes, a switch that is off included, and none of the keys of 1.1.4 (read, never written)",
              Set(everyValue.keys) == Set(SettingSpec.all.filter { !$0.deprecated }.map(\.key)) && everyValue["agentConnection"] as? Bool == true
              && everyValue["glossaryApply"] as? String == "hint" && everyValue["appleUsesPinnedTerms"] == nil && everyValue["appProfiles"] == nil)
        let wrongKey = client.call("get_settings", ["keys": ["lensStile"]])
        check("get_settings with a key that is not a setting names where and what is allowed", wrongKey.isError && wrongKey.text.contains("keys[0]") && wrongKey.text.contains("lensStyle"))
        let settingsBefore = bytes()
        let changedSettings = client.call("set_settings", ["values": ["targetLanguage": "en", "lensStyle": "subtle", "boxOpacity": 0.8]])
        let changedBack = client.call("get_settings", ["keys": ["targetLanguage", "lensStyle", "boxOpacity"]]).data["settings"] as? [String: Any] ?? [:]
        let appliedValues = changedSettings.data["applied"] as? [String: Any] ?? [:]
        check("set_settings applies valid keys, reports what changed with the stored values, and the file holds them",
              !changedSettings.isError && Set(appliedValues.keys) == ["targetLanguage", "lensStyle", "boxOpacity"] && appliedValues["lensStyle"] as? String == "subtle"
              && bytes() != settingsBefore && SettingsFileCheck.read(bytes() ?? Data(), over: AppSettings()).settings.targetLanguage == "en"
              && SettingsFileCommand.check(file).code == 0)
        check("get_settings round-trips what set_settings wrote", changedBack["targetLanguage"] as? String == "en" && changedBack["lensStyle"] as? String == "subtle" && changedBack["boxOpacity"] as? Double == 0.8)
        let again = client.call("set_settings", ["values": ["lensStyle": "subtle"]])
        check("set_settings with a value the file already has changes nothing and lists the key as unchanged",
              !again.isError && (again.data["applied"] as? [String: Any])?.isEmpty == true && again.list("unchanged") == ["lensStyle"])
        let settingsKept = bytes()
        let badValue = client.call("set_settings", ["values": ["lensStyle": "neon", "boxOpacity": 0.7]])
        check("set_settings with a bad value is rejected with its path in the arguments, and the valid key beside it is not written either",
              badValue.isError && badValue.text.contains("values.lensStyle") && badValue.text.contains("neon") && !badValue.text.contains("ignored") && bytes() == settingsKept)
        let nested = client.call("set_settings", ["values": ["appProfiles": [["bundleID": "com.example.x", "source": "ja", "target": "ko", "entries": [["src": "a", "dst": "b", "kind": "villain"]]]]]])
        check("set_settings names the path of a bad value inside a list", nested.isError && nested.text.contains("values.appProfiles[0].entries[0].kind") && bytes() == settingsKept)
        let typo = client.call("set_settings", ["values": ["lenStyle": "glow"]])
        check("set_settings with a key that is not a setting says which one it meant", typo.isError && typo.text.contains("unknown key values.lenStyle") && typo.text.contains("lensStyle") && bytes() == settingsKept)
        let person = client.call("set_settings", ["values": ["agentConnection": false, "lensStyle": "glow"]])
        check("set_settings refuses agentConnection, which only the person changes, and writes nothing",
              person.isError && person.text.contains("agentConnection cannot be changed through MCP") && person.text.contains(String(localized: "Connect an agent (MCP)")) && bytes() == settingsKept)
        check("set_settings with no settings, or values that is not an object, is a tool error",
              client.call("set_settings", ["values": [String: Any]()]).isError && client.call("set_settings", ["values": "glow"]).isError && client.call("set_settings").isError && bytes() == settingsKept)
        let viaSettings = client.call("set_settings", ["values": ["appProfiles": [["bundleID": "com.example.x", "appName": "X", "source": "ja", "target": "ko", "note": "Via settings.", "entries": [["src": "a", "dst": "b"]]]]]])
        check("set_settings also writes appProfiles whole, which get_memory then reads",
              !viaSettings.isError && client.call("get_memory", ["app": "com.example.x"]).data["note"] as? String == "Via settings." && stored("com.example.game") == nil)
        // Command engines are the person's: an agent adds other kinds, and cannot add or change a command engine
        let engineID = "5B1F3C0A-6D2E-4E0B-9A41-0C7D2A9E1F11"
        let compat: [String: Any] = ["id": engineID, "name": "Local", "kind": "openAICompatible", "baseURL": "http://localhost:11434/v1", "model": "gemma3:4b"]
        let beforeEngine = bytes()
        let addCompat = client.call("set_settings", ["values": ["engines": [compat]]])
        let engineList = (client.call("get_settings", ["keys": ["engines"]]).data["settings"] as? [String: Any])?["engines"] as? [[String: Any]] ?? []
        check("set_settings adds an openAICompatible engine, and get_settings returns it",
              !addCompat.isError && addCompat.list("unchanged").isEmpty && engineList.count == 1 && engineList.first?["kind"] as? String == "openAICompatible" && bytes() != beforeEngine
              && SettingsFileCommand.check(file).code == 0)
        let withEngine = bytes()
        let newCommand: [String: Any] = ["name": "Mine", "kind": "command", "command": ["executable": "/usr/bin/true"]]
        let addCommand = client.call("set_settings", ["values": ["engines": [compat, newCommand]]])
        check("set_settings refuses to add an engine of kind command, and writes nothing",
              addCommand.isError && addCommand.text.contains("Command engines are added by the person in Settings.") && bytes() == withEngine)
        let toCommand = client.call("set_settings", ["values": ["engines": [["id": engineID, "name": "Local", "kind": "command", "command": ["executable": "/usr/bin/true"]]]]])
        check("set_settings refuses to change an existing engine to kind command, and writes nothing",
              toCommand.isError && toCommand.text.contains("Command engines are added by the person in Settings.") && bytes() == withEngine)
        let owned = dir.appendingPathComponent("owned/settings.json")
        let ownedCommand: [String: Any] = ["id": "7C2E9D40-1B3A-4F58-8E6D-2A9B0C4D5E66", "name": "Mine", "kind": "command", "command": ["executable": "/usr/bin/true"]]
        try? FileManager.default.createDirectory(at: owned.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: ["engines": [ownedCommand]]).write(to: owned)
        let ownedBefore = bytes(owned)
        let ownedClient = Client(MCPServer(world: world(owned, saved: base), trace: { _ in }))
        var otherPath = ownedCommand
        otherPath["command"] = ["executable": "/bin/sh"]
        let editCommand = ownedClient.call("set_settings", ["values": ["engines": [otherPath]]])
        check("set_settings refuses to change the program of the person's command engine, and writes nothing",
              editCommand.isError && editCommand.text.contains("Command engines are added by the person in Settings.") && bytes(owned) == ownedBefore)
        let keepCommand = ownedClient.call("set_settings", ["values": ["engines": [ownedCommand, compat]]])
        let keptKinds = (ownedClient.call("get_settings", ["keys": ["engines"]]).data["settings"] as? [String: Any])?["engines"] as? [[String: Any]] ?? []
        check("set_settings may add another kind of engine beside the person's command engine, which stays as it was",
              !keepCommand.isError && keptKinds.compactMap { $0["kind"] as? String } == ["command", "openAICompatible"] && bytes(owned) != ownedBefore)
        let dropCommand = ownedClient.call("set_settings", ["values": ["engines": [compat]]])
        check("set_settings may take a command engine out of the list", !dropCommand.isError && SettingsFileCheck.read(bytes(owned) ?? Data(), over: AppSettings()).settings.engines.count == 1)
        let schema = client.call("get_settings_schema")
        let schemaProps = schema.data["properties"] as? [String: Any] ?? [:]
        check("get_settings_schema is the schema the app writes beside settings.json, with the switch in it and off by default",
              !schema.isError && NSDictionary(dictionary: schema.data).isEqual(to: (try? JSONSerialization.jsonObject(with: SettingsSchema.data())) as? [String: Any] ?? [:])
              && (schemaProps["agentConnection"] as? [String: Any])?["default"] as? Bool == false)
        let one = client.call("get_settings_schema", ["key": "glossary"])
        let wholeProperties = (try? JSONSerialization.jsonObject(with: SettingsSchema.data()) as? [String: Any])?["properties"] as? [String: Any] ?? [:]
        let unknownKey = client.call("get_settings_schema", ["key": "glossery"])
        check("get_settings_schema with a key returns that setting's schema alone (a fraction of the whole), and a key that is not a setting names the ones that are",
              !one.isError && one.data["key"] as? String == "glossary" && NSDictionary(dictionary: one.data["schema"] as? [String: Any] ?? [:]).isEqual(to: wholeProperties["glossary"] as? [String: Any] ?? [:])
              && one.text.utf8.count * 20 < schema.text.utf8.count && unknownKey.isError && unknownKey.text.contains("glossary"),
              "key \(one.text.utf8.count) bytes, whole \(schema.text.utf8.count)")
        let settingsTools = listed.filter { ["get_settings", "set_settings"].contains($0["name"] as? String ?? "") }
        let valuesInList = (((listed.first { $0["name"] as? String == "set_settings" })?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?["values"] as? [String: Any]
        check("tools/list gives set_settings' values in short (the key names, not the schema of each), and says API keys stay in the Keychain",
              valuesInList?["properties"] == nil && (valuesInList?["propertyNames"] as? [String: Any])?["enum"] as? [String] == SettingSpec.all.map(\.key)
              && settingsTools.count == 2 && settingsTools.allSatisfy { ($0["description"] as? String)?.contains("Keychain") == true })

        // settings.json that is not there, or is not JSON
        let fresh = dir.appendingPathComponent("fresh/settings.json")
        let fromNothing = Client(MCPServer(world: world(fresh, saved: base), trace: { _ in })).call("set_memory", ["app": "com.example.game", "note": "First."])
        check("set_memory with no settings.json writes one, with its schema beside it, that passes --check-settings",
              !fromNothing.isError && stored("com.example.game", at: fresh)?.note == "First." && SettingsFileCommand.check(fresh).code == 0
              && FileManager.default.fileExists(atPath: fresh.deletingLastPathComponent().appendingPathComponent(SettingsFileFormat.schemaName).path))
        let broken = dir.appendingPathComponent("broken/settings.json")
        try? FileManager.default.createDirectory(at: broken.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("{\n  \"lensStyle\": \"glow\",\n".utf8).write(to: broken)
        let brokenBefore = bytes(broken)
        let refused = Client(MCPServer(world: world(broken, saved: base), trace: { _ in })).call("set_memory", ["app": "com.example.game", "note": "x"])
        check("set_memory on a settings.json that is not JSON says so and leaves it alone", refused.isError && refused.text.contains("not valid JSON") && bytes(broken) == brokenBefore)
        let typed = dir.appendingPathComponent("typed/settings.json")
        try? FileManager.default.createDirectory(at: typed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("{\n  \"lenStyle\": \"glow\",\n  \"targetLanguage\": \"ko\"\n}\n".utf8).write(to: typed)
        let typedBefore = bytes(typed)
        let withIssues = Client(MCPServer(world: world(typed, saved: base), trace: { _ in })).call("set_memory", ["app": "com.example.game", "note": "x"])
        check("set_memory on a file with problems keeps the old file as settings.json.broken and reports it",
              !withIssues.isError && bytes(typed.appendingPathExtension("broken")) == typedBefore && withIssues.list("issues").first?.contains("settings.json.broken") == true
              && stored("com.example.game", at: typed)?.note == "x")

        // The app: a write by the server is applied by the running app, and not written back
        let appURL = model.settingsFile.url
        let profilesBefore = model.settings.appProfiles
        let viaApp = Client(MCPServer(world: world(appURL, saved: base), trace: { _ in })).call("set_memory", ["app": "com.example.mcp.check", "appName": "MCP Check", "note": "From an agent.", "entries": [["src": "九十九", "dst": "Tsukumo"]]])
        let written = bytes(appURL)
        model.settingsFileChanged()
        let applied = AppProfiles.profile(for: "com.example.mcp.check", in: model.settings.appProfiles)
        check("the running app applies what set_memory wrote to its settings file, and does not write it back",
              !viaApp.isError && applied?.note == "From an agent." && applied?.entries.map(\.dst) == ["Tsukumo"] && bytes(appURL) == written && model.settingsIssues.isEmpty)
        model.settings.appProfiles = profilesBefore
        func switchKey() -> Bool? { ((try? JSONSerialization.jsonObject(with: Data(contentsOf: appURL))) as? [String: Any])?["agentConnection"] as? Bool }
        model.settings.agentConnection = true
        let onKey = switchKey()
        model.settings.agentConnection = false
        check("the switch in Settings writes agentConnection: true to settings.json and takes the key out when it is turned off", onKey == true && switchKey() == nil)

        // One copy of each result
        let single: [(String, [String: Any])] = [("list_apps", [:]), ("read_translation_log", ["app": "com.example.chat"]), ("term_renderings", ["app": "com.example.chat", "terms": ["田中"]]),
                                                 ("get_memory", ["app": "com.example.game"]), ("set_memory", ["app": "com.example.game", "note": "One copy."]),
                                                 ("get_settings", ["keys": ["lensStyle"]]), ("get_settings_schema", ["key": "glossary"]), ("set_settings", ["values": ["lensStyle": "glow"]])]
        let answers = single.map { client.call($0.0, $0.1) }
        let recompacted = answers.map { (try? JSONSerialization.jsonObject(with: Data($0.text.utf8))).map { MCPServer.json($0) } }
        check("each result is one text block of compact JSON and no structuredContent, so the payload is read once, by a client that reads either",
              answers.count == 8 && answers.allSatisfy { !$0.isError && !$0.doubled } && zip(answers, recompacted).allSatisfy { $0.0.text == $0.1 },
              "\(zip(single, answers).map { "\($0.0.0) \($0.1.isError ? "error" : $0.1.doubled ? "doubled" : "ok")" })")

        // What the take's calls cost an agent (round mcp2, 2026-10-21; tools/mcp/budget.py measures the same on a binary, with the wire bytes)
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("tools/mcp/fixtures")
        let takeCalls = (try? JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("take-calls.json")))) as? [[String: Any]] ?? []
        let takeLog = LensExport.transcriptsFolder(dir.appendingPathComponent("take"))
        try? FileManager.default.createDirectory(at: takeLog, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: fixtures.appendingPathComponent("take-log.jsonl"), to: takeLog.appendingPathComponent("Lens 2026-10-20 19-14.jsonl"))
        var takeSettings = base
        takeSettings.exportFolder = dir.appendingPathComponent("take").path
        takeSettings.appProfiles = []
        let takeFile = dir.appendingPathComponent("take-settings.json")
        write(takeSettings, to: takeFile)
        let taker = Client(MCPServer(world: world(takeFile), trace: { _ in }))
        let takeBytes = takeCalls.map { call -> Int in
            taker.call(call["tool"] as? String ?? "", call["arguments"] as? [String: Any] ?? [:]).text.utf8.count
        }
        // BEFORE (base 4d08e42, 2026-10-21, the agent's copy): list_apps 188 + read_translation_log (limit 65, 65 rows) 15,765 + set_memory 1,630
        // = 17,583 bytes; the round's target is 40 % of that, 7,033. AFTER (this code, same fixture, 2026-10-21): 188 + 6,093 + 247 = 6,528 bytes, 37 %.
        // A ceiling is the measured value + 10 %, rounded up: 207, 6,703, 272.
        let ceilings = [207, 6703, 272]
        check("the take's three calls (list_apps, read_translation_log of 65 rows, set_memory of 8 names) cost an agent at most \(ceilings.reduce(0, +)) bytes, 40 % of the 17,583 they did",
              takeCalls.count == 3 && zip(takeBytes, ceilings).allSatisfy { $0 <= $1 } && takeBytes.reduce(0, +) * 100 <= 17_583 * 40, "bytes \(takeBytes), ceilings \(ceilings)")

        // translate_text: the lens's own path, with the app's memory
        let alice = MemoryEntry(src: "Alice", dst: "앨리스", kind: .person, gender: .f)
        if let mock = ContextChecks.Mock(mode: "ok", flags: "native") {
            defer { mock.stop() }
            let engine = ContextChecks.engine("openai", base: mock.base)
            var translating = ContextChecks.settings(engine, profiles: [ContextChecks.profile(ContextChecks.chat, entries: [alice], note: "casual chat between friends")])
            translating.agentConnection = true
            let translateFile = dir.appendingPathComponent("translate/settings.json")
            try? FileManager.default.createDirectory(at: translateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            write(translating, to: translateFile)
            func translator(_ s: AppSettings = translating, at url: URL? = nil, secrets: any SecretStore = MemorySecrets([engine.id: "dummy"])) -> Client {
                let file = url ?? translateFile
                write(s, to: file)
                return Client(MCPServer(world: MCPWorld(settingsURL: file, saved: { s }, appName: { _ in nil }, secrets: secrets), trace: { _ in }))
            }
            let t = translator()
            let sent = mock.bodies.count
            let withMemory = t.call("translate_text", ["lines": ["Alice sent a photo"], "app": ContextChecks.chat])
            let body = mock.bodies.dropFirst(sent).last ?? ""
            check("translate_text through the lens's path: the translation, the engine that made it, and the app's memory in what the engine was sent",
                  !withMemory.isError && withMemory.columns == ["translation", "engine"] && withMemory.rows.count == 1 && (withMemory.rows.first?[0] as? String)?.contains("Alice sent a photo") == true
                  && withMemory.rows.first?[1] as? String == "O" && withMemory.data["memory"] as? String == "used" && body.contains("앨리스") && body.contains("casual chat between friends"),
                  "\(withMemory.text) body \(body.prefix(200))")
            let before = mock.bodies.count
            let withoutApp = t.call("translate_text", ["lines": ["Alice sent another photo"]])
            check("translate_text without an app sends the lines alone: no memory, no note",
                  !withoutApp.isError && withoutApp.data["memory"] == nil && mock.bodies.count == before + 1 && !(mock.bodies.last ?? "").contains("앨리스") && withoutApp.rows.first?[1] as? String == "O")
            // Apple Translation answers on the main queue, which this run holds (a job of the main actor, waiting on the call): its answer is
            // `tools/mcp/smoke.sh`'s, in a process that waits on the run loop alone. Here the choice of the engine is checked: "apple" is no
            // added engine, and an id is that engine.
            var chosen = translating
            try? MCPTranslate.choose("apple", in: &chosen)
            let second = EngineConfig(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2") ?? UUID(), name: "P",
                                      kind: .openAICompatible(baseURL: mock.base.appendingPathComponent("v1"), model: "m2", thinking: .off, extraHeaders: [:]))
            var twoEngines = translating
            twoEngines.engines.append(second)
            var byID = twoEngines
            try? MCPTranslate.choose(second.id.uuidString.lowercased(), in: &byID)
            let refused: Bool = { var s = twoEngines; return (try? MCPTranslate.choose("deepl", in: &s)) == nil }()
            check("translate_text's engine argument: apple is no added engine, an id (in any case) is that engine, and a name that is neither is refused",
                  chosen.customEngineID == nil && byID.customEngineID == second.id && twoEngines.customEngineID == engine.id && refused)
            let other = translator(twoEngines, at: dir.appendingPathComponent("translate-two/settings.json"), secrets: MemorySecrets([engine.id: "dummy", second.id: "dummy"]))
            let sentBefore = mock.bodies.count
            let viaOther = other.call("translate_text", ["lines": ["Alice sent a third photo"], "engine": second.id.uuidString])
            let otherBody = mock.bodies.dropFirst(sentBefore).last ?? ""
            check("translate_text with the id of another engine sends the line to that engine and names it",
                  !viaOther.isError && viaOther.rows.first?[1] as? String == second.name && otherBody.contains("\"m2\"") && mock.bodies.count == sentBefore + 1,
                  viaOther.text)
            let unknownEngine = t.call("translate_text", ["lines": ["x"], "engine": "00000000-0000-0000-0000-000000000000"])
            check("translate_text with an engine that is not one names apple and the engines there are",
                  unknownEngine.isError && unknownEngine.text.contains("apple") && unknownEngine.text.contains(engine.id.uuidString))
            check("translate_text with no line, or more than 20, or a line over the limit is a tool error",
                  t.call("translate_text", ["lines": [String]()]).isError && t.call("translate_text", ["lines": (0..<21).map { "line \($0)" }]).isError
                  && t.call("translate_text", ["lines": [String(repeating: "a", count: 2001)]]).isError && t.call("translate_text").isError)
            var commanding = translating
            let program = EngineConfig(name: "Mine", kind: .command(CommandSpec(executable: "/usr/bin/true")))
            commanding.engines.append(program)
            commanding.customEngineID = program.id
            let command = translator(commanding, at: dir.appendingPathComponent("translate-command/settings.json")).call("translate_text", ["lines": ["x"]])
            check("translate_text does not run a command engine, and says so", command.isError && command.text.contains("command engines"))
            let locked = translator(secrets: Unreachable()).call("translate_text", ["lines": ["x"]])
            check("translate_text says so when the engine's key is in a Keychain this process cannot read", locked.isError && locked.text.contains("Keychain") && locked.text.contains(engine.name))
        } else {
            check("translate_text: the mock server starts", false)
        }

        // The trace and the command
        check("each message leaves one trace line, with the tool and the app, and never the text of a note or a name",
              traces.count == client.sent && traces.contains { $0.contains("tools/call set_memory app=com.example.game -> ok") }
              && traces.contains { $0.contains("tools/call set_memory app=com.example.game -> tool error:") } && traces.contains { $0.contains("unknown method resources/list") }
              && !traces.contains { $0.contains("Tsukumo") || $0.contains("Dark fantasy") || $0.contains("九十九") })
        check("every reply is one line of JSON", client.replies.allSatisfy { !$0.contains("\n") && (try? JSONSerialization.jsonObject(with: Data($0.utf8))) != nil })
        check("the command that adds the server quotes the path of this install",
              MCPServer.addCommand(executablePath: "/Applications/Mwoyeo.app/Contents/MacOS/Mwoyeo") == "claude mcp add mwoyeo -- \"/Applications/Mwoyeo.app/Contents/MacOS/Mwoyeo\" --mcp"
              && MCPServer.addCommand(executablePath: "/tmp/a b/\"x\"$y") == "claude mcp add mwoyeo -- \"/tmp/a b/\\\"x\\\"\\$y\" --mcp")
        return failed
    }
}
#endif
