import Foundation
import Testing
@testable import MwoyeoCore

/// What a test needs of a worker's state.
enum Named: CaseIterable {
    case cold, idle, busy, suspect, warming, stuck, restarting, crashLoop, stuckTwice
}

/// A worker whose state at `now` is `named`. `warm`: kinds that answered for a key before.
func makeHealth(_ role: WorkerRole, _ named: Named, warm: [WarmKey] = [], busyVia: ReadVia = .doc, key: String = "en",
                now: TimeInterval = 1000) -> WorkerHealth {
    var h = WorkerHealth(role: role)
    var t = now - 900
    for w in warm {
        h.dispatch(WorkerJob(via: w.via, key: w.key, purpose: .warmup), now: t)
        t += 1
        h.reply(.answered, now: t)
        t += 1
    }
    let job = WorkerJob(via: busyVia, key: key, purpose: .lens)
    switch named {
    case .cold: break
    case .idle: break
    case .busy: h.dispatch(job, now: now - 0.5)
    case .suspect:
        h.dispatch(job, now: now - 10)
        h.tick(now: now)
    case .warming:
        h.dispatch(WorkerJob(via: busyVia, key: key, purpose: .warmup), now: now - 10)
    case .stuck:
        h.dispatch(job, now: now - 300)
        h.tick(now: now)
    case .restarting:
        h.dispatch(job, now: now - 1)
        h.interrupted(now: now)
    case .crashLoop:
        for n in 0..<5 {
            h.dispatch(job, now: now - 50 + Double(n) * 10)
            h.interrupted(now: now - 49 + Double(n) * 10)
            h.tick(now: now - 40 + Double(n) * 10)
        }
    case .stuckTwice:
        h.dispatch(job, now: now - 700)
        h.tick(now: now - 460)
        h.interrupted(now: now - 459)
        h.tick(now: now - 450)
        h.dispatch(job, now: now - 449)
        h.tick(now: now)
    }
    return h
}

/// R2 reader-core (2026-10-18, design §4.5 and §4.6): the router's seven rules and the scheduler's bookkeeping.
@Suite struct ReadRouterTests {
    typealias T = ReadTarget
    private let now: TimeInterval = 1000
    private let layoutEN = RouteRequest(want: .layout, key: "en", ladder: [.rev3, .rev2, .fast])
    private let linesEN = RouteRequest(want: .lines, key: "en", ladder: [.rev3, .rev2, .fast])
    /// Japanese: rev3 and rev2 read it, `.fast` does not (Latin only).
    private let linesJA = RouteRequest(want: .lines, key: "ja", ladder: [.rev3, .rev2])
    private let docEN = WarmKey(.doc, "en"), rev3EN = WarmKey(.rev3, "en")

    private func route(_ r: RouteRequest, lines: WorkerHealth, docs: WorkerHealth) -> ReadRoute {
        ReadRouter.route(r, lines: lines, docs: docs, now: now)
    }

    // MARK: layout wanted

    @Test func layoutGoesToWarmIdleDocs() {
        let lines = makeHealth(.lines, .idle, warm: [rev3EN]), docs = makeHealth(.docs, .idle, warm: [docEN])
        #expect(route(layoutEN, lines: lines, docs: docs) == .dispatch(T(role: .docs, via: .doc)))
    }

    @Test func layoutQueuesBehindBusyDocsWithinS() {
        let lines = makeHealth(.lines, .idle, warm: [rev3EN]), docs = makeHealth(.docs, .busy, warm: [docEN])
        #expect(route(layoutEN, lines: lines, docs: docs) == .queue(T(role: .docs, via: .doc)))
    }

