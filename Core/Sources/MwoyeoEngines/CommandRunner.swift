import Foundation
import MwoyeoCore

/// Runs a user's own program for a `.command` engine (protocol in `CommandEngine`).
///
/// No shell: the executable is started directly with the spec's arguments. A bare name is looked up in PATH. The child
/// gets only PATH, HOME and LANG, so it does not inherit the app's whole environment (a user's script has no business
/// seeing whatever else the app was launched with). stdout is read to EOF and capped at 1 MB; stderr keeps its last
/// 4 KB for the error. On cancel the child gets SIGTERM, and SIGKILL one second later if it is still there.
enum CommandRunner {
    static let maxOutput = 1 << 20
    static let stderrTail = 4096
    /// A GUI app starts with a short PATH; these are where Homebrew and the system keep the usual interpreters.
    static let extraPath = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    /// The program's stdout for `input`; errors are `commandFailed` (launch, exit status, output size) or `cancelled`.
    static func run(_ spec: CommandSpec, input: Data, scrub: Scrubber) async throws(EngineError) -> Data {
        let job = Job(spec, input)
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Job.Outcome, Never>) in job.start(c) }
        } onCancel: {
            job.cancel()
        }
        switch outcome {
        case let .ok(data): return data
        case let .failed(message): throw .commandFailed(scrub(message))
        case .cancelled: throw .cancelled
        }
    }

    static var searchPath: [String] {
        var seen = Set<String>()
        let own = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return (own + extraPath).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func resolve(_ executable: String) -> String? {
        let fm = FileManager.default
        if executable.contains("/") {
            let path = (executable as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: path) ? path : nil
        }
        return searchPath.lazy.map { "\($0)/\(executable)" }.first { fm.isExecutableFile(atPath: $0) }
    }

    private final class Job: @unchecked Sendable {
        enum Outcome { case ok(Data), failed(String), cancelled }

        private let spec: CommandSpec
        private let input: Data
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        private var continuation: CheckedContinuation<Outcome, Never>?

        init(_ spec: CommandSpec, _ input: Data) {
            self.spec = spec
            self.input = input
        }

        func start(_ c: CheckedContinuation<Outcome, Never>) {
            lock.lock()
            if cancelled {
                lock.unlock()
                c.resume(returning: .cancelled)
                return
            }
            continuation = c
            lock.unlock()
            DispatchQueue.global().async { self.work() }
        }

        /// Resumes the caller at once; the worker thread reaps the child on its own.
        func cancel() {
            lock.lock()
            cancelled = true
            let p = process, c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: .cancelled)
            if let p { stop(p) }
        }

        private func stop(_ p: Process) {
            guard p.isRunning else { return }
            let pid = p.processIdentifier
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if p.isRunning { kill(pid, SIGKILL) } }
        }

        private func finish(_ outcome: Outcome) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: outcome)
        }

        private func work() {
            guard let executable = CommandRunner.resolve(spec.executable) else {
                return finish(.failed("command not found: \(spec.executable)"))
            }
            let env = ProcessInfo.processInfo.environment
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = spec.arguments
            p.environment = ["PATH": CommandRunner.searchPath.joined(separator: ":"),
                             "HOME": env["HOME"] ?? NSHomeDirectory(), "LANG": env["LANG"] ?? "en_US.UTF-8"]
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            p.standardInput = stdin
            p.standardOutput = stdout
            p.standardError = stderr

            lock.lock()
            if cancelled { lock.unlock(); return }
            process = p
            lock.unlock()
            do { try p.run() } catch { return finish(.failed("could not start \(spec.executable)")) }
            lock.lock()
            let late = cancelled
            lock.unlock()
            if late { stop(p) }

            // A child that exits without reading its stdin must not kill us with SIGPIPE.
            signal(SIGPIPE, SIG_IGN)
            let payload = input
            DispatchQueue.global().async {
                try? stdin.fileHandleForWriting.write(contentsOf: payload)
                try? stdin.fileHandleForWriting.close()
            }
            let group = DispatchGroup()
            let tail = TailBox()
            group.enter()
            DispatchQueue.global().async {
                while let d = try? stderr.fileHandleForReading.read(upToCount: 4096), !d.isEmpty { tail.append(d) }
                group.leave()
            }

            var out = Data()
            var overflow = false
            while let d = try? stdout.fileHandleForReading.read(upToCount: 65536), !d.isEmpty {
                out.append(d)
                if out.count > CommandRunner.maxOutput {
                    overflow = true
                    p.terminate()
                    break
                }
            }
            group.wait()
            p.waitUntilExit()
            if overflow { return finish(.failed("output is larger than 1 MB")) }
            guard p.terminationStatus == 0 else {
                let text = String(decoding: tail.data, as: UTF8.self)
                return finish(.failed(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      ? "exit status \(p.terminationStatus)" : text))
            }
            finish(.ok(out))
        }
    }

    private final class TailBox: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        func append(_ d: Data) {
            lock.withLock {
                buffer.append(d)
                if buffer.count > CommandRunner.stderrTail { buffer = buffer.suffix(CommandRunner.stderrTail) }
            }
        }
        var data: Data { lock.withLock { buffer } }
    }
}
