import Foundation

/// `MWOYEO_OCR_PATH` for the benches: `vn` never asks the document model (lines grouped by `ParagraphGrouper`, Docs never used),
/// `swift` assumes the document model ready for every key.
public enum PathOverride: String, Sendable, Equatable {
    case vn, swift
}

/// What one read wants, as the router needs it.
public struct RouteRequest: Equatable, Sendable {
    public enum Want: Equatable, Sendable {
        /// Paragraphs from the document model, or VN lines grouped by `ParagraphGrouper` when it is not available.
        case layout
        /// Lines (the plan's held reader is line grouping, or the caller groups).
        case lines
    }

    public var want: Want
    /// The language key (see `WorkerJob.key`).
    public var key: String
    /// The VN kinds that read every requested language, best first (`rev3`, `rev2`, `fast`): today's `OCRFallback.ladder` of the
    /// key. A kind is on it only if it reads *all* the languages, so Japanese has no `fast`.
    public var ladder: [ReadVia]
    public var path: PathOverride?

    public init(want: Want, key: String, ladder: [ReadVia], path: PathOverride? = nil) {
        self.want = want
        self.key = key
        self.ladder = ladder.filter { $0 != .doc }
        self.path = path
    }
}

/// Where a read goes and what its result stands for.
public struct ReadTarget: Equatable, Sendable {
    /// What a result of this target replaces; a recovery re-read gives it back once the better reader is ready again.
    public struct StandIn: OptionSet, Sendable, Equatable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// Lines grouped by `ParagraphGrouper` where the plan wanted the document layout (re-read on `readerReady(.docs)`).
        public static let layout = StandIn(rawValue: 1)
        /// `.fast` where the plan wanted accurate lines (re-read on `readerReady(.lines)`).
        public static let lines = StandIn(rawValue: 2)
    }

    public var role: WorkerRole
    public var via: ReadVia
    /// The paragraphs are `ParagraphGrouper` over this read's lines, not the document model's.
    public var grouped: Bool
    /// The worker the plan's first choice was, when this is not it (`reader.reroute.<from>.<to>`).
    public var reroutedFrom: WorkerRole?
    public var standIn: StandIn

    public init(role: WorkerRole, via: ReadVia, grouped: Bool = false, reroutedFrom: WorkerRole? = nil, standIn: StandIn = []) {
        self.role = role
        self.via = via
        self.grouped = grouped
        self.reroutedFrom = reroutedFrom
        self.standIn = standIn
    }
}

public enum ReadRoute: Equatable, Sendable {
    /// The worker takes it now.
    case dispatch(ReadTarget)
    /// The worker is busy within S: FIFO behind the request in flight.
    case queue(ReadTarget)
    /// No reader for this read now. The lens says so (`ReadWait`), and the pipeline re-runs on `readerReady`, not on a timer.
    case unavailable(RecognitionWait)

    public var target: ReadTarget? {
        switch self {
        case let .dispatch(t), let .queue(t): t
        case .unavailable: nil
        }
    }
}

