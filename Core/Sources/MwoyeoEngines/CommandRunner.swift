import Foundation
import MwoyeoCore

/// Runs a user's own program for a `.command` engine (protocol in `CommandEngine`).
///
/// No shell: the executable is started directly with the spec's arguments. A bare name is looked up in PATH. The child
/// gets only PATH, HOME and LANG, so it does not inherit the app's whole environment (a user's script has no business
/// seeing whatever else the app was launched with). stdout is read to EOF and capped at 1 MB; stderr keeps its last
/// 4 KB for the error. The child leads its own process group; on cancel the group gets SIGTERM, and SIGKILL one second later if any
/// member is still there (a grandchild holding stdout would otherwise keep the reader alive).
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
        /// The child, which is also its process group's id; nil before the spawn and after it is reaped.
        private var pid: pid_t?
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
            let p = pid, c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: .cancelled)
            if let p { stop(group: p) }
        }

        private func stop(group: pid_t) {
            killpg(group, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { killpg(group, SIGKILL) }
        }

        private func finish(_ outcome: Outcome) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: outcome)
        }

        /// A pipe whose ends close on exec (the child's own copies are made by `dup2`, which clears the flag).
        private static func pipe() -> (read: Int32, write: Int32)? {
            var fds: [Int32] = [0, 0]
            guard Darwin.pipe(&fds) == 0 else { return nil }
            for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
            return (fds[0], fds[1])
        }

        /// Starts the program as the leader of a new process group; stdin, stdout and stderr are the given pipe ends.
        private func spawn(_ executable: String, env: [String: String], stdin: Int32, stdout: Int32, stderr: Int32) -> pid_t? {
            var actions: posix_spawn_file_actions_t?
            var attrs: posix_spawnattr_t?
            posix_spawn_file_actions_init(&actions)
            posix_spawnattr_init(&attrs)
            defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attrs) }
            posix_spawn_file_actions_adddup2(&actions, stdin, 0)
            posix_spawn_file_actions_adddup2(&actions, stdout, 1)
            posix_spawn_file_actions_adddup2(&actions, stderr, 2)
            posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP))
            posix_spawnattr_setpgroup(&attrs, 0)
            let argv = ([executable] + spec.arguments).map { strdup($0) } + [nil]
            let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer { for p in argv + envp { free(p) } }
            var child: pid_t = 0
            return posix_spawn(&child, executable, &actions, &attrs, argv, envp) == 0 ? child : nil
        }

        private func work() {
            guard let executable = CommandRunner.resolve(spec.executable) else {
                return finish(.failed("command not found: \(spec.executable)"))
            }
            let env = ProcessInfo.processInfo.environment
            let childEnv = ["PATH": CommandRunner.searchPath.joined(separator: ":"),
                            "HOME": env["HOME"] ?? NSHomeDirectory(), "LANG": env["LANG"] ?? "en_US.UTF-8"]
            guard let stdin = Self.pipe(), let stdout = Self.pipe(), let stderr = Self.pipe() else {
                return finish(.failed("could not start \(spec.executable)"))
            }
            // A child that exits without reading its stdin must not kill us with SIGPIPE.
            signal(SIGPIPE, SIG_IGN)

            lock.lock()
            if cancelled { lock.unlock(); for fd in [stdin.read, stdin.write, stdout.read, stdout.write, stderr.read, stderr.write] { close(fd) }; return }
            // Spawned under the lock, so a cancel sees either no child yet or the child's pid.
            let spawned = spawn(executable, env: childEnv, stdin: stdin.read, stdout: stdout.write, stderr: stderr.write)
            pid = spawned
            lock.unlock()
            close(stdin.read); close(stdout.write); close(stderr.write)
            guard let child = spawned else {
                close(stdin.write); close(stdout.read); close(stderr.read)
                return finish(.failed("could not start \(spec.executable)"))
            }

            let stdinHandle = FileHandle(fileDescriptor: stdin.write, closeOnDealloc: true)
            let stdoutHandle = FileHandle(fileDescriptor: stdout.read, closeOnDealloc: true)
            let stderrHandle = FileHandle(fileDescriptor: stderr.read, closeOnDealloc: true)
            let payload = input
            DispatchQueue.global().async {
                try? stdinHandle.write(contentsOf: payload)
                try? stdinHandle.close()
            }
            let group = DispatchGroup()
            let tail = TailBox()
            group.enter()
            DispatchQueue.global().async {
                while let d = try? stderrHandle.read(upToCount: 4096), !d.isEmpty { tail.append(d) }
                group.leave()
            }

            var out = Data()
            var overflow = false
            while let d = try? stdoutHandle.read(upToCount: 65536), !d.isEmpty {
                out.append(d)
                if out.count > CommandRunner.maxOutput {
                    overflow = true
                    stop(group: child)
                    break
                }
            }
            group.wait()
            var status: Int32 = 0
            while waitpid(child, &status, 0) < 0 && errno == EINTR {}
            lock.withLock { pid = nil }
            if overflow { return finish(.failed("output is larger than 1 MB")) }
            let exited = (status & 0x7f) == 0
            let code = (status >> 8) & 0xff
            guard exited && code == 0 else {
                let text = String(decoding: tail.data, as: UTF8.self)
                return finish(.failed(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      ? (exited ? "exit status \(code)" : "terminated by signal \(status & 0x7f)") : text))
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
