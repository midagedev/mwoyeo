import Foundation

/// Every duration the reader host uses, in one struct (g2-fast-host-gates, 2026-10-19). `.standard` is what ships: its numbers are
/// the ones the policy types already own (`ReadVia.patience`, `WorkerHealth`'s limits, `Backoff.Use`, `OCRHealth.coldWait`), read
/// here and not copied. A gate that wants a worker that is slow, restarting or resting does not wait for the real numbers: a unit
/// test passes a `ReaderTiming` to `ReaderHostCore` and drives a fake clock, and the one shell smoke runs the real services with
/// scaled-down numbers (`MWOYEO_READER_TIMING`, non-MAS builds only, parsed by `applying(_:)`).
///
/// The delay a fake service adds to a job is not here: it is the argument of `MWOYEO_FAKE_READER=docs-slow:<ms>` (`ReaderFakePlan`).
public struct ReaderTiming: Sendable, Equatable {
    /// S(kind): how long a pass waits for a request of this kind before it is routed again without it (`ReadVia.patience`).
    public var patience: [ReadVia: TimeInterval]
    /// A lens or image request this old is stuck, a warm-up this old is overdue, an idle worker this old exits (`WorkerHealth`).
    public var stuckAfter: TimeInterval
    public var warmingBound: TimeInterval
    public var idleExitAfter: TimeInterval
    /// The windows of the Code-13 streak, the recycles and the crashes (`WorkerHealth`).
    public var code13Span: TimeInterval
    public var recycleWindow: TimeInterval
    public var crashWindow: TimeInterval
    /// A worker's restart after a crash or a recycle (`Backoff.workerRestart`).
    public var restart: Backoff
    /// The rev3 rung's rest after Code 13, and the warm-up's wait before it asks again (`Backoff.rev3Rung`).
    public var rung: Backoff
    /// Docs' rest after consecutive answers past S (`DocsRest`).
    public var docsRest: Backoff
    /// How long a warm-up waits for a busy worker, and keeps asking while the programs are not ready (`OCRHealth.coldWait`).
    public var coldWait: TimeInterval
    /// How often a warm-up looks at a worker that is busy or restarting.
    public var warmPoll: TimeInterval
    /// `MWOYEO_DOCS_WAIT=1`, the mutation of the silence gates: a layout read waits for Docs however long, as the in-process path
    /// did. A gate that does not fail under it measures nothing. How often the waiting read looks again: `docsWaitPoll`.
    public var waitsForDocs: Bool
    public var docsWaitPoll: TimeInterval

    public init(patience: [ReadVia: TimeInterval], stuckAfter: TimeInterval, warmingBound: TimeInterval, idleExitAfter: TimeInterval,
                code13Span: TimeInterval, recycleWindow: TimeInterval, crashWindow: TimeInterval, restart: Backoff, rung: Backoff,
                docsRest: Backoff, coldWait: TimeInterval, warmPoll: TimeInterval, waitsForDocs: Bool, docsWaitPoll: TimeInterval) {
        self.patience = patience
        self.stuckAfter = stuckAfter
        self.warmingBound = warmingBound
        self.idleExitAfter = idleExitAfter
        self.code13Span = code13Span
        self.recycleWindow = recycleWindow
        self.crashWindow = crashWindow
        self.restart = restart
        self.rung = rung
        self.docsRest = docsRest
        self.coldWait = coldWait
        self.warmPoll = warmPoll
        self.waitsForDocs = waitsForDocs
        self.docsWaitPoll = docsWaitPoll
    }

    /// The numbers the app ships with.
    public static let standard = ReaderTiming(
        patience: Dictionary(uniqueKeysWithValues: ReadVia.allCases.map { ($0, $0.patience) }),
        stuckAfter: WorkerHealth.stuckAfter, warmingBound: WorkerHealth.warmingBound, idleExitAfter: WorkerHealth.idleExitAfter,
        code13Span: WorkerHealth.code13Span, recycleWindow: WorkerHealth.recycleWindow, crashWindow: WorkerHealth.crashWindow,
        restart: .workerRestart, rung: .rev3Rung, docsRest: .rev3Rung, coldWait: OCRHealth.coldWait, warmPoll: 0.2,
        waitsForDocs: false, docsWaitPoll: 0.1)

    public func patience(_ via: ReadVia) -> TimeInterval { patience[via] ?? via.patience }

    // MARK: MWOYEO_READER_TIMING

    /// The names the spec knows, for the message that names a typo.
    public static let names = ["doc", "rev3", "rev2", "fast", "stuck", "warming", "idle", "restart", "rung", "docsrest", "cold", "poll",
                               "docs-wait"]

    /// `name=<value>[,name=<value>…]` on top of these numbers, and the entries it did not understand (a typo would otherwise change
    /// nothing, silently). Seconds: `doc` `rev3` `rev2` `fast` (S of the kind), `stuck` `warming` `idle`, `cold`, `poll`.
    /// `restart` `rung` `docsrest` take `<base>/<cap>` (the doubling and the healthy window stay). `docs-wait=1` is the mutation.
    public func applying(_ spec: String?) -> (timing: ReaderTiming, unrecognized: [String]) {
        var out = self
        var unknown: [String] = []
        for raw in (spec ?? "").split(separator: ",") {
            let entry = raw.trimmingCharacters(in: .whitespaces)
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { unknown.append(entry); continue }
            let name = parts[0], value = parts[1]
            func seconds() -> TimeInterval? { Double(value).flatMap { $0 > 0 && $0.isFinite ? $0 : nil } }
            func backoff(_ old: Backoff) -> Backoff? {
                let ends = value.split(separator: "/").compactMap { Double($0) }
                guard ends.count == 2, ends[0] > 0, ends[1] >= ends[0], ends.allSatisfy(\.isFinite) else { return nil }
                return Backoff(base: ends[0], factor: old.factor, cap: ends[1], healthyWindow: old.healthyWindow)
            }
            switch name {
            case "doc", "rev3", "rev2", "fast":
                guard let s = seconds(), let via = ReadVia(rawValue: name) else { unknown.append(entry); continue }
                out.patience[via] = s
            case "stuck": if let s = seconds() { out.stuckAfter = s } else { unknown.append(entry) }
            case "warming": if let s = seconds() { out.warmingBound = s } else { unknown.append(entry) }
            case "idle": if let s = seconds() { out.idleExitAfter = s } else { unknown.append(entry) }
            case "cold": if let s = seconds() { out.coldWait = s } else { unknown.append(entry) }
            case "poll": if let s = seconds() { out.warmPoll = s } else { unknown.append(entry) }
            case "restart": if let b = backoff(out.restart) { out.restart = b } else { unknown.append(entry) }
            case "rung": if let b = backoff(out.rung) { out.rung = b } else { unknown.append(entry) }
            case "docsrest": if let b = backoff(out.docsRest) { out.docsRest = b } else { unknown.append(entry) }
            case "docs-wait": out.waitsForDocs = value != "0"
            default: unknown.append(entry)
            }
        }
        return (out, unknown)
    }
}
