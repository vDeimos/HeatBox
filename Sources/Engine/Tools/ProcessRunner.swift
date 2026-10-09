import Foundation

/// Everything needed to run one tool. There is no shell: the executable is an
/// absolute path and the arguments are a list. The environment is given in
/// full (see `ToolRegistry.environment`); nothing is inherited.
public struct ProcessRequest: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?

    public init(executable: String, arguments: [String], environment: [String: String], workingDirectory: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

public enum OutputSource: Sendable, Equatable {
    case standardOutput
    case standardError
}

public struct ProcessLine: Sendable, Equatable {
    public let text: String
    public let source: OutputSource

    public init(text: String, source: OutputSource) {
        self.text = text
        self.source = source
    }
}

/// How a process ended.
public struct ProcessOutcome: Sendable, Equatable {
    /// The exit code, or the signal number when `signalled` is true.
    public let status: Int32
    /// True when a signal ended the process rather than its own exit.
    public let signalled: Bool
    /// True when `stop()` was called before the process ended.
    public let stopRequested: Bool

    public var succeeded: Bool { !signalled && status == 0 }
}

/// A finished short-lived run with all of its output.
public struct CapturedOutput: Sendable, Equatable {
    public let outcome: ProcessOutcome
    /// Lines joined with `\n`.
    public let standardOutput: String
    public let standardError: String
}

public enum ProcessError: Error, Equatable {
    /// The executable was not an absolute path. Tools are never looked up by name.
    case executableNotAbsolute(String)
    case launchFailed(String)
}

/// The one way the engine runs a tool (plan Rule 3): argument list, fixed
/// executable path, explicit environment, stdin closed, lines split on `\n`
/// and `\r`, and a stop that escalates SIGINT → SIGTERM → SIGKILL.
///
/// Every tool is started in a process group of its own, so that a stop
/// reaches the programs the tool started too (yt-dlp's FFmpeg) and none of
/// them can be left running.
public struct ProcessRunner: Sendable {
    /// How long each signal is given before the next, stronger one.
    public var stopGrace: TimeInterval
    /// How long to wait for output after the process has exited. A tool can
    /// leave a child behind that keeps the pipe open; this bounds the wait.
    public var drainTimeout: TimeInterval

    public init(stopGrace: TimeInterval = 2, drainTimeout: TimeInterval = 2) {
        self.stopGrace = stopGrace
        self.drainTimeout = drainTimeout
    }

    /// Starts a tool. `onLine` is called for each line, in order, on a private
    /// serial queue; every line has been delivered before `waitUntilExit` returns.
    /// A line longer than `maxLineLength` bytes is cut short (see `LineSplitter`).
    public func start(_ request: ProcessRequest, maxLineLength: Int? = nil,
                      onLine: @escaping @Sendable (ProcessLine) -> Void) throws -> RunningProcess {
        guard request.executable.hasPrefix("/") else {
            throw ProcessError.executableNotAbsolute(request.executable)
        }
        let running = RunningProcess(stopGrace: stopGrace, drainTimeout: drainTimeout,
                                     maxLineLength: maxLineLength, onLine: onLine)
        try running.launch(request)
        return running
    }

    /// Runs a short-lived tool and collects its output. Cancelling the task stops the tool.
    public func run(_ request: ProcessRequest) async throws -> CapturedOutput {
        let collected = CollectedLines()
        let running = try start(request) { collected.add($0) }
        let outcome = await withTaskCancellationHandler {
            await running.waitUntilExit()
        } onCancel: {
            running.stop()
        }
        let lines = collected.all()
        func text(_ source: OutputSource) -> String {
            lines.filter { $0.source == source }.map(\.text).joined(separator: "\n")
        }
        return CapturedOutput(outcome: outcome, standardOutput: text(.standardOutput), standardError: text(.standardError))
    }
}

/// A tool that has been started.
public final class RunningProcess: @unchecked Sendable {
    private let queue = DispatchQueue(label: "engine.process-runner")
    private let stopGrace: TimeInterval
    private let drainTimeout: TimeInterval
    private let onLine: @Sendable (ProcessLine) -> Void

    // Touched only on `queue`.
    private var outSplitter: LineSplitter
    private var errSplitter: LineSplitter
    private var delivering = true

    // Guarded by `lock`.
    private let lock = NSLock()
    private var pid: pid_t = 0
    /// The tool itself has ended. Its id is only signalled while this is false,
    /// so a signal can never reach an unrelated process that was given the id later.
    private var exited = false
    private var outcome: ProcessOutcome?
    private var waiters: [CheckedContinuation<ProcessOutcome, Never>] = []
    private var stopRequested = false

    fileprivate init(stopGrace: TimeInterval, drainTimeout: TimeInterval, maxLineLength: Int?,
                     onLine: @escaping @Sendable (ProcessLine) -> Void) {
        self.stopGrace = stopGrace
        self.drainTimeout = drainTimeout
        self.onLine = onLine
        outSplitter = LineSplitter(maxLineLength: maxLineLength)
        errSplitter = LineSplitter(maxLineLength: maxLineLength)
    }

    /// The tool's process id, which is also the id of its process group.
    public var processIdentifier: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return pid
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pid != 0 && !exited
    }

    fileprivate func launch(_ request: ProcessRequest) throws {
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { throw ProcessError.launchFailed(Self.describe(errno)) }
        guard pipe(&errPipe) == 0 else {
            let code = errno
            close(outPipe[0]); close(outPipe[1])
            throw ProcessError.launchFailed(Self.describe(code))
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // Tools must never wait on the keyboard.
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO)
        if let directory = request.workingDirectory {
            posix_spawn_file_actions_addchdir_np(&actions, directory)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A process group of its own; no file of the app's left open in the
        // tool; signals as a freshly started program expects them.
        posix_spawnattr_setpgroup(&attributes, 0)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                       | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))

        let argv: [UnsafeMutablePointer<CChar>?] = ([request.executable] + request.arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = request.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var child: pid_t = 0
        let code = posix_spawn(&child, request.executable, &actions, &attributes, argv, envp)
        close(outPipe[1])
        close(errPipe[1])
        guard code == 0 else {
            close(outPipe[0])
            close(errPipe[0])
            throw ProcessError.launchFailed(Self.describe(code))
        }
        lock.lock()
        pid = child
        lock.unlock()

        let out = FileHandle(fileDescriptor: outPipe[0], closeOnDealloc: true)
        let err = FileHandle(fileDescriptor: errPipe[0], closeOnDealloc: true)
        // Signalled once per stream when it reaches its end.
        let ended = DispatchSemaphore(value: 0)
        read(out, as: .standardOutput, ended: ended)
        read(err, as: .standardError, ended: ended)

        let drainTimeout = self.drainTimeout
        Thread.detachNewThread { [self] in
            let status = waitForExit(of: child)
            // The process is gone; wait for the rest of its output, but not
            // for ever, in case something that left its group still holds the pipe.
            let deadline = DispatchTime.now() + drainTimeout
            for _ in 0..<2 where ended.wait(timeout: deadline) == .timedOut {
                out.readabilityHandler = nil
                err.readabilityHandler = nil
                break
            }
            queue.async { [self] in
                if let tail = outSplitter.flush() { onLine(ProcessLine(text: tail, source: .standardOutput)) }
                if let tail = errSplitter.flush() { onLine(ProcessLine(text: tail, source: .standardError)) }
                delivering = false
                // 0 in the low seven bits means the process exited by itself; otherwise they name the signal.
                let signal = status & 0x7f
                finish(status: signal == 0 ? (status >> 8) & 0xff : signal, signalled: signal != 0)
            }
        }
    }

    /// Blocks until the tool has ended and returns its wait status. Anything
    /// the tool started and left running is stopped at the same moment, while
    /// the tool's id is still reserved and so cannot belong to anything else.
    private func waitForExit(of child: pid_t) -> Int32 {
        var info = siginfo_t()
        while waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
        lock.lock()
        defer { lock.unlock() }
        exited = true
        kill(-child, SIGKILL)
        var status: Int32 = 0
        while waitpid(child, &status, 0) == -1 && errno == EINTR {}
        return status
    }

    private func read(_ handle: FileHandle, as source: OutputSource, ended: DispatchSemaphore) {
        handle.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                queue.async { ended.signal() }
                return
            }
            queue.async { [self] in
                guard delivering else { return }
                let lines = source == .standardOutput ? outSplitter.append(data) : errSplitter.append(data)
                for line in lines { onLine(ProcessLine(text: line, source: source)) }
            }
        }
    }

    private func finish(status: Int32, signalled: Bool) {
        lock.lock()
        let result = ProcessOutcome(status: status, signalled: signalled, stopRequested: stopRequested)
        outcome = result
        let waiting = waiters
        waiters = []
        lock.unlock()
        for waiter in waiting { waiter.resume(returning: result) }
    }

    /// Waits for the process to end and for all of its output to be delivered.
    public func waitUntilExit() async -> ProcessOutcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(returning: outcome)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// Asks the tool to stop, then insists. SIGINT comes first, to the tool
    /// alone, so yt-dlp can stop its own FFmpeg children and tidy up; then
    /// SIGTERM and SIGKILL to the whole group, because FFmpeg treats the first
    /// two as "finish what you are doing", which can take minutes with a slow
    /// encoder. Safe to call more than once.
    public func stop() {
        lock.lock()
        let already = stopRequested || exited || pid == 0
        stopRequested = true
        lock.unlock()
        guard !already else { return }
        send(SIGINT, toGroup: false)
        DispatchQueue.global().asyncAfter(deadline: .now() + stopGrace) { [self] in
            send(SIGTERM, toGroup: true)
            DispatchQueue.global().asyncAfter(deadline: .now() + stopGrace) { [self] in
                send(SIGKILL, toGroup: true)
            }
        }
    }

    private func send(_ signal: Int32, toGroup: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard pid != 0, !exited else { return }
        kill(toGroup ? -pid : pid, signal)
    }

    private static func describe(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}

private final class CollectedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [ProcessLine] = []

    func add(_ line: ProcessLine) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func all() -> [ProcessLine] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
