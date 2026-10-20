#if !MAS
import Foundation
import MwoyeoCore

/// The checks of `Mwoyeo --mcp`, run by `--capture-ui … check-logic` and alone by `mcp-checks` (PASS/FAIL lines). The server is driven in
/// process with JSON-RPC lines, over a scratch settings.json and a scratch Transcripts folder written by the app's own `TranscriptWriter`,
/// so a change to the log's line or to the file's checks shows here. The process itself (stdout, the end at EOF) is `tools/mcp/smoke.sh`.
@MainActor
enum MCPChecks {
    /// A tool's answer: whether it is an error, its text and its structured content.
    private struct Answer {
        var isError: Bool
        var text: String
        var data: [String: Any]

        var lines: [[String: Any]] { data["lines"] as? [[String: Any]] ?? [] }
        var originals: [String] { lines.compactMap { $0["original"] as? String } }
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
            let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            return Answer(isError: result["isError"] as? Bool ?? false, text: text, data: result["structuredContent"] as? [String: Any] ?? [:])
        }
    }

    static func run(_ model: AppModel) -> Int {
        var failed = 0
        func check(_ what: String, _ ok: Bool) {
            print("check-logic: \(ok ? "PASS" : "FAIL") mcp: \(what)")
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
        let initialized = client.send("notifications/initialized", notification: true)
        let ping = client.send("ping")?["result"] as? [String: Any]
        check("notifications/initialized has no reply and ping an empty result", initialized == nil && ping?.isEmpty == true)
        let listed = (client.send("tools/list")?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        check("tools/list: the seven tools, each with a description and an object schema",
              listed.compactMap { $0["name"] as? String } == ["list_apps", "read_translation_log", "get_memory", "set_memory", "get_settings", "set_settings", "get_settings_schema"]
              && listed.allSatisfy { ($0["description"] as? String)?.isEmpty == false && ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" })
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
                            switched.call("set_settings", ["values": ["lensStyle": "subtle"]]), switched.call("get_settings_schema")]
        let offText = "Agent connection is off. Turn it on in Mwoyeo Settings → \(String(localized: "Connect an agent (MCP)"))."
        check("switch off: all seven tools are refused with the name of the row to turn on, and nothing is written",
              refusedCalls.count == 7 && refusedCalls.allSatisfy { $0.isError && $0.text == offText } && bytes(switchURL) == switchBefore)
        let handshake = switched.send("initialize")?["result"] as? [String: Any]
        let toolsOff = ((switched.send("tools/list")?["result"] as? [String: Any])?["tools"] as? [Any])?.count
        check("switch off: initialize and tools/list still answer", handshake?["protocolVersion"] as? String == "2025-06-18" && toolsOff == 7)
        write(base, to: switchURL)
        let nowOn = switched.call("list_apps")
        check("switch on: the same server works at the next call, without a restart (the setting is read at each call)", !nowOn.isError && (nowOn.data["loggedApps"] as? [Any])?.count == 2)
        check("the switch is off in a file without the key, in no file at all and by default, and the file holds the key only while it is on",
              !SettingsFileCheck.read(Data("{}".utf8), over: AppSettings()).settings.agentConnection && !AppSettings().agentConnection
              && Client(MCPServer(world: world(dir.appendingPathComponent("no/such/settings.json")), trace: { _ in })).call("list_apps").isError
              && !String(decoding: SettingsFileFormat.render(AppSettings()), as: UTF8.self).contains("agentConnection")
              && String(decoding: SettingsFileFormat.render(base), as: UTF8.self).contains("\"agentConnection\": true"))

        // read_translation_log
        let all = client.call("read_translation_log")
        check("read_translation_log: the five lines of the writer's files, oldest first, with the agreed fields",
              !all.isError && all.originals == ["こんにちは", "田中さんは来ましたか", "ありがとう", "勇者アレンは魔王城へ向かった", "九十九の剣"]
              && all.lines.first.map { Set($0.keys) == ["time", "app", "source", "target", "engine", "original", "translation"] } == true
              && all.lines.first?["app"] as? String == "com.example.chat" && all.lines.first?["engine"] as? String == "Ollama"
              && all.lines.last?["translation"] as? String == "쓰쿠모의 검" && all.data["matching"] as? Int == 5)
        let chat = client.call("read_translation_log", ["app": "com.example.chat"])
        check("read_translation_log filters by app", chat.originals == ["こんにちは", "田中さんは来ましたか", "ありがとう"] && chat.data["matching"] as? Int == 3)
        let newest = client.call("read_translation_log", ["app": "com.example.chat", "limit": 2])
        check("read_translation_log limit gives the newest lines, still oldest first",
              newest.originals == ["田中さんは来ましたか", "ありがとう"] && newest.data["returned"] as? Int == 2 && newest.data["matching"] as? Int == 3)
        let since = ISO8601DateFormatter().string(from: t0.addingTimeInterval(3600))
        let late = client.call("read_translation_log", ["since": since])
        check("read_translation_log since keeps the lines from that time on", late.originals == ["勇者アレンは魔王城へ向かった", "九十九の剣"])
        let badLimit = client.call("read_translation_log", ["limit": 0]), bigLimit = client.call("read_translation_log", ["limit": 2001])
        let badSince = client.call("read_translation_log", ["since": "yesterday"]), badType = client.call("read_translation_log", ["limit": "ten"])
        check("a limit of 0 or 2001, a limit that is not a number and a since that is not a time are tool errors naming the argument",
              badLimit.isError && badLimit.text.contains("limit:") && bigLimit.isError && bigLimit.text.contains("2000")
              && badSince.isError && badSince.text.contains("since") && badType.isError && badType.text.contains("limit:"))
        let extra = client.call("read_translation_log", ["lines": 3])
        check("an argument the tool does not take is a tool error that names the ones it takes",
              extra.isError && extra.text.contains("unknown key lines") && extra.text.contains("limit"))

        // list_apps
        let apps = client.call("list_apps")
        let logged = apps.data["loggedApps"] as? [[String: Any]] ?? []
        let profiles = apps.data["profiles"] as? [[String: Any]] ?? []
        check("list_apps: the apps of the log with their names, line counts and last time, newest first",
              logged.map { $0["bundleID"] as? String } == ["com.example.game", "com.example.chat"] && logged.map { $0["lines"] as? Int } == [2, 3]
              && logged.map { $0["appName"] as? String } == ["Example Game", "Example Chat"] && logged.first?["last"] as? String == late.lines.last?["time"] as? String
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
        check("lines written earlier are still read while the log is off, with a note", !old.isError && old.lines.count == 5 && (old.data["note"] as? String)?.contains("off") == true)

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
              bookmarked.exportBookmark != nil && !viaBookmark.isError && viaBookmark.lines.count == 5 && noBookmark.isError && noBookmark.text.contains("choose the folder"))

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
        let echoed = (merged.data["entries"] as? [[String: Any]])?.map { $0["src"] as? String }
        check("set_memory returns the stored memory, which is what the file holds",
              echoed == ["九十九", "魔王城", "アレン"] && afterMerge.map { client.call("get_memory", ["app": "com.example.game"]).text == MCPServer.json(MCPMemory.json($0)) } == true)
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
        check("get_settings without keys returns every setting of the table, a switch that is off included",
              Set(everyValue.keys) == Set(SettingSpec.all.map(\.key)) && everyValue["agentConnection"] as? Bool == true && everyValue["appleUsesPinnedTerms"] as? Bool == false)
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