    @Test func testDocsSuspectRoutesToLines() {
        // Today (G3/G4, `TextRecognizer.swift:162, :293-336`): a document read waits 8 s in the blocked process, then VN tries
        // there too, rung after rung, each blocked behind the same compile (`ocr-stall-112`: 106 s silent). Here Docs is another
        // process: the moment it is suspect the layout read is lines + `ParagraphGrouper` on Lines, which answers in 0.3-1.5 s.
        let lines = makeHealth(.lines, .idle, warm: [rev3EN])
        let viaLines = ReadRoute.dispatch(T(role: .lines, via: .rev3, grouped: true, reroutedFrom: .docs, standIn: .layout))
        for named in [Named.suspect, .warming, .stuck, .restarting, .crashLoop, .stuckTwice] {
            let docs = makeHealth(.docs, named, warm: [docEN])
            #expect(route(layoutEN, lines: lines, docs: docs) == viaLines, "\(named)")
        }
        // Cold for the key (rule 2): a doc read of a new key compiles ~130 s, so it is not asked.
        #expect(route(layoutEN, lines: lines, docs: makeHealth(.docs, .idle)) == viaLines)
        #expect(route(layoutEN, lines: lines, docs: makeHealth(.docs, .cold)) == viaLines)
        // Another key warm is not this key.
        #expect(route(layoutEN, lines: lines, docs: makeHealth(.docs, .idle, warm: [WarmKey(.doc, "ja")])) == viaLines)
    }

