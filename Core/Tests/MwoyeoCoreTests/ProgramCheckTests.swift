import Foundation
import Testing
@testable import MwoyeoCore

/// What a Lines service does with its reading of the drawn check page (2026-10-21, D4): the good caches read all 33 lines of it, the
/// bad one 25.
@Suite struct ProgramCheckTests {
    @Test func aPageReadInFullIsGood() {
        #expect(ProgramCheck.verdict(drawn: 33, read: 33, resetsSoFar: 0) == .good)
        #expect(ProgramCheck.verdict(drawn: 33, read: 33, resetsSoFar: 2) == .good, "a good read after resets is good")
    }

    @Test func theRecordedBadCacheIsReset() {
        // 25 of 33: eight lines short.
        #expect(ProgramCheck.verdict(drawn: 33, read: 25, resetsSoFar: 0) == .reset)
        #expect(ProgramCheck.verdict(drawn: 33, read: 25, resetsSoFar: 1) == .reset, "a second bad compile is dropped too")
        #expect(ProgramCheck.verdict(drawn: 33, read: 25, resetsSoFar: ProgramCheck.resets) == .stillBad, "and a third time it serves as it is")
    }

    @Test func aLineOrTwoMissingIsNotABadCache() {
        // A future system may read one line of the page as two or leave one out: three missing is still good, four is not.
        #expect(ProgramCheck.verdict(drawn: 33, read: 30, resetsSoFar: 0) == .good)
        #expect(ProgramCheck.verdict(drawn: 33, read: 29, resetsSoFar: 0) == .reset)
        #expect(ProgramCheck.verdict(drawn: 33, read: 34, resetsSoFar: 0) == .good, "a line read as two")
        // The tolerance is under the bad cache's loss with room.
        #expect(ProgramCheck.tolerated <= 8 - 4)
    }
}

