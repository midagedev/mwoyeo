import AppKit
import CoreVideo
import Foundation
import MwoyeoCore
import Vision

/// `Mwoyeo --reader-check <scenario> …`: the gates of the reader services that need one process holding both the app's own Vision
/// and the services (tools/ocr-probe/reader-equal.sh drives the picture sets). Prints `check: <scenario> … PASS|FAIL` lines and
/// exits 1 on a FAIL.
///
///   hello                              both services say who they are (pid, footprint)
///   warm <lang>                        the warm-up jobs, in the design's order (Lines, then Docs), with their cold times
///   equal <lang> <png…>                every kind, in this process and through a service: lines, words and rects equal to 0 px
///   bgra <lang> <png…>                 frames as ScreenCaptureKit hands them out (IOSurface-backed BGRA pixel buffers)
///   crash                              a service that exits mid-job, is killed, is asked to exit: each an event, and the next job relaunches it
///   fakes                              every MWOYEO_FAKE_READER mode, a job sent as bytes, a job the service refuses, no service at all
///   footprint <reads> <lang> <png>     footprint -p of each service after its first read, after warm-up and after the reads, and the read latency
///   hop <reads> <lang> <png>           where the time of a read through a service goes: in this process, the surface, the bytes
///   idle <seconds> <lang> <png>        a warm service is still the same process after it has been idle that long
enum ReaderCheck {
    static func run(_ args: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        Task.detached {
            do {
                try await check(args)
                exit(0)
            } catch {
                print("check: FAIL \(error)")
                exit(1)
            }
        }
        RunLoop.main.run()
        exit(0)
    }

    private struct Failure: Error, CustomStringConvertible { let description: String }

    private static func check(_ args: [String]) async throws {
        guard let scenario = args.first else { throw Failure(description: "usage: --reader-check hello|warm|equal|bgra|crash|fakes|footprint|hop|idle …") }
        let rest = Array(args.dropFirst())
        switch scenario {
        case "hello": try await hello()
        case "warm": try await warm(language: rest.first ?? "en")
        case "equal": try await equal(language: rest.first ?? "en", paths: Array(rest.dropFirst()))
        case "bgra": try await bgra(language: rest.first ?? "en", paths: Array(rest.dropFirst()))
        case "crash": try await crash()
        case "fakes": try await fakes()
        case "hop": try await hop(reads: Int(rest.first ?? "30") ?? 30, language: rest.dropFirst().first ?? "en", path: rest.dropFirst(2).first)
        case "footprint": try await footprint(reads: Int(rest.first ?? "100") ?? 100, language: rest.dropFirst().first ?? "en", path: rest.dropFirst(2).first)
        case "idle": try await idle(seconds: Double(rest.first ?? "90") ?? 90, language: rest.dropFirst().first ?? "en", path: rest.dropFirst(2).first)
        default: throw Failure(description: "unknown scenario \(scenario)")
        }
    }

    // MARK: Scenarios

    private static func hello() async throws {
        var ok = true
        for role in ReaderRole.allCases {
            let connection = ReaderConnection.shared(role)
            guard let hello = await connection.hello() else { print("check: hello \(role.rawValue) no answer"); ok = false; continue }
            print("check: hello \(role.rawValue) pid=\(hello.pid) gui pid=\(getpid()) footprint=\(hello.footprint >> 20) MB version=\(hello.version)")
            ok = ok && hello.pid != getpid() && hello.role == role
        }
        try verdict("hello", ok)
    }

