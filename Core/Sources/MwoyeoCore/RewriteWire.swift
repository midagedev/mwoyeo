import Foundation

// The wire between the app and the `MwoyeoScript` service (docs/design/rewrite-rules.md §5), on the pattern of `ReaderWire`: the app sends a
// `ScriptJob` (a small encoded value), the service runs it to completion in a fresh JavaScript global and answers with a `ScriptReply`.
// Pure types and codecs; the JavaScriptCore calls are in `Script/`, the transport and the time limit in `App/Script/ScriptConnection.swift`.

/// What a job asks (§3, §5).
public enum ScriptJobKind: String, Codable, Sendable {
    /// One regex row (flags `gu`, `$1` in the replacement) over `text`.
    case regex
    /// The script's `before(text, ctx)`.
    case before
    /// The script's `after(src, text, ctx)`.
    case after
    /// Check time (§2, §3): compile each pattern and parse the script, run nothing but the script's top level.
    case check
}

/// A pattern to compile at check time: `item` is its row's index in the profile's table.
public struct ScriptPattern: Codable, Equatable, Sendable {
    public var item: Int
    public var pattern: String

    public init(item: Int, pattern: String) {
        self.item = item; self.pattern = pattern
    }
}

/// One job. Which fields count depends on `kind`: `regex` reads `pattern`, `replacement` and `text`; `before` and `after` read `source`, `text`,
/// `src` and `context`; `check` reads `patterns` and `source`.
public struct ScriptJob: Codable, Equatable, Sendable {
    public var id: UInt64
    public var kind: ScriptJobKind
    /// The line (regex, before) or the engine's answer so far (after).
    public var text: String
    /// after: the line that was sent.
    public var src: String
    public var pattern: String
    public var replacement: String
    /// The script's source.
    public var source: String
    public var patterns: [ScriptPattern]
    public var context: RewriteContext

    public init(id: UInt64 = 0, kind: ScriptJobKind, text: String = "", src: String = "", pattern: String = "", replacement: String = "",
                source: String = "", patterns: [ScriptPattern] = [], context: RewriteContext = RewriteContext(target: "en")) {
        self.id = id; self.kind = kind; self.text = text; self.src = src; self.pattern = pattern; self.replacement = replacement
        self.source = source; self.patterns = patterns; self.context = context
    }
}

/// The answer to one job: the new `text`, or a `failure` (the text stays as it was); a check answers with `issues` and the functions the script defines.
public struct ScriptReply: Codable, Equatable, Sendable {
    public var id: UInt64
    public var pid: Int32
    public var text: String?
    public var failure: RewriteFailure?
    /// check: what is wrong, by `item` (a pattern's row index, or `RewriteIssue.script`).
    public var issues: [RewriteIssue]
    /// check: the stages whose function the script defines.
    public var defines: [RewriteStage]
    /// What the job took in the service.
    public var ms: Double

    public init(id: UInt64, pid: Int32, text: String? = nil, failure: RewriteFailure? = nil, issues: [RewriteIssue] = [],
                defines: [RewriteStage] = [], ms: Double = 0) {
        self.id = id; self.pid = pid; self.text = text; self.failure = failure; self.issues = issues; self.defines = defines; self.ms = ms
    }
}

/// The service's side of the connection. Every method answers through its reply, once. One job runs at a time, to completion; the app sends the
/// next only after the last has answered (`ScriptConnection` serialises its callers, so a job waiting behind a slow one is not timed from when it
/// was sent).
@objc public protocol ScriptXPC {
    /// `job` is an encoded `ScriptJob` (`ScriptWire.encode`); the reply is an encoded `ScriptReply`, also for a failure.
    func run(_ job: Data, reply: @escaping (Data) -> Void)
    /// Who is there and ready: the service has made its JavaScript machine and run one trivial call, so the first job is not charged for them. Replies with the pid.
    func hello(reply: @escaping (Int32) -> Void)
    /// Queues an exit behind the jobs already queued: replies with the pid, then exits.
    func exitWhenIdle(reply: @escaping (Int32) -> Void)
}

public enum ScriptWire {
    /// `<app id>.script`. Derived from the app's bundle id, so a re-identified copy talks to its own service (as `ReaderRole.serviceName`).
    public static func serviceName(appID: String) -> String { "\(appID).script" }

    public static func encode<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T { try JSONDecoder().decode(type, from: data) }

    public static func interface() -> NSXPCInterface { NSXPCInterface(with: ScriptXPC.self) }
}
