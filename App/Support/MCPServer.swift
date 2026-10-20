import AppKit
import Foundation
import MwoyeoCore
import MwoyeoEngines

/// `Mwoyeo --mcp`: the Model Context Protocol on stdin and stdout, so an agent (Claude Code and the like) reads the translation
/// log and writes an app's memory through the app's own code instead of by hand in settings.json. The same executable runs in the
/// DMG and the App Store build, with that build's entitlements and container, and every write passes the settings file's own checks.
///
/// The protocol is JSON-RPC 2.0, one message per line (spec 2025-06-18, the stdio transport): `initialize`, `notifications/initialized`,
/// `ping`, `tools/list` and `tools/call`. Nothing but protocol goes to stdout; a line of trace per message goes to stderr. The tools
/// are `MCPTool` (`MCPTools.swift`); the process ends when stdin does. The person switches the connection on in Settings
/// (`agentConnection`): off, the server answers `initialize` and `tools/list` and refuses every `tools/call`.
@MainActor
final class MCPServer {
    static let protocolVersion = "2025-06-18"

    let world: MCPWorld
    private let trace: (String) -> Void

    init(world: MCPWorld, trace: @escaping (String) -> Void = MCPServer.toStandardError) {
        self.world = world
        self.trace = trace
    }

    nonisolated static func toStandardError(_ line: String) {
        try? FileHandle.standardError.write(contentsOf: Data((line + "\n").utf8))
    }

    // MARK: the process

    /// Serves stdin until it ends, then exits. No window and no NSApplication: the executable is a command-line tool here.
    static func runStdio() -> Never {
        // A client that went away must end the loop, not the process with a signal.
        signal(SIGPIPE, SIG_IGN)
        let server = MCPServer(world: .live())
        server.trace("mcp: serving on stdio, settings \(server.world.settingsURL.path)")
        while let line = readLine(strippingNewline: true) {
            guard !line.allSatisfy(\.isWhitespace), let reply = server.handle(line) else { continue }
            do { try FileHandle.standardOutput.write(contentsOf: Data((reply + "\n").utf8)) } catch { exit(0) }
        }
        exit(0)
    }

    /// The command that adds this install as an MCP server of Claude Code; the path is quoted for a shell.
    static func addCommand(executablePath: String = Bundle.main.executablePath ?? CommandLine.arguments[0]) -> String {
        var quoted = ""
        for c in executablePath {
            if "\\\"$`".contains(c) { quoted.append("\\") }
            quoted.append(c)
        }
        return "claude mcp add mwoyeo -- \"\(quoted)\" --mcp"
    }

    // MARK: a message

    /// One line in, the reply line out; nil when the message is a notification. The trace line says what came in and how it went.
    func handle(_ line: String) -> String? {
        let began = ProcessInfo.processInfo.systemUptime
        let (reply, label, outcome) = respond(to: line)
        trace("mcp: \(label) -> \(outcome) (\(Int((ProcessInfo.processInfo.systemUptime - began) * 1000)) ms)")
        return reply.map(Self.encode)
    }

    private func respond(to line: String) -> (reply: [String: Any]?, label: String, outcome: String) {
        let message: MCPMessage
        do {
            message = try MCPMessage(line)
        } catch {
            let fault = (error as? MCPFault) ?? MCPFault(.internalError, "\(error)")
            return (Self.faultReply(id: NSNull(), fault), "unreadable line", fault.described)
        }
        do {
            let result = try answer(message)
            let failed = result["isError"] as? Bool == true
            let outcome = failed ? "tool error: \(Self.firstText(of: result).prefix(160))" : "ok"
            return (message.id.map { ["jsonrpc": "2.0", "id": $0, "result": result] }, message.label, outcome)
        } catch {
            let fault = (error as? MCPFault) ?? MCPFault(.internalError, "\(error)")
            return (message.id.map { Self.faultReply(id: $0, fault) }, message.label, fault.described)
        }
    }

    private func answer(_ message: MCPMessage) throws -> [String: Any] {
        guard let method = MCPMethod(rawValue: message.method) else {
            throw MCPFault(.methodNotFound, "unknown method \(message.method)")
        }
        switch method {
        case .initialize:
            return [
                "protocolVersion": Self.protocolVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "mwoyeo", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"],
                "instructions": Self.instructions,
            ]
        case .initialized, .cancelled, .ping:
            return [:]
        case .toolsList:
            return ["tools": MCPTool.allCases.map(\.listing)]
        case .toolsCall:
            return try callTool(message.params)
        }
    }