    @Test func aRerouteToLinesUsesTheBestHealthyRung() {
        let docs = makeHealth(.docs, .suspect, warm: [docEN])
        var lines = makeHealth(.lines, .idle, warm: [rev3EN])
        lines.dispatch(WorkerJob(via: .rev3, key: "en"), now: now - 20)
        lines.reply(.notReady, now: now - 0.4)                       // rev3 rests for 1 s
        #expect(lines.isResting(.rev3, now: now))
        #expect(route(layoutEN, lines: lines, docs: docs)
                == .dispatch(T(role: .lines, via: .rev2, grouped: true, reroutedFrom: .docs, standIn: .layout)))
        let fastOnly = RouteRequest(want: .layout, key: "en", ladder: [.rev3, .fast])
        #expect(route(fastOnly, lines: lines, docs: docs)
                == .dispatch(T(role: .lines, via: .fast, grouped: true, reroutedFrom: .docs, standIn: [.layout, .lines])))
    }

    // MARK: lines wanted

    @Test func linesWantedGoesToLinesWithRev3() {
        let lines = makeHealth(.lines, .idle, warm: [rev3EN]), docs = makeHealth(.docs, .idle, warm: [docEN])
        #expect(route(linesEN, lines: lines, docs: docs) == .dispatch(T(role: .lines, via: .rev3)))
        // cold for the key at its home: the lens's own read is the compile (rule 6's exception)
        #expect(route(linesJA, lines: makeHealth(.lines, .cold), docs: docs) == .dispatch(T(role: .lines, via: .rev3)))
    }

    @Test func linesQueueBehindBusyLinesWithinS() {
        let lines = makeHealth(.lines, .busy, warm: [rev3EN], busyVia: .rev3)
        #expect(route(linesEN, lines: lines, docs: makeHealth(.docs, .idle)) == .queue(T(role: .lines, via: .rev3)))
    }

    @Test func testLinesWarmingLatinGoesToDocsFast() {
        // The p13 fresh-id gate (design §7, expected ~1-2 s): Lines compiles rev3 for 64-96 s; a Latin lens reads `.fast` in the
        // Docs worker meanwhile. Today the same read waits 8 s per rung in the blocked process.
        let lines = makeHealth(.lines, .warming, busyVia: .rev3)
        let docs = makeHealth(.docs, .idle)                         // cold for the doc networks: not asked
        let expected = ReadRoute.dispatch(T(role: .docs, via: .fast, reroutedFrom: .lines, standIn: .lines))
        #expect(route(linesEN, lines: lines, docs: docs) == expected)
        #expect(route(linesEN, lines: lines, docs: makeHealth(.docs, .cold)) == expected)
        // The layout version of the same read keeps the layout's stand-in too and the grouper.
        #expect(route(layoutEN, lines: lines, docs: makeHealth(.docs, .idle))
                == .dispatch(T(role: .docs, via: .fast, grouped: true, standIn: [.layout, .lines])))
        // Docs warm for the key reads the document instead (a doc read gives lines too).
        #expect(route(linesEN, lines: lines, docs: makeHealth(.docs, .idle, warm: [docEN]))
                == .dispatch(T(role: .docs, via: .doc, reroutedFrom: .lines)))
    }

    @Test func testLinesWarmingJapaneseIsPreparing() {
        // Japanese has no `.fast`, and rev3 is the only recognizer that is ready for it: nothing reads it until Lines is warm, and the
        // lens says so at once (today nothing raises the hint for a doc read, and a VN read raises it only after 8 s on its last rung).
        let lines = makeHealth(.lines, .warming, busyVia: .rev3, key: "ja")
        #expect(route(linesJA, lines: lines, docs: makeHealth(.docs, .idle)) == .unavailable(.preparing))
        #expect(route(linesJA, lines: lines, docs: makeHealth(.docs, .cold)) == .unavailable(.preparing))
        let layoutJA = RouteRequest(want: .layout, key: "ja", ladder: [.rev3, .rev2])
        #expect(route(layoutJA, lines: lines, docs: makeHealth(.docs, .idle)) == .unavailable(.preparing))
        // Docs warm for "ja" would read it.
        #expect(route(linesJA, lines: lines, docs: makeHealth(.docs, .idle, warm: [WarmKey(.doc, "ja")]))
                == .dispatch(T(role: .docs, via: .doc, reroutedFrom: .lines)))
    }

    @Test func linesSuspectBehavesLikeWarming() {
        let lines = makeHealth(.lines, .suspect, busyVia: .rev3)
        #expect(route(linesJA, lines: lines, docs: makeHealth(.docs, .idle)) == .unavailable(.preparing))
        #expect(route(linesEN, lines: lines, docs: makeHealth(.docs, .idle))
                == .dispatch(T(role: .docs, via: .fast, reroutedFrom: .lines, standIn: .lines)))
    }

    @Test func rev3RestingFallsDownTheLadderAndEndsWhenItEnds() {
        var lines = makeHealth(.lines, .idle, warm: [rev3EN])
        lines.dispatch(WorkerJob(via: .rev3, key: "en"), now: now - 20)
        lines.reply(.notReady, now: now - 0.4)
        let docs = makeHealth(.docs, .idle)
        #expect(route(linesEN, lines: lines, docs: docs) == .dispatch(T(role: .lines, via: .rev2)))
        let noRev2 = RouteRequest(want: .lines, key: "en", ladder: [.rev3, .fast])
        #expect(route(noRev2, lines: lines, docs: docs) == .dispatch(T(role: .lines, via: .fast, standIn: .lines)))
        // Only rev3 reads these languages: Docs cannot, so the lens waits for the rung.
        let rev3Only = RouteRequest(want: .lines, key: "ja", ladder: [.rev3])
        #expect(route(rev3Only, lines: lines, docs: docs) == .unavailable(.preparing))
        #expect(ReadRouter.route(rev3Only, lines: lines, docs: docs, now: now + 0.7) == .dispatch(T(role: .lines, via: .rev3)))
    }

    @Test func theReasonALensHasNoReaderComesFromLines() {
        let docs = makeHealth(.docs, .suspect)
        let cases: [(Named, RecognitionWait)] = [
            (.warming, .preparing), (.suspect, .preparing), (.restarting, .preparing),
            (.stuck, .notResponding), (.stuckTwice, .notResponding), (.crashLoop, .restartApp),
        ]
        for (named, why) in cases {
            let lines = makeHealth(.lines, named, busyVia: .rev3, key: "ja")
            #expect(route(linesJA, lines: lines, docs: docs) == .unavailable(why), "\(named)")
        }
    }

    // MARK: rule 6, as an invariant over every state

    @Test func testNeverSendsRev3ToDocs() {
        // Today's `OCRFallback` ladder is walked by whoever holds the request, in whichever process it is: a rev3 read of a new
        // key in the Docs cache is a second cold compile (design F3). Whatever the state of the two workers, rev3 and rev2 never
        // go to Docs, the doc kind never goes to Lines, and a doc read goes only where it is warm.
        let keys = ["en", "ja"]
        let ladders: [[ReadVia]] = [[.rev3, .rev2, .fast], [.rev3, .rev2], [.rev3, .fast], [.rev3], [.rev2, .fast], [.fast]]
        var checked = 0
        for l in Named.allCases {
            for d in Named.allCases {
                for docWarm in [true, false] {
                    for key in keys {
                        let lines = makeHealth(.lines, l, warm: [WarmKey(.rev3, key)], busyVia: .rev3, key: key)
                        let docs = makeHealth(.docs, d, warm: docWarm ? [WarmKey(.doc, key)] : [], busyVia: .doc, key: key)
                        for ladder in ladders {
                            for want in [RouteRequest.Want.layout, .lines] {
                                for path in [nil, PathOverride.vn] {
                                    let r = RouteRequest(want: want, key: key, ladder: ladder, path: path)
                                    guard let t = ReadRouter.route(r, lines: lines, docs: docs, now: now).target else { continue }
                                    checked += 1
                                    #expect(!(t.role == .docs && (t.via == .rev3 || t.via == .rev2)), "\(l) \(d) \(ladder) \(want)")
                                    #expect(!(t.role == .lines && t.via == .doc), "\(l) \(d) \(ladder) \(want)")
                                    if t.via == .doc { #expect(docWarm && path == nil, "doc read of a cold key: \(l) \(d)") }
                                    if path == .vn { #expect(t.role == .lines, "vn never uses Docs") }
                                    if t.role == .lines, t.via != .fast { #expect(ladder.contains(t.via)) }
                                }
                            }
                        }
                    }
                }
            }
        }
        #expect(checked > 1000)
    }

    // MARK: rule 7

    @Test func theBenchOverridesVnAndSwift() {
        let lines = makeHealth(.lines, .idle, warm: [rev3EN]), docs = makeHealth(.docs, .idle, warm: [docEN])
        // vn: lines grouped by the grouper, Docs never; the grouper is the plan, not a reroute.
        var vn = layoutEN
        vn.path = .vn
        #expect(route(vn, lines: lines, docs: docs) == .dispatch(T(role: .lines, via: .rev3, grouped: true)))
        #expect(route(vn, lines: makeHealth(.lines, .warming, busyVia: .rev3), docs: docs) == .unavailable(.preparing))
        // swift: the document model is assumed warm for every key.
        var swift = layoutEN
        swift.path = .swift
        #expect(route(swift, lines: lines, docs: makeHealth(.docs, .idle)) == .dispatch(T(role: .docs, via: .doc)))
        #expect(route(swift, lines: lines, docs: makeHealth(.docs, .suspect))
                == .dispatch(T(role: .lines, via: .rev3, grouped: true, reroutedFrom: .docs, standIn: .layout)))
    }
}

/// R2 reader-core (2026-10-18, design §4.6 and §10.4): who waits for what, which result wins, who reads again.
@Suite struct ReadSchedulerTests {
    typealias T = ReadTarget
    private let docTarget = T(role: .docs, via: .doc)
    private let linesTarget = T(role: .lines, via: .rev3, grouped: true, reroutedFrom: .docs, standIn: .layout)

    private func submit(_ s: inout ReadScheduler, client: Int, frame: Int, _ target: T, purpose: WorkerJob.Purpose = .lens,
                        at t: TimeInterval = 0) -> ReadScheduler.Job {
        s.submit(client: client, purpose: purpose, frame: frame, key: "en", target: target, now: t).job
    }

    @Test func oneInFlightPerWorkerFIFO() {
        var s = ReadScheduler()
        let a = submit(&s, client: 1, frame: 1, docTarget), b = submit(&s, client: 2, frame: 1, docTarget)
        let next2 = s.next(.docs)?.id
        #expect(next2 == a.id)
        let next3 = s.next(.docs)
        #expect(next3 == nil)                           // a is in flight
        let next4 = s.next(.lines)
        #expect(next4 == nil)
        let delivery = s.complete(.docs, id: a.id)
        #expect(delivery == .accept)
        let next5 = s.next(.docs)?.id
        #expect(next5 == b.id)
    }

    @Test func aNewerJobOfTheSameClientSupersedesTheQueuedOne() {
        var s = ReadScheduler()
        _ = submit(&s, client: 9, frame: 1, docTarget)
        let next2 = s.next(.docs)
        #expect(next2 != nil)                           // in flight: not touched
        let queued = submit(&s, client: 1, frame: 1, docTarget)
        let newer = s.submit(client: 1, purpose: .lens, frame: 2, key: "en", target: docTarget, now: 1)
        #expect(newer.superseded?.id == queued.id)
        #expect(s.queued(.docs).map(\.id) == [newer.job.id])
        // across workers: the queued job of a client sits in one queue only
        let moved = s.submit(client: 1, purpose: .lens, frame: 3, key: "en", target: T(role: .lines, via: .rev3), now: 2)
        #expect(moved.superseded?.id == newer.job.id)
        #expect(s.queued(.docs).isEmpty && s.queued(.lines).map(\.id) == [moved.job.id])
    }

    @Test func lensBeforeImageThenFIFO() {
        var s = ReadScheduler()
        let image = submit(&s, client: 10, frame: 1, docTarget, purpose: .image)
        let lens1 = submit(&s, client: 1, frame: 1, docTarget)
        let lens2 = submit(&s, client: 2, frame: 1, docTarget)
        let image2 = submit(&s, client: 11, frame: 1, docTarget, purpose: .image)
        var order: [Int] = []
        while let job = s.next(.docs) { order.append(job.id); _ = s.complete(.docs, id: job.id) }
        #expect(order == [lens1.id, lens2.id, image.id, image2.id])
    }

    @Test func aWarmupTakesOnlyAFreeSlot() {
        var s = ReadScheduler()
        #expect(s.slotIsFree(.lines))
        let lensJob = submit(&s, client: 1, frame: 1, T(role: .lines, via: .rev3))
        #expect(!s.slotIsFree(.lines))                          // queued
        let warmup2 = s.beginWarmup(client: 0, role: .lines, via: .rev3, key: "en", now: 0)
        #expect(warmup2 == nil)
        _ = s.next(.lines)
        #expect(!s.slotIsFree(.lines))                          // in flight
        let delivery = s.complete(.lines, id: lensJob.id)
        #expect(delivery == .accept)
        let warm = s.beginWarmup(client: 0, role: .lines, via: .rev3, key: "en", now: 5)
        #expect(warm != nil && !s.slotIsFree(.lines))
        let delivery2 = s.complete(.lines, id: warm!.id)
        #expect(delivery2 == .warmup)
        #expect(s.slotIsFree(.docs))
    }

    @Test func rerouteHandsBackTheLensJobsQueuedAndInFlight() {
        var s = ReadScheduler()
        let inflight = submit(&s, client: 1, frame: 5, docTarget)
        _ = s.next(.docs)
        let queuedLens = submit(&s, client: 2, frame: 3, docTarget)
        let queuedImage = submit(&s, client: 3, frame: 1, docTarget, purpose: .image)
        let handed = s.reroute(.docs)
        #expect(handed.map(\.id) == [inflight.id, queuedLens.id, queuedImage.id])
        #expect(s.queued(.docs).isEmpty)
        #expect(s.inFlight(.docs)?.id == inflight.id)           // it runs on
        let next2 = s.next(.docs)
        #expect(next2 == nil)                           // and the slot stays taken: one request in flight
    }

    @Test func testNewestFrameFirstResultWins() {
        // Today an abandoned request's result still comes back (`TextRecognizer.swift:225-229`) and whichever pass is awaiting
        // takes it, so a late answer for an old frame can land over the reroute's answer for the new one. §10.4: per client, the
        // first result for the newest frame wins and a later one is dropped.
        var s = ReadScheduler()
        // 1. The reroute answers first; the suspect original comes second and is dropped.
        let original = submit(&s, client: 1, frame: 7, docTarget)
        _ = s.next(.docs)
        _ = s.reroute(.docs)
        let rerouted = submit(&s, client: 1, frame: 7, linesTarget)
        let next2 = s.next(.lines)?.id
        #expect(next2 == rerouted.id)
        let delivery = s.complete(.lines, id: rerouted.id)
        #expect(delivery == .accept)
        let delivery2 = s.complete(.docs, id: original.id)
        #expect(delivery2 == .drop(.rerouted))
        #expect(s.dropped[.rerouted] == 1)

        // 2. The original answers first (it was slow, not stuck); the queued copy of the reroute is not read at all.
        let orig2 = submit(&s, client: 1, frame: 8, docTarget)
        _ = s.next(.docs)
        _ = s.reroute(.docs)
        _ = submit(&s, client: 1, frame: 8, linesTarget)
        let delivery3 = s.complete(.docs, id: orig2.id)
        #expect(delivery3 == .accept)
        let next3 = s.next(.lines)
        #expect(s.queued(.lines).isEmpty && next3 == nil)

        // 3. A newer frame was submitted while an older one was in flight: the older result is stale, the newer wins.
        let old = submit(&s, client: 1, frame: 9, docTarget)
        _ = s.next(.docs)
        let new = submit(&s, client: 1, frame: 10, docTarget)
        let delivery4 = s.complete(.docs, id: old.id)
        #expect(delivery4 == .drop(.stale))
        let next4 = s.next(.docs)?.id
        #expect(next4 == new.id)
        let delivery5 = s.complete(.docs, id: new.id)
        #expect(delivery5 == .accept)
        #expect(s.dropped[.stale] == 1)

        // 4. Clients do not shadow each other.
        let other = submit(&s, client: 2, frame: 1, docTarget)
        _ = s.next(.docs)
        let delivery6 = s.complete(.docs, id: other.id)
        #expect(delivery6 == .accept)
    }

    @Test func testReadyLinesRereadsFastLenses() {
        // §10.4: on `readerReady(.lines)` the lenses that read through `.fast` read once more. Today only a timer re-runs a pass,
        // and a lens that read `.fast` while rev3 compiled keeps that read until its pixels change.
        var s = ReadScheduler()
        let fast = T(role: .docs, via: .fast, reroutedFrom: .lines, standIn: .lines)
        let a = submit(&s, client: 1, frame: 1, fast)
        _ = s.next(.docs)
        let delivery = s.complete(.docs, id: a.id)
        #expect(delivery == .accept)
        let b = submit(&s, client: 2, frame: 1, T(role: .lines, via: .rev3))     // read at full quality: nothing to redo
        _ = s.next(.lines)
        let delivery2 = s.complete(.lines, id: b.id)
        #expect(delivery2 == .accept)
        let quiet = s.readerReady(.docs).isEmpty
        #expect(quiet)                    // not what a fast read stands in for
        let ready2 = s.readerReady(.lines)
        #expect(ready2 == [1])
        let quiet2 = s.readerReady(.lines).isEmpty
        #expect(quiet2)                   // once
    }

    @Test func readyDocsRereadsLensesWhoseLayoutCameFromAReroute() {
        var s = ReadScheduler()
        let a = submit(&s, client: 1, frame: 1, linesTarget)
        _ = s.next(.lines)
        _ = s.complete(.lines, id: a.id)
        let b = submit(&s, client: 2, frame: 1, T(role: .lines, via: .fast, grouped: true, standIn: [.layout, .lines]))
        _ = s.next(.lines)
        _ = s.complete(.lines, id: b.id)
        let ready = s.readerReady(.docs)
        #expect(ready == [1, 2])
        let quiet = s.readerReady(.docs).isEmpty
        #expect(quiet)
        let ready3 = s.readerReady(.lines)
        #expect(ready3 == [2])                    // the fast read is also owed a Lines re-read
    }

    @Test func aNormalReadClearsWhatAStandInOwed() {
        var s = ReadScheduler()
        let a = submit(&s, client: 1, frame: 1, linesTarget)
        _ = s.next(.lines)
        _ = s.complete(.lines, id: a.id)
        let b = submit(&s, client: 1, frame: 2, docTarget)       // the layout came back by itself
        _ = s.next(.docs)
        _ = s.complete(.docs, id: b.id)
        let quiet = s.readerReady(.docs).isEmpty
        #expect(quiet)
    }

    @Test func forgettingAClientDropsItsQueueAndFlags() {
        var s = ReadScheduler()
        let a = submit(&s, client: 1, frame: 1, linesTarget)
        _ = s.next(.lines)
        _ = s.complete(.lines, id: a.id)
        _ = submit(&s, client: 1, frame: 2, docTarget)
        s.forget(client: 1)
        #expect(s.queued(.docs).isEmpty)
        let quiet = s.readerReady(.docs).isEmpty
        #expect(quiet)
    }

    @Test func aLostJobFreesTheSlot() {
        var s = ReadScheduler()
        let a = submit(&s, client: 1, frame: 1, docTarget)
        _ = s.next(.docs)
        let lost2 = s.lost(.docs)?.id
        #expect(lost2 == a.id)
        #expect(s.inFlight(.docs) == nil && s.slotIsFree(.docs))
        let lost3 = s.lost(.docs)
        #expect(lost3 == nil)
        let delivery = s.complete(.docs, id: a.id)
        #expect(delivery == .drop(.stale))    // a reply from the dead process, if one ever came
    }
}