/// Which reader reads (design §4.5). Pure: the health of both workers at `now` in, a route out. A reroute is nothing special: when a
/// worker turns `suspect`, ask again, and the answer no longer includes it.
public enum ReadRouter {
    /// The rules, in order. A rule that finds no usable worker passes to the next.
    ///
    /// Layout wanted:
    /// 1. Docs ready (or busy within S) and warm for the key → Docs/doc.
    /// 2. Otherwise the job becomes lines + `ParagraphGrouper` on the best healthy rung of Lines (rule 3 and 4 below). A rerouted
    ///    read never changes the plan's held reader: the lens keeps wanting the layout and gets it back on `readerReady(.docs)`.
    /// 5. Otherwise Docs/`.fast` (every language in `.fast`).
    ///
    /// Lines wanted:
    /// 3. Lines ready → Lines with the best healthy rung for the languages: rev3, or rev2 or `.fast` while rev3 rests.
    /// 4. Lines busy within S → queue behind it.
    /// 5. Lines not usable → Docs/doc if Docs is ready and warm for the key (a doc read gives lines too); else Docs/`.fast` if the
    ///    ladder has `.fast`; else unavailable: restart when Lines crash-looped, the disk when its compile keeps failing on a Mac
    ///    short of space (`WorkerHealth.lacksDiskSpace`), not responding when it is stuck (or stuck twice), preparing otherwise.
    ///
    /// 6. A kind never goes to a worker that is cold for it unless that worker is its home (`WorkerHealth.readiness`): rev3 never
    ///    goes to Docs, doc never to Lines. `.fast` never compiles and goes anywhere.
    /// 7. `path`: `vn` never uses Docs, `swift` assumes the document model warm.
    public static func route(_ request: RouteRequest, lines: WorkerHealth, docs: WorkerHealth, now: TimeInterval) -> ReadRoute {
        func health(_ role: WorkerRole) -> WorkerHealth { role == .lines ? lines : docs }
        let layout = request.want == .layout
        let usesDocs = request.path != .vn
        let wantedWorker: WorkerRole = layout && usesDocs ? .docs : .lines
        let ladderFirst = request.ladder.first

        func attempt(_ role: WorkerRole, _ via: ReadVia) -> ReadRoute? {
            let assumeWarm = request.path == .swift
            let readiness = health(role).readiness(for: via, key: request.key, now: now, assumeWarm: assumeWarm)
            guard readiness != .unusable else { return nil }
            var standIn: ReadTarget.StandIn = []
            if via != .doc, layout, usesDocs { standIn.insert(.layout) }
            if via == .fast, let ladderFirst, ladderFirst != .fast { standIn.insert(.lines) }
            let target = ReadTarget(role: role, via: via, grouped: layout && via != .doc,
                                    reroutedFrom: role == wantedWorker ? nil : wantedWorker, standIn: standIn)
            return readiness == .ready ? .dispatch(target) : .queue(target)
        }

        // Rule 6 is `readiness`: Docs is offered the whole ladder, and refuses rev3 and rev2 (cold there, not their home), so only
        // `.fast` is left of it. Lines is never offered doc.
        let onLines: [(WorkerRole, ReadVia)] = request.ladder.map { (.lines, $0) }
        let onDocs: [(WorkerRole, ReadVia)] = usesDocs ? [(.docs, .doc)] + request.ladder.map { (.docs, $0) } : []
        let candidates = layout ? onDocs.prefix(1) + onLines + onDocs.dropFirst() : onLines + onDocs
        for (role, via) in candidates {
            if let route = attempt(role, via) { return route }
        }
        return .unavailable(unavailableReason(lines: lines, now: now))
    }

    /// Why a lens that has no reader waits, from the worker that reads lines.
    public static func unavailableReason(lines: WorkerHealth, now: TimeInterval) -> RecognitionWait {
        switch (lines.lacksDiskSpace, lines.effectiveState(now: now)) {
        case (_, .disabled(.crashLoop)): .restartApp
        case (true, _): .needsDiskSpace
        case (_, .stuck), (_, .disabled(.stuckTwice)): .notResponding
        default: .preparing
        }
    }
}

/// Who waits for what, per worker (design §4.6). Pure bookkeeping for the host actor.
///
/// - One request in flight per worker (`next` hands out nothing until `complete`), FIFO, at most one *queued* job per client:
///   a newer job from the same client supersedes the queued one.
/// - Priority: lens > image window > warm-up. A warm-up goes only to an idle worker with an empty queue (`slotIsFree`).
/// - Late results: per client the first result for the newest frame wins and a later one is dropped (`complete`). A rerouted job's
///   original request runs on; its answer updates health in the owner and is dropped here (or wins, if it comes first).
/// - Recovery re-read: `readerReady(role)` returns the clients whose last accepted read was a stand-in for that worker, once.
public struct ReadScheduler: Sendable, Equatable {
    public struct Job: Equatable, Sendable {
        public var id: Int
        public var client: Int
        public var purpose: WorkerJob.Purpose
        /// The frame (or request) number of the client; newer is larger.
        public var frame: Int
        public var target: ReadTarget
        public var key: String
        public var queuedAt: TimeInterval

        public var workerJob: WorkerJob { WorkerJob(via: target.via, key: key, purpose: purpose) }
    }

    public enum DropReason: String, Sendable, Equatable {
        /// A newer frame of the client was submitted since.
        case stale
        /// The client already has a result for this frame (the original of a reroute, or its stand-in, came second): `reader.dropped.rerouted`.
        case rerouted
    }

    public enum Delivery: Equatable, Sendable {
        /// Use this result.
        case accept
        case drop(DropReason)
        /// A warm-up has no client; only health cares.
        case warmup
    }

    public struct Submission: Equatable, Sendable {
        public var job: Job
        /// The client's queued job this one replaced; it ends `.superseded` at once.
        public var superseded: Job?
    }

    private var nextID = 1
    private var queues: [WorkerRole: [Job]] = [:]
    private var inflight: [WorkerRole: Job] = [:]
    private var newestFrame: [Int: Int] = [:]
    private var answeredFrame: [Int: Int] = [:]
    private var standIns: [Int: ReadTarget.StandIn] = [:]
    public private(set) var dropped: [DropReason: Int] = [:]

    public init() {}

    public func queued(_ role: WorkerRole) -> [Job] { queues[role] ?? [] }
    public func inFlight(_ role: WorkerRole) -> Job? { inflight[role] }

