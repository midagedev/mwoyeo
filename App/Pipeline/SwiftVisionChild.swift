import Foundation
import MwoyeoCore
import Vision

/// Compiles a Swift Vision model (`RecognizeDocumentsRequest`, `RecognizeTextRequest`) in a child process, so that reading in
/// the app process never waits for the compile. Measured (vision-revive2 G0): in one process, while a Swift model compiled
/// cold, a warm VN revision 3 read waited 37 s (0.23 s otherwise); the same read in another process answered in 0.3 s. The
/// compile cache is the system's, shared by the same app (bundle ID), so the app's own load of the model afterwards is quick.
/// The child is this app's own executable with `--warm-vision <step> <key>` (`Entry`); in the App Sandbox a child of the
/// app's own executable inherits the sandbox. Never killed while it loads: a client that goes away restarts the system's compile.
enum SwiftVisionChild {
    enum Outcome: Equatable {
        /// The child loaded the model and exited 0: the model is in the system's cache.
        case loaded
        /// The child ran and did not succeed (its exit status).
        case failed(String)
        /// No child could be started: the caller loads the model in its own process, as before.
        case unavailable
    }

    /// The pid of the child that is running, nil if none.
    nonisolated(unsafe) private(set) static var pid: Int32?
    private static let lock = NSLock()

    /// Runs the child for `step` (a Swift step) of `key` and returns when it has exited, however long that takes.
    static func run(step: SwiftVisionGate.Step, key: String) async -> Outcome {
        // `MWOYEO_OCR_CHILD=off`: no child, the model is loaded in this process (the order before the child, for the gate that
        // contrasts the two).
        guard let executable = Bundle.main.executableURL, ProcessInfo.processInfo.environment["MWOYEO_OCR_CHILD"] != "off" else { return .unavailable }
        return await withCheckedContinuation { (done: CheckedContinuation<Outcome, Never>) in
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--warm-vision", step.rawValue, key]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { ended in
                lock.withLock { if pid == ended.processIdentifier { pid = nil } }
                let ok = ended.terminationReason == .exit && ended.terminationStatus == 0
                done.resume(returning: ok ? .loaded : .failed("the helper process ended with status \(ended.terminationStatus)"))
            }
            do {
                // The lock is also taken by the termination handler, which therefore waits until the pid is recorded.
                try lock.withLock { try process.run(); pid = process.processIdentifier }
            } catch {
                done.resume(returning: .unavailable)
            }
        }
    }

    // MARK: The child (`Mwoyeo --warm-vision <step> <key>`)

    /// Loads the model of `step` for `key` on a small drawn picture and exits 0, or 1 if it fails. No window, no permissions.
    /// `MWOYEO_FAKE_OCR=slow-child:<ms>` waits first, `fail-child` fails at once (to exercise the parent on a Mac whose
    /// models compile slowly or not at all).
    static func runChild(step: String, key: String) -> Never {
        Task.detached {
            let fake = ProcessInfo.processInfo.environment["MWOYEO_FAKE_OCR"]
            if fake == "fail-child" { exit(1) }
            if let fake, fake.hasPrefix("slow-child:"), let ms = Int(fake.dropFirst(11)) {
                try? await Task.sleep(for: .milliseconds(ms))
            }
            do {
                try await TextRecognizer.loadSwiftModel(step: SwiftVisionGate.Step(rawValue: step) ?? .documentModel, key: key)
                exit(0)
            } catch {
                FileHandle.standardError.write("warm-vision: \(error)\n".data(using: .utf8)!)
                exit(1)
            }
        }
        RunLoop.main.run()
        exit(0)
    }
}
