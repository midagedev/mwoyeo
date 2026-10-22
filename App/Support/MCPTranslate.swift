import Foundation
import MwoyeoCore
import MwoyeoEngines

/// `translate_text`: a few lines through the very `TranslationService` a lens uses (`SelfTest`'s `--render` builds the same), under the
/// settings in effect for a window (an app and its title) or for a profile picked by hand (design names-and-context §1.3, §7: its chain,
/// narrowest profile first, then All apps, decides the languages, the engine and the memory) and with that memory as a lens over the window
/// would send it (`LensContext`; `ContextPlan` decides what reaches which engine). An agent that has written a memory checks it here.
///
/// A fresh service per call: its cache is keyed by the glossary but not by an app's memory, so a service kept between calls would answer
/// the line an agent asked about before it wrote the memory from its cache.
enum MCPTranslate {
    static let maxLines = 20
    static let maxLineLength = 2000

    static func run(_ a: [String: Any], _ world: MCPWorld) throws -> [String: Any] {
        let lines = a["lines"] as? [String] ?? []
        if lines.isEmpty { throw MCPToolError("translate_text was not run: lines holds no line") }
        let done = try translate(lines, a, world)
        return ["columns": ["translation", "engine"], "rows": done.rows].merging(done.extra) { first, _ in first }
    }

    /// The translation of `lines` the way a lens over the window `a` names (`app`, `title`, `profile`, `engine`) does it: a row `[translation, engine]` for each
    /// line, and what else the answer says (the profile that decided, whether its memory was used, the service's issue). `test_rules` asks the same for the
    /// lines `before` left, with `withRewrites` off: it applies the rewrites itself, so the service must not apply them a second time.
    /// The request path is `TextTranslation`'s (the Translate Text window is its other caller); the words of a refusal are this tool's.
    static func translate(_ lines: [String], _ a: [String: Any], _ world: MCPWorld, tool: String = "translate_text",
                          withRewrites: Bool = true) throws -> (rows: [[Any]], extra: [String: Any]) {
        let request = TextTranslation.Request(app: a["app"] as? String, title: a["title"] as? String, profile: a["profile"] as? String, engine: a["engine"] as? String)
        let resolved: TextTranslation.Resolved
        do {
            resolved = try TextTranslation.resolve(request, base: world.settings(), asker: .agent, secrets: world.secrets, withRewrites: withRewrites)
        } catch let refusal as TextTranslation.Refusal {
            throw MCPToolError(words(refusal, tool: tool))
        }
        let answer = MCPAsync.wait { await TextTranslation.run(lines, resolved, secrets: world.secrets) }
        guard answer.translated else {
            throw MCPToolError("\(tool) could not translate: " + (answer.issue?.message ?? "no engine answered"))
        }
        let rows = answer.rows.map { [$0.translation ?? NSNull(), $0.engine ?? NSNull()] as [Any] }
        var result: [String: Any] = [:]
        if let profile = answer.profile { result["profile"] = profile }
        if let memory = answer.memory { result["memory"] = memory }
        if let issue = answer.issue { result["issue"] = issue.message }
        return (rows, result)
    }

    /// `engine`: "apple", or the id of an added engine.
    static func choose(_ choice: String, in settings: inout AppSettings) throws {
        do { try TextTranslation.choose(choice, in: &settings) } catch let refusal as TextTranslation.Refusal {
            throw MCPToolError(words(refusal, tool: "translate_text"))
        }
    }

    private static func words(_ refusal: TextTranslation.Refusal, tool: String) -> String {
        switch refusal {
        case let .noSuchProfile(id):
            "\(tool) was not run: profile: no profile has the id \(id); list_apps lists them"
        case let .noSuchEngine(choice, known):
            "translate_text was not run: engine: \"\(choice)\" is not an engine; use one of \(known.joined(separator: ", "))"
        case .commandEngine:
            "\(tool) does not run command engines (programs of the person's own); name apple or another engine"
        case let .keyUnreachable(engine, reason):
            "\(tool) cannot use \(engine): its API key is in the Keychain and this process cannot read it (\(reason)). Use apple, or ask the person to translate with it in Mwoyeo"
        }
    }
}

// MARK: - async work from the synchronous loop

/// The server reads and answers one line at a time on the main thread. A tool that has to await (the translation service is an actor)
/// runs its work on the cooperative pool, and the main run loop keeps turning while the loop waits, so whatever the work needs from the
/// run loop (the system's services answer on it) still happens, as in `--render`. It polls for the end: the main queue may be busy with
/// the very job that waits (a check run inside the app), so a wake-up through it could never come.
enum MCPAsync {
    private final class Box<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T?
        func put(_ value: T) { lock.withLock { stored = value } }
        var value: T? { lock.withLock { stored } }
    }

    static func wait<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
        let box = Box<T>()
        Task.detached { box.put(await work()) }
        while true {
            if let done = box.value { return done }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }
}