    private static func warm(language: String) async throws {
        let lines = ReaderConnection.shared(.lines), docs = ReaderConnection.shared(.docs)
        var ok = true
        // The design's order: Lines is warm before Docs starts, because the compile service takes one compile at a time.
        var t = Date()
        do { _ = try await lines.read(.warmLines, image: nil, roi: nil) } catch { print("check: warm lines failed: \(error)"); ok = false }
        print("check: warm lines ms=\(ms(t)) pid=\(lines.servicePid ?? 0)")
        t = Date()
        do { _ = try await docs.read(.warmDoc, image: nil, roi: nil, documentLanguages: [Locale.Language(identifier: language)]) } catch { print("check: warm docs failed: \(error)"); ok = false }
        print("check: warm docs ms=\(ms(t)) pid=\(docs.servicePid ?? 0)")
        try verdict("warm", ok)
    }

    private static func equal(language: String, paths: [String]) async throws {
        var total = 0, same = 0, worst = 0.0
        for path in paths {
            let image = try load(path)
            for run in try kinds(language: language, image: image) {
                let local = try await run.local()
                let remote = try await run.remote()
                let c = compare(local, remote)
                total += 1
                if c.same { same += 1 }
                worst = max(worst, c.delta)
                print("check: equal \(name(path)) \(run.label) lines=\(local.lines.count) same=\(c.same) delta=\(c.delta)\(c.same ? "" : " (\(c.why))")")
            }
        }
        print("check: equal same: \(same)/\(total) reads, max rect delta \(worst) px")
        try verdict("equal", total > 0 && same == total && worst == 0)
    }

    private static func bgra(language: String, paths: [String]) async throws {
        var total = 0, same = 0
        for path in paths {
            let source = try load(path)
            let pb = try bgraPixelBuffer(from: source)
            // The frame as the capturer makes it, and the pixel buffer itself as the connection sends it.
            guard let frame = RegionCapturer.makeFrame(pb, rect: CGRect(x: 0, y: 0, width: source.width, height: source.height), scale: 2, time: 0) else {
                throw Failure(description: "makeFrame failed for \(path)")
            }
            for run in try kinds(language: language, image: frame.image).filter({ $0.label == "rev3" || $0.label == "doc" }) {
                let local = try await run.local()
                let viaPixelBuffer = try await run.remote(pixelBuffer: pb)
                let viaImage = try await run.remote()
                let a = compare(local, viaPixelBuffer), b = compare(local, viaImage)
                total += 2
                same += (a.same ? 1 : 0) + (b.same ? 1 : 0)
                print("check: bgra \(name(path)) \(run.label) lines=\(local.lines.count) pixelBuffer same=\(a.same) delta=\(a.delta) cgImage same=\(b.same) delta=\(b.delta)")
            }
        }
        print("check: bgra same: \(same)/\(total)")
        try verdict("bgra", total > 0 && same == total)
    }

