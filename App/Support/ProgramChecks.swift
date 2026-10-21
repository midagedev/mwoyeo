#if !MAS
import CoreGraphics
import Foundation
import MwoyeoCore

/// The check of the Lines programs of this run (round d4root, 2026-10-21), run by `--capture-ui … check-logic` and alone by
/// `program-checks` (PASS/FAIL lines): the page the service draws to read its own programs (`ProgramCheck`) read through the host, as a
/// lens reads. A cache of programs that leaves a band of widths out of every answer (one cold compile in about fifteen here, D4) is no error
/// anywhere else; here it is a FAIL, before it spoils a gate: drop `~/Library/Caches/<id>.reader.lines/com.apple.e5rt.e5bundlecache`
/// (the service does it for its own cache the first time it reads the page, `ReaderWorker.verifyPrograms`).
enum ProgramChecks {
    static func run() async -> Int {
        var failed = 0
        func check(_ what: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            print("check-logic: \(ok ? "PASS" : "FAIL") programs: \(what)" + (ok ? "" : " [\(detail())]"))
            if !ok { failed += 1 }
        }
        guard let page = VisionExec.checkPicture else { check("the check page is drawn", false); return failed + 1 }
        let drawn = VisionExec.checkLines
        check("the check page has a line for each of three sizes and eleven widths", drawn == 33, "\(drawn)")
        check("it is a screen wide", page.width == 1920, "\(page.width)")
        // Through the host and a service, as a lens reads (the language detected, the whole picture).
        let read: Int
        do { read = try await TextRecognizer.lines(in: page, languages: [], fast: false).count } catch { read = -1 }
        check("a Lines service reads the page (\(read) of \(drawn) lines)", read + ProgramCheck.tolerated >= drawn,
              "\(read) of \(drawn): the programs of this id leave lines out; drop its com.apple.e5rt.e5bundlecache")
        return failed
    }
}
#endif