/// The cache of a service: where it is, how it is dropped and counted, and the mark that the programs were read once.
@Suite struct E5ProgramsTests {
    private func caches() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("e5programs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A cache with one compiled program, born at `born` (seconds since 1970; the system's own birth times are too close to tell apart).
    private func makeCache(_ root: URL, _ id: String, nested: Bool = true, born: Double = 1_000) throws -> URL {
        let cache = nested ? root.appendingPathComponent(id).appendingPathComponent(E5Programs.directoryName) : root.appendingPathComponent(E5Programs.directoryName)
        let program = cache.appendingPathComponent("26A428/131707")
        try FileManager.default.createDirectory(at: program, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: program.appendingPathComponent("H13S.e5"))
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: born)], ofItemAtPath: program.path)
        return cache
    }

    @Test func resetDropsTheProgramsAndCountsIt() throws {
        let root = try caches(), id = "dev.midagedev.mwoyeo.reader.lines"
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try makeCache(root, id)
        #expect(E5Programs.resetsSoFar(bundleID: id, in: root, osBuild: "26A428") == 0)
        #expect(E5Programs.reset(bundleID: id, in: root, osBuild: "26A428"))
        #expect(!FileManager.default.fileExists(atPath: cache.path), "the programs are gone")
        #expect(E5Programs.resetsSoFar(bundleID: id, in: root, osBuild: "26A428") == 1)
        #expect(E5Programs.resetsSoFar(bundleID: id, in: root, osBuild: "26A429") == 0, "the count is per system build")
        // Compiled again, bad again: the second reset counts 2.
        _ = try makeCache(root, id)
        #expect(E5Programs.reset(bundleID: id, in: root, osBuild: "26A428"))
        #expect(E5Programs.resetsSoFar(bundleID: id, in: root, osBuild: "26A428") == 2)
    }

    @Test func aGoodReadStartsTheCountOver() throws {
        let root = try caches(), id = "dev.midagedev.mwoyeo.reader.lines"
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeCache(root, id)
        E5Programs.reset(bundleID: id, in: root, osBuild: "26A428")
        _ = try makeCache(root, id)
        E5Programs.reset(bundleID: id, in: root, osBuild: "26A428")
        #expect(E5Programs.resetsSoFar(bundleID: id, in: root, osBuild: "26A428") == 2)
        // The third compile is good: a bad one a month later is a first, not a third.
        _ = try makeCache(root, id)
        E5Programs.markVerified(bundleID: id, in: root, osBuild: "26A428", build: "100")
        #expect(E5Programs.resetsSoFar(bundleID: id, in: root, osBuild: "26A428") == 0)
        #expect(ProgramCheck.verdict(drawn: 33, read: 25, resetsSoFar: E5Programs.resetsSoFar(bundleID: id, in: root, osBuild: "26A428")) == .reset)
    }

    @Test func nothingToDropIsNoReset() throws {
        let root = try caches()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!E5Programs.reset(bundleID: "dev.midagedev.mwoyeo.reader.lines", in: root, osBuild: "26A428"), "no cache: the service does not exit for it")
        #expect(E5Programs.resetsSoFar(bundleID: "dev.midagedev.mwoyeo.reader.lines", in: root, osBuild: "26A428") == 0)
    }

    @Test func theSandboxLayoutIsFoundToo() throws {
        let root = try caches()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try makeCache(root, "ignored", nested: false)
        #expect(E5Programs.caches(bundleID: "dev.midagedev.mwoyeo.reader.lines", in: root).map { $0.resolvingSymlinksInPath().path } == [cache.resolvingSymlinksInPath().path])
        #expect(E5Programs.reset(bundleID: "dev.midagedev.mwoyeo.reader.lines", in: root, osBuild: "26A428"))
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @Test func theVerifiedMarkNamesTheProgramsItWasGivenFor() throws {
        let root = try caches(), id = "dev.midagedev.mwoyeo.reader.lines"
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try makeCache(root, id)
        #expect(!E5Programs.isVerified(bundleID: id, in: root, osBuild: "26A428", build: "100"))
        E5Programs.markVerified(bundleID: id, in: root, osBuild: "26A428", build: "100")
        #expect(E5Programs.isVerified(bundleID: id, in: root, osBuild: "26A428", build: "100"))
        #expect(!E5Programs.isVerified(bundleID: id, in: root, osBuild: "26A428", build: "101"), "a new build of the service compiles its own programs")
        #expect(!E5Programs.isVerified(bundleID: id, in: root, osBuild: "26A429", build: "100"), "and a new system its own")
        // The system clears what it did not write from its cache directory: the mark is not in it.
        #expect(!FileManager.default.fileExists(atPath: cache.appendingPathComponent("programs-verified").path))
        // A program the cache got since is not one the page was read with.
        try FileManager.default.createDirectory(at: cache.appendingPathComponent("26A428/9A9A"), withIntermediateDirectories: true)
        #expect(!E5Programs.isVerified(bundleID: id, in: root, osBuild: "26A428", build: "100"))
    }

    @Test func aCacheCompiledAgainIsNotTheOneThatWasRead() throws {
        let root = try caches(), id = "dev.midagedev.mwoyeo.reader.lines"
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try makeCache(root, id)
        E5Programs.markVerified(bundleID: id, in: root, osBuild: "26A428", build: "100")
        // Whatever drops the cache (the user, the system) leaves the mark where it was; the programs that come after have other births.
        try FileManager.default.removeItem(at: cache)
        #expect(!E5Programs.isVerified(bundleID: id, in: root, osBuild: "26A428", build: "100"), "no programs, nothing read")
        _ = try makeCache(root, id, born: 2_000)
        #expect(!E5Programs.isVerified(bundleID: id, in: root, osBuild: "26A428", build: "100"))
    }

    @Test func aResetDropsTheMarkToo() throws {
        let root = try caches(), id = "dev.midagedev.mwoyeo.reader.lines"
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeCache(root, id)
        E5Programs.markVerified(bundleID: id, in: root, osBuild: "26A428", build: "100")
        E5Programs.reset(bundleID: id, in: root, osBuild: "26A428")
        _ = try makeCache(root, id)   // compiled again, with the very same birth
        #expect(!E5Programs.isVerified(bundleID: id, in: root, osBuild: "26A428", build: "100"))
    }

    @Test func aMarkWithNoCacheIsNotWritten() throws {
        let root = try caches()
        defer { try? FileManager.default.removeItem(at: root) }
        E5Programs.markVerified(bundleID: "x", in: root, osBuild: "26A428", build: "1")
        #expect(!E5Programs.isVerified(bundleID: "x", in: root, osBuild: "26A428", build: "1"))
    }
}