    private static func crash() async throws {
        let victim = ReaderConnection(role: .lines, fakes: ReaderFakePlan("crash"))
        let events = Collected<ReaderConnectionEvent>()
        let stream = victim.events()
        let listening = Task { for await e in stream { events.add(e) } }
        defer { listening.cancel() }
        let picture = ReaderCheck.drawn
        func fast() async -> ReadReply {
            var job = ReadJob(kind: .fast, languages: [])
            guard let packed = ReaderPixels.surface(from: picture) else { return ReadReply(id: 0, role: .lines, pid: 0, error: .badJob("pack")) }
            job.image = packed.image
            return await victim.perform(job, surface: packed.surface)
        }
        // The first job carries the crash: no answer, an interruption.
        let first = await victim.hello()
        let pid1 = first?.pid ?? 0
        let crashed = await fast()
        try await Task.sleep(for: .milliseconds(300))
        let interrupted = events.all.contains { if case .interrupted = $0 { true } else { false } }
        print("check: crash job1 error=\(crashed.error.map { "\($0)" } ?? "none") interruption event=\(interrupted) service pid was \(pid1)")
        // The next job relaunches the service and answers.
        let t = Date()
        let second = await fast()
        let pid2 = second.pid
        print("check: crash job2 error=\(second.error.map { "\($0)" } ?? "none") lines=\(second.lines.count) pid=\(pid2) relaunch ms=\(ms(t))")
        // A kill on the recorded pid is the same event. (launchd throttles a respawn after an instance that lived under 10 s; this one has
        // lived longer, so the relaunch below shows what a recycle of a service that has been up costs.)
        try await Task.sleep(for: .seconds(11))
        victim.killService()
        try await Task.sleep(for: .milliseconds(300))
        let t3 = Date()
        let third = await fast()
        print("check: crash killService → next job error=\(third.error.map { "\($0)" } ?? "none") pid=\(third.pid) (was \(pid2)) relaunch ms=\(ms(t3))")
        let sawConnected = events.all.contains { if case let .connected(_, pid) = $0 { pid == pid2 } else { false } }
        // The exit message is the polite recycle: the service answers with its pid, exits, and the next job starts another.
        try await Task.sleep(for: .seconds(11))
        let asked = await victim.exitWhenIdle()
        try await Task.sleep(for: .milliseconds(800))
        let gone = asked.map { kill($0, 0) != 0 } ?? false
        let t4 = Date()
        let fourth = await fast()
        print("check: crash exitWhenIdle → pid \(asked ?? 0) gone=\(gone); next job error=\(fourth.error.map { "\($0)" } ?? "none") pid=\(fourth.pid) relaunch ms=\(ms(t4))")
        try verdict("crash", crashed.error == .interrupted && interrupted && second.error == nil && !second.lines.isEmpty && pid2 != 0 && pid2 != pid1
                    && sawConnected && third.error == nil && third.pid != pid2 && third.pid != 0
                    && asked == third.pid && gone && fourth.error == nil && fourth.pid != 0 && fourth.pid != third.pid)
    }

