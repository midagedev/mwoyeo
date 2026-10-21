import Foundation
import MwoyeoCore

/// The context state of everything the translator has served under context (design §2, §8), RAM only: per head of a chain a `ThreadStore`
/// (at most 8 threads, 5 min idle expiry), a `ContextMemory` (the user's note and entries as the chain has them now, plus the learned rows)
/// and a usage counter. The head is the key (names-and-context §2.1 rule 3, §8 P7): the first profile of the chain, or the app's bundle id
/// where All apps is first, as `MergedChain.learnedKey` says; two games in one emulator never share learned names, and an app's profile
/// (its id is its bundle id) keeps the book it always had. Screen text lives in the threads' transcripts and nowhere else; nothing here
/// logs or saves.
///
/// A plain value, mutated only by `TranslationService` (an actor), so there is no lock.
struct ContextBook {
    struct AppState {
        var threads = ThreadStore()
        var memory = ContextMemory()
        var usage = ContextUsage()
        /// The lines last seen on each thread's screen (for the wholesale-change test); kept for the threads that are kept.
        var screens: [ThreadKey: [String]] = [:]
    }

    /// What one call starts from, after the thread was found, resumed or started and its reset applied.
    struct Pass: Equatable {
        var key: ThreadKey
        /// The reset this call's signals asked for (a key change included), or nil.
        var reason: ResetReason?
        /// `ContextThread.namespaceFingerprint`: the "Start fresh" generation, the note, the user entries and the referents.
        var fingerprint: String
        /// The book this call's memory, threads and usage are in: the head of its chain (`MergedChain.learnedKey`), else the app.
        var book: String
    }

    private(set) var apps: [String: AppState] = [:]

    /// Told (with the app's bundle id) when the app's learned rows that a request may use changed: a row became usable, was
    /// dropped, or the user removed, forgot or pinned one. The app's learned-memory file and the Memory sheet follow it. Carries
    /// no row.
    var learnedChanged: (@Sendable (String) -> Void)?

    /// More lines than this on one screen are not compared (the test needs a share, not every line).
    static let screenCap = 400

    // MARK: a call

    /// One reading pass of a lens that has a profile and no window to match: the chain of that profile alone (or All apps', with none).
    /// What the checks of this book use; the request path knows its chain (`begin(_:chain:pair:engineID:now:)`).
    mutating func begin(_ lens: LensContext, profile: AppProfile?, pair: LanguagePair, engineID: String, now: TimeInterval) -> Pass {
        let links: [ChainLink] = profile.map { [.profile($0), .allApps] } ?? [.allApps]
        return begin(lens, chain: ProfileChain.merge(links, base: ChainBase(bundleID: lens.bundleID)), pair: pair, engineID: engineID, now: now)
    }

    /// One reading pass: makes the memory follow the chain, finds or starts the thread of this lens, applies the reset the
    /// signals ask for, and takes in the lines the lens sees right above the batch (the lens showed them: design §8.1).
    mutating func begin(_ lens: LensContext, chain: MergedChain, pair: LanguagePair, engineID: String, now: TimeInterval) -> Pass {
        let book = chain.learnedKey ?? lens.bundleID
        var app = apps[book] ?? AppState()
        let learnedBefore = app.memory.learnedPairs
        app.memory.follow(chain)
        // A name the user wrote (or pinned) for the chain takes the place of a learned row of the same source.
        defer { if app.memory.learnedPairs != learnedBefore { learnedChanged?(book) } }
        var signals = ThreadSignals(bundleID: lens.bundleID, confirmedTitle: lens.confirmedTitle, lensID: lens.lensID, pair: pair,
                                    engineID: engineID, idleSeconds: app.threads.current.map { max(0, now - $0.lastActive) } ?? 0)
        let screen = Array(lens.screen.prefix(Self.screenCap))
        signals.sharedLineRatio = ThreadSignals.sharedLineRatio(previous: app.screens[signals.key] ?? [], current: screen)
        let step = app.threads.step(signals, now: now)
        if let reason = step.reason { app.usage.noteReset(reason) }
        app.screens[step.key] = screen
        let kept = app.threads
        app.screens = app.screens.filter { kept.thread($0.key) != nil }
        app.threads.update(step.key) { thread in for line in lens.above { thread.append(source: line) } }
        let fingerprint = app.threads.thread(step.key).map { $0.namespaceFingerprint(memory: app.memory) } ?? ""
        apps[book] = app
        return Pass(key: step.key, reason: step.reason, fingerprint: fingerprint, book: book)
    }

