import CoreGraphics
import Foundation
import MwoyeoCore
import Vision
import os

/// Keeps the Swift Vision text models (`RecognizeTextRequest`, `RecognizeDocumentsRequest`) out of the app process until a
/// child process has loaded them. A Swift request that is still loading its model (on macOS 27 a compile of up to a minute
/// per language, or one that crawls under load) blocks every accurate `VNRecognizeTextRequest` in the same process, so one
/// pending request silences the fallback ladder too; the same request in another process answers in 0.3 s. The child is this
/// app's own executable with `--warm-vision <key>`; once it has exited 0 the load of that key in this process is quick.
/// `TextRecognizer` reads through `VNRecognizeTextRequest` until then. A key is a language set, as in `SwiftVisionGate`.
/// (Sandbox, for the App Store build: a child process inherits the app's sandbox, and spawning the app's own executable
/// is allowed.)
enum SwiftVisionWarm {
    private static let gate = OSAllocatedUnfairLock(initialState: SwiftVisionGate())
    private static let retryArmed = OSAllocatedUnfairLock(initialState: false)
    /// The running child: held until its termination handler has reaped it.
    private static let child = OSAllocatedUnfairLock<Process?>(initialState: nil)
    private static let log = Logger(subsystem: "dev.midagedev.mwoyeo", category: "ocr")

    /// The key for reads in these languages (empty: detect).
    static func key(_ languages: [Locale.Language]) -> String {
        let codes = languages.compactMap(TextRecognizer.code)
        return codes.isEmpty ? SwiftVisionGate.anyLanguage : codes.joined(separator: ",")
    }

    /// The Swift models of `key` have been loaded by a child (or `assumeReady` was called): they may be asked in this process.
    static func isReady(_ key: String) -> Bool { gate.withLock { $0.isReady(key) } }

    /// The ready keys at the moment, for the self-test's report.
    static var readyKeys: [String] { gate.withLock { $0.readyKeys } }

    /// The pid of the child that is running, nil if none.
    static var childPID: Int32? { child.withLock { $0?.processIdentifier } }

    /// How long `key` has been waited for (since its child first started), nil once ready or before any start.
    static func waiting(_ key: String, now: TimeInterval) -> TimeInterval? { gate.withLock { $0.waiting(key, now: now) } }

    /// For gates that want the Swift path at once (`--assume-vision-ready`): no child is started.
    static func assumeReady() { gate.withLock { $0.assumeReady() } }

    /// The Swift models of `key` are wanted: a child loads them when none is running (one at a time, in the order asked for),
    /// and again every `SwiftVisionGate.retryEvery` if it did not succeed. Never kills a child: a client that goes away
    /// restarts the system's compile. Cheap to call on every read.
    static func need(_ key: String) {
        let first = gate.withLock { g -> Bool in
            guard !g.isReady(key) else { return false }
            g.want(key)
            return true
        }
        if first { pump() }
    }

    /// Starts the child for the next key that is due, and makes sure someone looks again if some key is still not ready.
    private static func pump() {
        let key = gate.withLock { g -> String? in
            guard let key = g.nextDue(now: Trace.now) else { return nil }
            // Before the process runs: it can end before `run()` has returned.
            g.started(key, now: Trace.now)
            return key
        }
        if let key { launch(key) }
        guard !gate.withLock({ $0.allReady }), !retryArmed.withLock({ let was = $0; $0 = true; return was }) else { return }
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(SwiftVisionGate.retryEvery))
            retryArmed.withLock { $0 = false }
            pump()
        }
    }

    private static func launch(_ key: String) {
        guard let executable = Bundle.main.executableURL else {
            _ = gate.withLock { $0.ended(success: false) }
            return
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--warm-vision", key]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { done in
            let ok = done.terminationReason == .exit && done.terminationStatus == 0
            let loaded = gate.withLock { $0.ended(success: ok) }
            child.withLock { if $0?.processIdentifier == done.processIdentifier { $0 = nil } }
            log.info("Swift Vision child \(done.processIdentifier, privacy: .public) for \(key, privacy: .public) ended, status \(done.terminationStatus, privacy: .public)")
            if loaded != nil {
                Trace.count("ocr.swift.ready")
                // Loaded here too, so that the first real read does not pay for it.
                Task.detached(priority: .utility) { await TextRecognizer.preloadSwift(key: key) }
            }
            pump()
        }
        do {
            // The lock is also taken by the termination handler, which therefore waits until the child is recorded.
            try child.withLock { slot in try process.run(); slot = process }
        } catch {
            log.error("Swift Vision child did not start: \(String(describing: error), privacy: .public)")
            _ = gate.withLock { $0.ended(success: false) }
        }
    }

    // MARK: The child (`Mwoyeo --warm-vision <key>`)

    /// Loads both Swift requests for `key` on a small drawn picture and exits 0, or 1 if one fails. No window, no permissions.
    /// `MWOYEO_FAKE_OCR=slow-child:<ms>` waits first, `fail-child` fails at once (to exercise the parent on a Mac whose
    /// models compile slowly or not at all).
    static func runChild(key: String) -> Never {
        Task.detached {
            let fake = ProcessInfo.processInfo.environment["MWOYEO_FAKE_OCR"]
            if fake == "fail-child" { exit(1) }
            if let fake, fake.hasPrefix("slow-child:"), let ms = Int(fake.dropFirst(11)) {
                try? await Task.sleep(for: .milliseconds(ms))
            }
            exit(await loadModels(languages(of: key)) ? 0 : 1)
        }
        RunLoop.main.run()
        exit(0)
    }

    /// The languages a key stands for (empty: detect).
    static func languages(of key: String) -> [Locale.Language] {
        key == SwiftVisionGate.anyLanguage ? [] : key.split(separator: ",").map { Locale.Language(identifier: String($0)) }
    }

    /// The requests the app makes, with the languages of the key: a line read and a document read. Each is awaited for as
    /// long as it takes: this process has nothing else to do, and is never killed while it loads.
    private static func loadModels(_ languages: [Locale.Language]) async -> Bool {
        guard let picture = TextRecognizer.probePicture else { return false }
        do {
            var lines = RecognizeTextRequest()
            lines.recognitionLevel = .accurate
            var document = RecognizeDocumentsRequest()
            if languages.isEmpty {
                lines.automaticallyDetectsLanguage = true
                document.textRecognitionOptions.automaticallyDetectLanguage = true
            } else {
                lines.recognitionLanguages = languages
                document.textRecognitionOptions.recognitionLanguages = languages
            }
            _ = try await lines.perform(on: picture)
            _ = try await document.perform(on: picture)
            return true
        } catch {
            FileHandle.standardError.write("warm-vision: \(error)\n".data(using: .utf8)!)
            return false
        }
    }
}