    private static func fakes() async throws {
        let picture = drawn
        guard let packed = ReaderPixels.surface(from: picture) else { throw Failure(description: "cannot pack the probe picture") }
        let local = VisionExec.Output.lines(try VisionExec.readLines(.rev3, in: picture, roi: nil, languages: [], customWords: []))
        func job(_ kind: ReadKind = .rev3) -> ReadJob { ReadJob(kind: kind, image: packed.image) }
        var results: [(String, Bool)] = []
        func note(_ what: String, _ ok: Bool, _ detail: String = "") { results.append((what, ok)); print("check: fakes \(what) \(ok ? "ok" : "WRONG") \(detail)") }

        // lines-e5rt:2 — the first two newest-model jobs fail like a Mac whose programs are not ready; the third reads.
        let e5rt = ReaderConnection(role: .lines, fakes: ReaderFakePlan("lines-e5rt:2"))
        let a = await e5rt.perform(job(), surface: packed.surface), b = await e5rt.perform(job(), surface: packed.surface)
        let c = await e5rt.perform(job(), surface: packed.surface)
        let typed: (ReadReply) -> Bool = { r in if case .programsNotReady? = r.error { true } else { false } }
        note("lines-e5rt:2", typed(a) && typed(b) && c.error == nil, "jobs: \(a.error.map { "\($0)".prefix(24) } ?? "none") / \(b.error.map { "\($0)".prefix(24) } ?? "none") / \(c.error == nil ? "read" : "error")")
        note("lines-e5rt is what OCRHealth classifies", a.error.map { OCRHealth.programsNotReady($0) } ?? false)
        note("an e5rt job is not an answer", c.lines.count == local.lines.count && compare(local, .lines(c.lines.map(VisionExec.unwire))).same)

        // lines-slow / docs-slow — the answer is late, not different.
        let slowLines = ReaderConnection(role: .lines, fakes: ReaderFakePlan("lines-slow:400"))
        let t1 = Date()
        let s1 = await slowLines.perform(job(), surface: packed.surface)
        note("lines-slow:400", ms(t1) >= 400 && s1.ms >= 400 && s1.error == nil && compare(local, .lines(s1.lines.map(VisionExec.unwire))).same, "took \(ms(t1)) ms, worker says \(Int(s1.ms)) ms")
        let slowDocs = ReaderConnection(role: .docs, fakes: ReaderFakePlan("docs-slow:300"))
        let t2 = Date()
        let s2 = await slowDocs.perform(ReadJob(kind: .doc, image: packed.image, documentLanguages: []), surface: packed.surface)
        note("docs-slow:300", ms(t2) >= 300 && s2.ms >= 300 && s2.error == nil && !s2.paragraphs.isEmpty, "took \(ms(t2)) ms, \(s2.paragraphs.count) paragraphs")

        // shift1 — every rect 1 px to the right, nothing else.
        let shifted = ReaderConnection(role: .lines, fakes: ReaderFakePlan("shift1"))
        let m = await shifted.perform(job(), surface: packed.surface)
        let cmp = compare(local, .lines(m.lines.map(VisionExec.unwire)))
        note("shift1", cmp.same && cmp.delta == 1 && m.lines.count == local.lines.count, "max rect delta \(cmp.delta)")

        // The picture as bytes instead of a surface: the same answer.
        let plain = ReaderConnection(role: .lines, fakes: ReaderFakePlan(nil))
        if let data = picture.dataProvider?.data as Data?, let described = ReaderPixels.surface(from: picture)?.image {
            let viaBytes = await plain.perform(ReadJob(kind: .rev3, image: described), bytes: copyRows(data, picture: picture, into: described))
            note("pixels as bytes", viaBytes.error == nil && compare(local, .lines(viaBytes.lines.map(VisionExec.unwire))).same, "\(viaBytes.lines.count) lines")
        } else { note("pixels as bytes", false, "no pixel data") }

        // Jobs the service must refuse, said as a typed failure, not a crash.
        let wrongRole = await plain.perform(ReadJob(kind: .doc, image: packed.image), surface: packed.surface)
        note("a doc job to Lines is refused", { if case .badJob? = wrongRole.error { true } else { false } }(), "\(wrongRole.error.map { "\($0)" } ?? "none")")
        let noPicture = await plain.perform(ReadJob(kind: .rev3))
        note("a read without a picture is refused", { if case .badJob? = noPicture.error { true } else { false } }(), "\(noPicture.error.map { "\($0)" } ?? "none")")
        var wrongSize = packed.image
        wrongSize.width += 1
        let mismatch = await plain.perform(ReadJob(kind: .rev3, image: wrongSize), surface: packed.surface)
        note("a surface that is not as described is refused", { if case .badJob? = mismatch.error { true } else { false } }(), "\(mismatch.error.map { "\($0)" } ?? "none")")

        // No such service: the job fails as unavailable and the connection reports its invalidation.
        let nowhere = ReaderConnection(role: .lines, appID: "dev.midagedev.mwoyeo.no-such-app", fakes: ReaderFakePlan(nil))
        let events = Collected<ReaderConnectionEvent>()
        let stream = nowhere.events()
        let listening = Task { for await e in stream { events.add(e) } }
        defer { listening.cancel() }
        let lost = await nowhere.perform(job(), surface: packed.surface)
        try await Task.sleep(for: .milliseconds(300))
        note("no such service", { if case .unavailable? = lost.error { true } else { false } }() && events.all.contains(.invalidated(.lines)),
             "\(lost.error.map { "\($0)".prefix(60) } ?? "none"); events \(events.all)")
        try verdict("fakes", results.allSatisfy(\.1))
    }