    /// Nothing in flight and nothing queued: the slot a warm-up may take.
    public func slotIsFree(_ role: WorkerRole) -> Bool { inflight[role] == nil && (queues[role] ?? []).isEmpty }

    /// Queues a read. At most one queued job per client: the older one is returned as superseded.
    public mutating func submit(client: Int, purpose: WorkerJob.Purpose, frame: Int, key: String, target: ReadTarget,
                                now: TimeInterval) -> Submission {
        var superseded: Job?
        for role in WorkerRole.allCases {
            if let i = queues[role]?.firstIndex(where: { $0.client == client }) { superseded = queues[role]?.remove(at: i) }
        }
        newestFrame[client] = max(newestFrame[client] ?? frame, frame)
        let job = Job(id: nextID, client: client, purpose: purpose, frame: frame, target: target, key: key, queuedAt: now)
        nextID += 1
        queues[target.role, default: []].append(job)
        return Submission(job: job, superseded: superseded)
    }

    /// The job the worker takes next: nil while one is in flight, else the highest priority, oldest first.
    public mutating func next(_ role: WorkerRole) -> Job? {
        guard inflight[role] == nil, let queue = queues[role], !queue.isEmpty else { return nil }
        let best = queue.indices.min { a, b in
            queue[a].purpose != queue[b].purpose ? queue[a].purpose < queue[b].purpose : a < b
        }!
        let job = queues[role]!.remove(at: best)
        inflight[role] = job
        return job
    }

    /// A warm-up starts on the worker (it never queues). False when the slot is not free.
    public mutating func beginWarmup(client: Int, role: WorkerRole, via: ReadVia, key: String, now: TimeInterval) -> Job? {
        guard slotIsFree(role) else { return nil }
        let job = Job(id: nextID, client: client, purpose: .warmup, frame: 0,
                      target: ReadTarget(role: role, via: via), key: key, queuedAt: now)
        nextID += 1
        inflight[role] = job
        return job
    }

    /// The worker went suspect: every lens and image job queued there, and the one in flight, are handed back to be routed again
    /// (submit them with their old frame). The one in flight keeps running; its answer is a late result.
    public mutating func reroute(_ role: WorkerRole) -> [Job] {
        var out = (queues[role] ?? []).filter { $0.purpose != .warmup }
        queues[role] = (queues[role] ?? []).filter { $0.purpose == .warmup }
        if let job = inflight[role], job.purpose != .warmup { out.insert(job, at: 0) }
        return out
    }

    /// The worker returned job `id` (any outcome). Frees the slot and says what to do with the result.
    public mutating func complete(_ role: WorkerRole, id: Int) -> Delivery {
        guard let job = inflight[role], job.id == id else { return drop(.stale) }
        inflight[role] = nil
        if job.purpose == .warmup { return .warmup }
        if job.frame < (newestFrame[job.client] ?? job.frame) { return drop(.stale) }
        if answeredFrame[job.client] == job.frame { return drop(.rerouted) }
        answeredFrame[job.client] = job.frame
        standIns[job.client] = job.target.standIn.isEmpty ? nil : job.target.standIn
        // A copy of this frame still waiting in a queue (the reroute's) would read what is already answered.
        for r in WorkerRole.allCases { queues[r]?.removeAll { $0.client == job.client && $0.frame <= job.frame } }
        return .accept
    }

    /// The process died with the request in flight (a crash or a recycle): the job is lost. Returns it, nil if none.
    public mutating func lost(_ role: WorkerRole) -> Job? {
        guard let job = inflight[role] else { return nil }
        inflight[role] = nil
        return job
    }

    /// `readerReady(role)`: the clients whose last accepted read stood in for this worker's. Each is returned once (read it again);
    /// a client that has read normally since is not in the list.
    public mutating func readerReady(_ role: WorkerRole) -> [Int] {
        let flag: ReadTarget.StandIn = role == .docs ? .layout : .lines
        let clients = standIns.filter { $0.value.contains(flag) }.keys.sorted()
        for c in clients {
            let rest = standIns[c]!.subtracting(flag)
            standIns[c] = rest.isEmpty ? nil : rest
        }
        return clients
    }

    /// A client is gone (a lens closed): its queued job, its frame record and its stand-in flag go.
    public mutating func forget(client: Int) {
        for role in WorkerRole.allCases { queues[role]?.removeAll { $0.client == client } }
        newestFrame[client] = nil
        answeredFrame[client] = nil
        standIns[client] = nil
    }

    private mutating func drop(_ why: DropReason) -> Delivery {
        dropped[why, default: 0] += 1
        return .drop(why)
    }
}