    /// The request for `items` (one group of one call): the card, the note, the rows, the referents, the lines before (every
    /// kept line, minus the items; the layout takes the last N) and the lines after.
    func request(_ lens: LensContext, pass: Pass, items: [String], source: String?, target: String,
                 glossary: [(String, String)]) -> ContextRequest {
        let app = apps[pass.book]
        let thread = app?.threads.thread(pass.key)
        return ContextRequest(
            items: items,
            before: thread?.contextLines(count: ContextThread.maxLines, excluding: items) ?? [],
            after: lens.below,
            memory: app?.memory.rows ?? [],
            card: DocumentCard(appName: lens.appName, domain: lens.categoryWord, title: lens.confirmedTitle ?? ""),
            note: app?.memory.note ?? "",
            referents: thread?.referents ?? [],
            source: source, target: target, glossary: glossary, threadKey: pass.key.cacheKey, above: lens.above)
    }

    /// An engine call under context ended well: counts its usage, records the rows it used, and, only with `includeLearned`,
    /// lets the learning rule read the reply's `terms`.
    mutating func finish(_ lens: LensContext, pass: Pass, items: [String], reply: TranslationReply, used: [MemoryEntry], options: ContextOptions,
                         glossary: [(String, String)], now: Date = Date()) {
        guard var app = apps[pass.book] else { return }
        app.usage.add(reply.usage)
        let before = app.memory.learnedPairs
        // Memory only never learns, whatever else the options say (the layout does not ask for `terms` either).
        if options.includeLearned, !options.memoryOnly {
            let verdicts = app.memory.learn(reply.terms, items: items, reply: reply.lines, glossary: glossary, now: now)
            app.usage.noteSightings(verdicts.filter { if case .sighted = $0 { true } else { false } }.count)
        }
        app.memory.recordUse(of: used.map(\.src), now: now)
        let changed = app.memory.learnedPairs != before
        apps[pass.book] = app
        if changed { learnedChanged?(pass.book) }
    }

    /// The lines of a call are observed once it is over: the lines the lens showed, cache hits included (design §8.1), each with
    /// its translation when it has one. The translation of a line is shown to the engine only when the options trust it.
    mutating func observe(_ lens: LensContext, pass: Pass, lines: [(source: String, translation: String?)], now: TimeInterval) {
        apps[pass.book]?.threads.update(pass.key, now: now) { thread in
            for line in lines { thread.append(source: line.source, translation: line.translation, trusted: line.translation != nil) }
        }
    }

    // MARK: what the rest of the app reads and does (T3a-3, T3b)

    func usage(for bundleID: String) -> ContextUsage { apps[bundleID]?.usage ?? ContextUsage() }

    /// The learned rows, including those still waiting for a second sighting (`LearnedRecord.isUsable` tells them apart).
    func learned(for bundleID: String) -> [ContextMemory.LearnedRecord] { apps[bundleID]?.memory.learned ?? [] }

    /// "Start fresh" for the app's current thread: the transcript and the referents go, and the namespace generation moves on.
    mutating func startFresh(_ bundleID: String) { apps[bundleID]?.threads.startFresh() }

    mutating func forgetLearned(_ bundleID: String) {
        guard apps[bundleID]?.memory.learned.isEmpty == false else { return }
        apps[bundleID]?.memory.forgetLearned()
        learnedChanged?(bundleID)
    }

    /// The user removed one learned row ("Remove"), or pinned it (the profile has it now). No such row, no effect.
    mutating func removeLearned(src: String, for bundleID: String) {
        let key = ContextText.foldedKey(src)
        guard apps[bundleID]?.memory.learned.contains(where: { $0.entry.id == key }) == true else { return }
        apps[bundleID]?.memory.removeLearned(src: src)
        learnedChanged?(bundleID)
    }

    /// The referents of the app's current thread (`ContextThread.setReferents`); no thread yet, no effect.
    mutating func setReferents(_ list: [Referent], for bundleID: String) {
        guard let key = apps[bundleID]?.threads.currentKey else { return }
        apps[bundleID]?.threads.update(key) { $0.setReferents(list) }
    }
}

extension ContextMemory {
    /// The learned rows a request may use, as the learned-memory file holds them: (src, dst, kind, gender), no counts, no times.
    /// Two states with the same value here have the same file.
    var learnedPairs: [LearnedPair] { usableLearned.map { LearnedPair(src: $0.src, dst: $0.dst, kind: $0.kind, gender: $0.gender) } }

    struct LearnedPair: Equatable {
        var src: String
        var dst: String
        var kind: EntryKind
        var gender: Gender?
    }

    /// Makes the user's part match `chain` (its notes together and its merged names, as the user keeps them now); learned rows stay. A
    /// chain with nothing in it (All apps alone, no memory) empties the user's part. Entries that did not change keep their `uses`.
    mutating func follow(_ chain: MergedChain) {
        setNote(chain.note)
        let wanted = chain.rows.map(\.entry).filter { $0.origin == .user }
        let wantedIDs = Set(wanted.map(\.id))
        for entry in user where !wantedIDs.contains(entry.id) { removeUser(src: entry.src) }
        for entry in wanted {
            if var current = user.first(where: { $0.id == entry.id }) {
                current.uses = entry.uses
                current.lastSeen = entry.lastSeen
                if current == entry { continue }
            }
            addUser(entry)
        }
    }
}