    /// The picture's pixels as one run of rows at the stride `described` names (what travels as bytes).
    private static func copyRows(_ data: Data, picture: CGImage, into described: ReadImage) -> Data {
        var out = Data(count: described.bytesPerRow * picture.height)
        out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                for y in 0..<picture.height {
                    memcpy(dst.baseAddress! + y * described.bytesPerRow, src.baseAddress! + y * picture.bytesPerRow, picture.width * 4)
                }
            }
        }
        return out
    }

    private static func footprint(reads: Int, language: String, path: String?) async throws {
        let image = try path.map(load) ?? drawn
        let lines = ReaderConnection.shared(.lines), docs = ReaderConnection.shared(.docs)
        // footprint(1) is the reference; the service's own `phys_footprint` (`hello`) says the same thing from inside.
        func show(_ when: String) async {
            for (role, connection) in [(ReaderRole.lines, lines), (.docs, docs)] {
                guard let hello = await connection.hello() else { print("check: footprint \(role.rawValue) \(when): no answer"); continue }
                print("check: footprint \(role.rawValue) pid=\(hello.pid) \(when): \(footprintLine(hello.pid)), self-reported \(hello.footprint >> 20) MB")
            }
        }
        let ids = rev3Languages(language)
        // A read before any warm-up job: what the first language costs.
        for (role, connection) in [(ReaderRole.lines, lines), (.docs, docs)] {
            guard let packed = ReaderPixels.surface(from: image) else { continue }
            let kind: ReadKind = role == .lines ? .rev3 : .doc
            _ = await connection.perform(ReadJob(kind: kind, image: packed.image, languages: role == .lines ? ids : [],
                                                 documentLanguages: role == .docs ? [Locale.Language(identifier: language)] : []), surface: packed.surface)
        }
        try await Task.sleep(for: .seconds(2))
        await show("after the first read, no warm-up job")
        _ = try await lines.read(.warmLines, image: nil, roi: nil)
        _ = try await docs.read(.warmDoc, image: nil, roi: nil, documentLanguages: [Locale.Language(identifier: language)])
        try await Task.sleep(for: .seconds(2))
        await show("after warm-up")
        var lineMs: [Double] = [], docMs: [Double] = []
        for _ in 0..<reads {
            var t = Date()
            _ = try await lines.read(.rev3, image: image, roi: nil, languages: ids)
            lineMs.append(msFine(t))
            t = Date()
            _ = try await docs.read(.doc, image: image, roi: nil, documentLanguages: [Locale.Language(identifier: language)])
            docMs.append(msFine(t))
        }
        await show("after \(reads) reads of each")
        print("check: footprint reads rev3 p50=\(percentile(lineMs, 0.5)) ms p95=\(percentile(lineMs, 0.95)) ms; doc p50=\(percentile(docMs, 0.5)) ms p95=\(percentile(docMs, 0.95)) ms")
        // The same line read in this process, and the packing alone: what the hop costs is the difference (a document read has no
        // in-process time: the app cannot run one any more).
        var localLines: [Double] = [], pack: [Double] = []
        for _ in 0..<reads {
            var t = Date()
            _ = try VisionExec.readLines(.rev3, in: image, roi: nil, languages: ids, customWords: [])
            localLines.append(msFine(t))
            t = Date()
            _ = ReaderPixels.surface(from: image)
            pack.append(msFine(t))
        }
        func p50(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
        print(String(format: "check: latency %dx%d (%.1f MB) rev3 xpc %.1f in-process %.1f hop %.1f ms; doc xpc %.1f ms; packing alone %.2f ms",
                     image.width, image.height, Double(image.width * image.height * 4) / 1e6, p50(lineMs), p50(localLines), p50(lineMs) - p50(localLines),
                     p50(docMs), p50(pack)))
        try verdict("footprint", true)
    }

    /// Where the time of a read through a service goes: the same read in this process, with the picture as a surface (zero copy) and
    /// as bytes, each as the whole call and as the worker's own time (`ReadReply.ms`). Interleaved, so that drift cancels.
    private static func hop(reads: Int, language: String, path: String?) async throws {
        let image = try path.map(load) ?? drawn
        guard let packed = ReaderPixels.surface(from: image), let data = image.dataProvider?.data as Data? else { throw Failure(description: "no pixels") }
        let bytes = copyRows(data, picture: image, into: packed.image)
        let ids = rev3Languages(language)
        let doc = Locale.Language(identifier: language)
        // The floor: one message with nothing in it, there and back.
        for role in ReaderRole.allCases {
            let connection = ReaderConnection.shared(role)
            _ = await connection.hello()
            var v: [Double] = []
            for _ in 0..<100 { let t = Date(); _ = await connection.hello(); v.append(msFine(t)) }
            v.sort()
            print(String(format: "check: hop %@ hello round trip min %.2f p50 %.2f p95 %.2f ms", role.rawValue, v[0], v[50], v[95]))
        }
        for kind in [ReadKind.rev3, .doc] {
            let connection = ReaderConnection.shared(ReaderRole.home(of: kind))
            func job() -> ReadJob { ReadJob(kind: kind, image: packed.image, languages: kind == .rev3 ? ids : [], documentLanguages: kind == .doc ? [doc] : []) }
            var samples: [String: [Double]] = [:]
            func add(_ key: String, _ v: Double) { samples[key, default: []].append(v) }
            func runLocal() async throws {
                let t = Date()
                // The app has no document read of its own any more (r3-docs-xpc): only the line kinds have an in-process time.
                if kind == .rev3 { _ = try VisionExec.readLines(.rev3, in: image, roi: nil, languages: ids, customWords: []) }
                add("local", kind == .rev3 ? msFine(t) : 0)
            }
            func runRemote(_ name: String, surface: IOSurface?, bytes: Data?) async throws {
                let t = Date()
                let r = await connection.perform(job(), surface: surface, bytes: bytes)
                add(name + " total", msFine(t)); add(name + " worker", r.ms)
                if let e = r.error { throw Failure(description: "read failed: \(e)") }
            }
            // The order rotates, so that no variant always follows the same one.
            for i in 0..<(reads + 3) {
                let order = [0, 1, 2].map { ($0 + i) % 3 }
                for v in order {
                    switch v {
                    case 0: try await runLocal()
                    case 1: try await runRemote("surface", surface: packed.surface, bytes: nil)
                    default: try await runRemote("bytes", surface: nil, bytes: bytes)
                    }
                }
            }
            func stat(_ key: String) -> String {
                let v = Array((samples[key] ?? []).dropFirst(3)).sorted()   // the first three are warm-up of the loop itself
                return String(format: "%.0f/%.0f", v.first ?? 0, v.isEmpty ? 0 : v[v.count / 2])
            }
            // What the reply costs to encode (in the worker) and to decode (here): the one term of the transport that is code, not the system.
            let sample = await connection.perform(job(), surface: packed.surface)
            var encoded: [Double] = [], decoded: [Double] = [], size = 0
            for _ in 0..<50 {
                var t = Date()
                let blob = try ReaderWire.encode(sample)
                encoded.append(msFine(t))
                size = blob.count
                t = Date()
                _ = try ReaderWire.decode(ReadReply.self, from: blob)
                decoded.append(msFine(t))
            }
            let words = (sample.lines + sample.paragraphs.flatMap { $0 }).reduce(0) { $0 + $1.words.count }
            print(String(format: "check: hop %@ reply: %d lines %d words %d bytes; encode p50 %.2f ms, decode p50 %.2f ms", kind.rawValue,
                         sample.lines.count + sample.paragraphs.flatMap { $0 }.count, words, size, encoded.sorted()[25], decoded.sorted()[25]))
            print("check: hop \(kind.rawValue) \(image.width)x\(image.height) min/p50 ms over \(reads): in-process \(stat("local")) | surface total \(stat("surface total")) worker \(stat("surface worker")) | bytes total \(stat("bytes total")) worker \(stat("bytes worker"))")
        }
        try verdict("hop", true)
    }

    private static func idle(seconds: Double, language: String, path: String?) async throws {
        let image = try path.map(load) ?? drawn
        let lines = ReaderConnection.shared(.lines)
        _ = try await lines.read(.rev3, image: image, roi: nil, languages: rev3Languages(language))
        let before = lines.servicePid
        try await Task.sleep(for: .seconds(seconds))
        let t = Date()
        let reply = await lines.perform(ReadJob(kind: .warmLines))
        print("check: idle \(Int(seconds)) s: pid \(before ?? 0) → \(reply.pid), next job ms=\(ms(t)) error=\(reply.error.map { "\($0)" } ?? "none")")
        try verdict("idle", before != nil && reply.pid == before && reply.error == nil)
    }

    // MARK: Pieces

    /// A way to run one kind on one picture: in this process, and through the service.
    private struct Run {
        let label: String
        let local: () async throws -> VisionExec.Output
        let remote: () async throws -> VisionExec.Output
        let remotePixelBuffer: (CVPixelBuffer) async throws -> VisionExec.Output

        func remote(pixelBuffer: CVPixelBuffer) async throws -> VisionExec.Output { try await remotePixelBuffer(pixelBuffer) }
    }

    /// Every rung the language has (as `TextRecognizer.accurate` walks them), the document read, and `.fast` on the Docs service.
    private static func kinds(language: String, image: CGImage) throws -> [Run] {
        let doc = Locale.Language(identifier: language)
        var runs: [Run] = []
        func lineRun(_ label: String, _ kind: ReadKind, _ ids: [String], role: ReaderRole) -> Run {
            Run(label: label,
                local: { .lines(try VisionExec.readLines(kind, in: image, roi: nil, languages: ids, customWords: [])) },
                remote: { try await ReaderConnection.shared(role).read(kind, image: image, roi: nil, languages: ids) },
                remotePixelBuffer: { try await ReaderConnection.shared(role).read(kind, pixelBuffer: $0, roi: nil, languages: ids) })
        }
        let ladder = OCRFallback.ladder(requested: [language], vision3: supported(.accurate, 3), revision2: supported(.accurate, 2), fast: supported(.fast, nil))
        for rung in ladder {
            switch rung {
            case let .vision3(ids): runs.append(lineRun("rev3", .rev3, ids, role: .lines))
            case let .revision2(ids): runs.append(lineRun("rev2", .rev2, ids, role: .lines))
            case let .fast(ids):
                runs.append(lineRun("fast", .fast, ids, role: .lines))
                runs.append(lineRun("fast@docs", .fast, ids, role: .docs))
            }
        }
        // The app has no in-process document read any more (r3-docs-xpc): the reference of this run is the service's own earlier answer
        // (repeatability). The equivalence with the in-process read was proved by R1 (55/55) and across binaries by reader-equal.sh.
        runs.append(Run(label: "doc",
                        local: { try await ReaderConnection.shared(.docs).read(.doc, image: image, roi: nil, documentLanguages: [doc]) },
                        remote: { try await ReaderConnection.shared(.docs).read(.doc, image: image, roi: nil, documentLanguages: [doc]) },
                        remotePixelBuffer: { try await ReaderConnection.shared(.docs).read(.doc, pixelBuffer: $0, roi: nil, documentLanguages: [doc]) }))
        return runs
    }

    private static func supported(_ level: VNRequestTextRecognitionLevel, _ revision: Int?) -> [String] {
        if let revision, !VNRecognizeTextRequest.supportedRevisions.contains(revision) { return [] }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = level
        if let revision { req.revision = revision }
        return (try? req.supportedRecognitionLanguages()) ?? []
    }

    private static func rev3Languages(_ language: String) -> [String] {
        if case let .vision3(ids)? = OCRFallback.ladder(requested: [language], vision3: supported(.accurate, 3), revision2: [], fast: []).first { return ids }
        return []
    }

    private static func compare(_ a: VisionExec.Output, _ b: VisionExec.Output) -> (same: Bool, delta: Double, why: String) {
        var delta = 0.0
        func d(_ x: CGRect, _ y: CGRect) -> Double { max(abs(x.minX - y.minX), abs(x.minY - y.minY), abs(x.width - y.width), abs(x.height - y.height)) }
        func lines(_ x: [OCRLine], _ y: [OCRLine]) -> String? {
            guard x.count == y.count else { return "line count \(x.count) vs \(y.count)" }
            for (p, q) in zip(x, y) {
                if p.text != q.text { return "text \"\(p.text.prefix(30))\" vs \"\(q.text.prefix(30))\"" }
                delta = max(delta, d(p.rect, q.rect))
                guard p.words.count == q.words.count else { return "word count in \"\(p.text.prefix(30))\"" }
                for (u, v) in zip(p.words, q.words) {
                    if p.text.utf8.distance(from: p.text.utf8.startIndex, to: u.range.lowerBound) != q.text.utf8.distance(from: q.text.utf8.startIndex, to: v.range.lowerBound)
                        || p.text.utf8.distance(from: p.text.utf8.startIndex, to: u.range.upperBound) != q.text.utf8.distance(from: q.text.utf8.startIndex, to: v.range.upperBound) {
                        return "word range in \"\(p.text.prefix(30))\""
                    }
                    delta = max(delta, d(u.rect, v.rect))
                }
            }
            return nil
        }
        var why: String?
        switch (a, b) {
        case let (.lines(x), .lines(y)): why = lines(x, y)
        case let (.paragraphs(x), .paragraphs(y)):
            if x.count != y.count { why = "paragraph count \(x.count) vs \(y.count)" } else { for (p, q) in zip(x, y) where why == nil { why = lines(p, q) } }
        default: why = "shapes differ"
        }
        return (why == nil, delta, why ?? "")
    }

    private static func load(_ path: String) throws -> CGImage {
        guard let decoded = try? StillTranslation.decode(url: URL(fileURLWithPath: path), scale: 2) else { throw Failure(description: "cannot read \(path)") }
        return decoded.image
    }

    /// An IOSurface-backed BGRA pixel buffer holding `image`, drawn as ScreenCaptureKit's frames are (opaque, sRGB).
    private static func bgraPixelBuffer(from image: CGImage) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
        guard CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess, let pb = buffer else {
            throw Failure(description: "no pixel buffer")
        }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw Failure(description: "no context")
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pb
    }

    /// The drawn warm-up picture in the layout the app's own pictures have (sRGB RGBA, as a decoded PNG): the probe picture itself is
    /// device RGB, which a job would have to convert before it travels.
    private static let drawn: CGImage = {
        let picture = VisionExec.probePicture!
        return RGBAImage(cgImage: picture)?.cgImage ?? picture
    }()

    private static func footprintLine(_ pid: Int32) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/footprint")
        process.arguments = ["-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "footprint(1) did not run: \(error)" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").first { $0.contains("Footprint:") }.map { $0.trimmingCharacters(in: .whitespaces) } ?? "(no Footprint line: \(text.prefix(120)))"
    }

    private static func verdict(_ scenario: String, _ ok: Bool) throws {
        print("check: \(scenario) \(ok ? "PASS" : "FAIL")")
        if !ok { throw Failure(description: "\(scenario) failed") }
    }

    private static func name(_ path: String) -> String { URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }
    private static func ms(_ since: Date) -> Int { Int(Date().timeIntervalSince(since) * 1000) }
    private static func msFine(_ since: Date) -> Double { Date().timeIntervalSince(since) * 1000 }
    private static func percentile(_ v: [Double], _ p: Double) -> Int {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return Int(s[min(s.count - 1, Int(Double(s.count) * p))])
    }

    private final class Collected<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [T] = []
        func add(_ item: T) { lock.withLock { items.append(item) } }
        var all: [T] { lock.withLock { items } }
    }
}
