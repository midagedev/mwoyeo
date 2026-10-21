import Foundation

/// The verdict on the programs a Lines service compiled, from one read of a page it draws (`VisionExec.checkPicture`), and what is
/// done about bad ones.
///
/// Vision's programs are compiled once into the service's e5rt bundle cache, and a compile can go wrong without any error: on
/// 2026-10-21 one of about fifteen cold compiles here (a standalone tool, same binary, same picture) left a cache whose every later process
/// answered a still page of 26 lines with 22. The four lines it left out were the ones in a band of widths (the page's widest, 25 to 33
/// times their height), at revision 2 and at `.fast` too (the detector is shared), with no failure, no low confidence and no trace.
/// A fresh compile of the same binary read all 26; the old cache again read 22, process after process. film3's lens dropped the
/// middle line of a paragraph for an hour on such a cache (D4). Nothing in an answer says so; a drawn page with a line of every
/// width does: the good caches read all 33 lines of it (7 caches, 14 reads), the bad one 25.
///
/// The service reads the page once after its programs were compiled. When lines are missing it drops the cache, exits, and the
/// restarted service compiles again (the host treats an exit like a crash: it restarts the service and reads again). A second
/// bad compile in a row is about 1 in 225 here, a third 1 in 3,400: after `resets` resets the service serves what it has and says so in the log.
public enum ProgramCheck {
    /// How many of the drawn lines an answer of good programs may lack. Good caches lacked none; the bad one lacked 8 (a quarter of
    /// the page); 3 is a spare for a line that a future system reads as two or leaves out, with 5 under the bad cache's loss.
    public static let tolerated = 3

    /// How many times in a row a service drops its cache for a bad read of the page. Each is a compile (a minute on a cold cache).
    public static let resets = 2

    public enum Verdict: Equatable, Sendable {
        /// The programs read the page.
        case good
        /// They do not, and the cache has not been dropped `resets` times yet: drop it and compile again.
        case reset
        /// They do not, and compiling again did not help (`resets` times): serve what there is.
        case stillBad
    }

    /// `read` of the `drawn` lines came back; the cache was dropped `resetsSoFar` times before.
    public static func verdict(drawn: Int, read: Int, resetsSoFar: Int) -> Verdict {
        if read + tolerated >= drawn { return .good }
        return resetsSoFar < resets ? .reset : .stillBad
    }
}

/// Where a service's compiled programs are, and the two marks it keeps beside them (not in them: the system clears what it did not
/// write from its cache directory, measured 2026-10-21): how many times it dropped them, and which programs of which build of the
/// service on which system were read once and found good (so that the page is drawn once per cache, not once per launch).
public enum E5Programs {
    static let directoryName = "com.apple.e5rt.e5bundlecache"

    /// The caches of the process with this bundle identifier: the system makes `<Caches>/<id>/com.apple.e5rt.e5bundlecache` for a
    /// process outside the sandbox and, it is presumed (not measured: the App Store build was not run for this), `<Caches>/com.apple.e5rt.e5bundlecache`
    /// inside it, where `Caches` is already the container's.
    public static func caches(bundleID: String, in caches: URL) -> [URL] {
        [caches.appendingPathComponent(bundleID).appendingPathComponent(directoryName), caches.appendingPathComponent(directoryName)]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// How many times in a row the programs were dropped on this system build (`osBuild`): a read that found them good starts the count over.
    public static func resetsSoFar(bundleID: String, in caches: URL, osBuild: String) -> Int {
        (try? String(contentsOf: resetMark(bundleID, caches, osBuild), encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
    }

    /// Drops the programs and counts it. False when there was nothing to drop (the cache is somewhere this does not know): the
    /// caller does not exit for a reset that cannot happen.
    @discardableResult
    public static func reset(bundleID: String, in caches: URL, osBuild: String) -> Bool {
        let found = Self.caches(bundleID: bundleID, in: caches)
        guard !found.isEmpty else { return false }
        let mark = resetMark(bundleID, caches, osBuild)
        let count = resetsSoFar(bundleID: bundleID, in: caches, osBuild: osBuild) + 1
        try? FileManager.default.createDirectory(at: mark.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? String(count).write(to: mark, atomically: true, encoding: .utf8)) != nil else { return false }
        for url in found { try? FileManager.default.removeItem(at: url) }
        try? FileManager.default.removeItem(at: verifiedMark(bundleID, caches))
        return true
    }

    /// The programs in the cache now: the name and the birth of each directory the system made for a compiled program. A cache that
    /// was dropped and compiled again, or one that got a program since, is another list. Nil with no program in it.
    static func programs(bundleID: String, in caches: URL) -> String? {
        let fm = FileManager.default
        var found: [String] = []
        for cache in Self.caches(bundleID: bundleID, in: caches) {
            for system in (try? fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? [] {
                for program in (try? fm.contentsOfDirectory(at: system, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
                    let born = (try? program.resourceValues(forKeys: [.creationDateKey]).creationDate)?.timeIntervalSince1970 ?? 0
                    found.append("\(program.lastPathComponent)@\(born)")
                }
            }
        }
        return found.isEmpty ? nil : found.sorted().joined(separator: ",")
    }

    /// The programs now in the cache were read once, by this build of the service (`build`: dev builds change it with every compile)
    /// on this system, and found good.
    public static func isVerified(bundleID: String, in caches: URL, osBuild: String, build: String) -> Bool {
        guard let programs = programs(bundleID: bundleID, in: caches) else { return false }
        return (try? String(contentsOf: verifiedMark(bundleID, caches), encoding: .utf8)) == "\(osBuild) \(build) \(programs)"
    }

    /// Writes the mark for the programs now in the cache. They read well, so the count of resets starts over: `resets` is how many
    /// bad compiles in a row a service drops, not in its life.
    public static func markVerified(bundleID: String, in caches: URL, osBuild: String, build: String) {
        guard let programs = programs(bundleID: bundleID, in: caches) else { return }
        let mark = verifiedMark(bundleID, caches)
        try? FileManager.default.createDirectory(at: mark.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "\(osBuild) \(build) \(programs)".write(to: mark, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: resetMark(bundleID, caches, osBuild))
    }

    private static func resetMark(_ bundleID: String, _ caches: URL, _ osBuild: String) -> URL {
        caches.appendingPathComponent(bundleID).appendingPathComponent("programs-reset-\(osBuild)")
    }

    private static func verifiedMark(_ bundleID: String, _ caches: URL) -> URL {
        caches.appendingPathComponent(bundleID).appendingPathComponent("programs-verified")
    }
}