    private func callTool(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String, let tool = MCPTool(rawValue: name) else {
            throw MCPFault(.invalidParams, "unknown tool \(params["name"] as? String ?? "(no name)"); the tools are \(MCPTool.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        // Read at each call, so turning the switch on needs no restart of the agent.
        guard world.settings().agentConnection else { return Self.failure(Self.offMessage) }
        do {
            return Self.success(try tool.run(params["arguments"] as? [String: Any] ?? [:], in: world))
        } catch let failure as MCPToolError {
            return Self.failure(failure.message)
        }
    }

    static var offMessage: String { "Agent connection is off. Turn it on in Mwoyeo Settings → \(MCPSettings.switchLabel)." }

    /// The workflow, in the words an agent reads once at the start. One short paragraph per step; the tools' own descriptions hold the rest.
    static let instructions = """
        Mwoyeo translates text on the screen. Use these tools to make an app's names and terms come out the same on every line.
        1. list_apps: the apps in the translation log; its bundle IDs are the app argument of the other tools.
        2. read_translation_log: the newest lines of one app. For names you already suspect, term_renderings shows how each was translated, at a fraction of the size.
        3. set_memory (mode merge): write the app's names and a note for the translator. The glossary setting is for every app; one app's names go in its memory.
        4. translate_text: translate a few lines the way the lens does, with that memory, to check the fix.
        Results are compact JSON: values that never vary sit once in a header, and a row is an array named by columns.
        """

    // MARK: replies

    /// A tool's result: one text block of compact JSON, and no `structuredContent`. A client that reads the structured copy (Claude Code does,
    /// and then ignores the text) or the text (the others) gets the payload once; both would send it twice over the wire and, for a client
    /// that reads both, into the agent's context twice.
    private static func success(_ result: [String: Any]) -> [String: Any] {
        ["content": [["type": "text", "text": json(result)]]]
    }

    private static func failure(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    private static func firstText(of result: [String: Any]) -> String {
        ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    private static func faultReply(id: Any, _ fault: MCPFault) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": fault.code.rawValue, "message": fault.message]]
    }

    /// The reply as one line. Only values JSON can hold are put in a reply; a value that is not one is a bug and says so.
    static func encode(_ reply: [String: Any]) -> String {
        if JSONSerialization.isValidJSONObject(reply) { return json(reply) }
        return json(faultReply(id: reply["id"] ?? NSNull(), MCPFault(.internalError, "the reply held a value JSON cannot")))
    }

    /// Compact JSON with sorted keys; a string never holds a raw line break, so it is one line.
    static func json(_ object: Any) -> String {
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data ?? Data("{}".utf8), as: UTF8.self)
    }
}

// MARK: - what the server touches

/// The server's surroundings, so a check can point it at scratch files: where settings.json is, the preferences' copy of the settings
/// (where the folder bookmark lives, and the whole of the settings when there is no file yet), how an app's name is found and where the
/// engines' API keys are (the Keychain, as for the app).
struct MCPWorld {
    var settingsURL: URL
    var saved: () -> AppSettings
    /// The name of the app with this bundle ID, nil when none is installed.
    var appName: (String) -> String?
    var secrets: any SecretStore = KeychainSecrets()

    /// The real surroundings, the way the app itself sees them (`SettingsFileStore.defaultURL`, `AppModel`'s preferences).
    static func live() -> MCPWorld {
        #if MAS
        let defaults = UserDefaults.standard
        #else
        let defaults = ProcessInfo.processInfo.environment["MWOYEO_DEFAULTS_SUITE"].flatMap { UserDefaults(suiteName: $0) } ?? .standard
        #endif
        // The keys are where the app keeps them (`AppModel`): the Keychain, and in a check run memory only.
        #if MAS
        let secrets: any SecretStore = KeychainSecrets()
        #else
        let secrets: any SecretStore = ProcessInfo.processInfo.environment["MWOYEO_MEMORY_SECRETS"] != nil ? MemorySecrets() : KeychainSecrets()
        #endif
        return MCPWorld(settingsURL: SettingsFileStore.defaultURL,
                        saved: { defaults.data(forKey: "settings").flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? AppSettings() },
                        appName: installedName, secrets: secrets)
    }

    static func installedName(_ bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID), let bundle = Bundle(url: url) else { return nil }
        return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
    }

    /// The settings as the app reads them at launch, without writing anything: the file over the preferences' copy.
    func settings() -> AppSettings {
        let base = saved()
        guard let data = try? Data(contentsOf: settingsURL) else { return base }
        return SettingsFileCheck.read(data, over: base).settings
    }
}

// MARK: - the protocol

/// The methods the server answers. A request gets a reply; for a notification the reply is dropped, as the protocol has none.
enum MCPMethod: String {
    case initialize
    case initialized = "notifications/initialized"
    case cancelled = "notifications/cancelled"
    case ping
    case toolsList = "tools/list"
    case toolsCall = "tools/call"
}

/// A JSON-RPC error: its code and what the client is told.
struct MCPFault: Error {
    enum Code: Int {
        case parseError = -32700, invalidRequest = -32600, methodNotFound = -32601, invalidParams = -32602, internalError = -32603
    }

    let code: Code
    let message: String

    init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    var described: String { "rpc error \(code.rawValue): \(message)" }
}

/// A failure of a tool, which the client gets as a result with `isError` (the agent can read it and try again).
struct MCPToolError: Error {
    let message: String

    init(_ message: String) { self.message = message }
}

/// One line read as JSON-RPC: a request (it has an `id`) or a notification (it has none).
struct MCPMessage {
    var id: Any?
    var method: String
    var params: [String: Any]

    init(_ line: String) throws {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else {
            throw MCPFault(.parseError, "the line is not JSON")
        }
        guard let message = object as? [String: Any], message["method"] is String || message["result"] != nil || message["error"] != nil else {
            throw MCPFault(.invalidRequest, "expected one JSON-RPC message per line: an object with a method")
        }
        // A reply from the client has no method of ours to run; it is read as an unknown notification and gets no answer.
        method = message["method"] as? String ?? "(reply)"
        let id = message["id"]
        self.id = id is NSNull || message["method"] == nil ? nil : id
        params = message["params"] as? [String: Any] ?? [:]
    }

    /// What the trace shows: the method, and for a tool call the tool and the app it is about.
    var label: String {
        guard method == MCPMethod.toolsCall.rawValue, let name = params["name"] as? String else { return method }
        let app = (params["arguments"] as? [String: Any])?["app"] as? String
        return "\(method) \(name)" + (app.map { " app=\($0)" } ?? "")
    }
}
