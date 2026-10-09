import Foundation

/// One conversion of a file on the Mac, as the Convert screen shows it.
public struct Conversion: Identifiable, Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case running, done, failed, cancelled

        public var label: String {
            switch self {
            case .running: return Messages.convertStateRunning
            case .done: return Messages.convertStateDone
            case .failed: return Messages.convertStateFailed
            case .cancelled: return Messages.convertStateCancelled
            }
        }
    }

    public let id: UUID
    /// The original file's name.
    public let title: String
    /// What is being made of it ("MP4 copy").
    public let detail: String
    public let input: String
    public let output: String
    /// Whether to tell the person when it finishes. A copy made on the way to
    /// something else (Send to iPhone) is not announced.
    public let announce: Bool
    public var progress: Double = 0
    public var status: String
    /// The converter's own last words when it failed, for the curious.
    public var toolSays = ""
    public var state = State.running
}

/// Runs conversions (plan Rule 2: `FFmpegPlanner` plans, this runs). The
/// original is never touched: a plan names a new file, and a conversion that
/// fails or is cancelled removes only that new file.
public actor ConvertCenter {
    private let tools: @Sendable () -> ToolRegistry
    private let library: LibraryRepository?
    private let runner: ProcessRunner
    private var items: [Conversion] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var watchers: [UUID: AsyncStream<[Conversion]>.Continuation] = [:]

    public init(tools: @escaping @Sendable () -> ToolRegistry, library: LibraryRepository? = nil, runner: ProcessRunner = ProcessRunner()) {
        self.tools = tools
        self.library = library
        self.runner = runner
    }

    // MARK: What the screen reads

    /// Newest first.
    public func snapshot() -> [Conversion] { items }

    public var hasRunning: Bool { items.contains { $0.state == .running } }

    /// The list now, and again whenever it changes.
    public func updates() -> AsyncStream<[Conversion]> {
        let id = UUID()
        return AsyncStream { continuation in
            watchers[id] = continuation
            continuation.yield(items)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.dropWatcher(id) }
            }
        }
    }

    private func dropWatcher(_ id: UUID) { watchers[id] = nil }

    private func publish() {
        for watcher in watchers.values { watcher.yield(items) }
    }

    private func change(_ id: UUID, _ edit: (inout Conversion) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        edit(&items[index])
        publish()
    }

    // MARK: What the screen asks for

    /// Starts a conversion. `mustBeSmaller` is for a shrink: a copy that
    /// comes out no smaller than the original is removed and reported.
    @discardableResult
    public func start(_ plan: FFmpegPlanner.Plan, input: String, label: String, mustBeSmaller: Bool = false,
                      announce: Bool = true) -> UUID {
        let item = Conversion(id: UUID(), title: (input as NSString).lastPathComponent, detail: label, input: input,
                              output: plan.output, announce: announce,
                              status: plan.copiesOnly ? Messages.convertRepackaging : Messages.convertStarting)
        items.insert(item, at: 0)
        publish()
        let id = item.id
        tasks[id] = Task { [weak self] in
            await self?.perform(id, plan: plan, input: input, label: label, mustBeSmaller: mustBeSmaller)
        }
        return id
    }

    /// Waits for a conversion to end. The new file's path when it worked, nil otherwise.
    public func result(of id: UUID) async -> String? {
        await tasks[id]?.value
        guard let item = items.first(where: { $0.id == id }), item.state == .done else { return nil }
        return item.output
    }

    public func cancel(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), item.state == .running else { return }
        change(id) {
            $0.state = .cancelled
            $0.status = Messages.convertStateCancelled
        }
        tasks[id]?.cancel()
    }

    public func cancelAll() {
        for item in items where item.state == .running { cancel(item.id) }
    }

    public func clearFinished() {
        items.removeAll { $0.state != .running }
        publish()
    }

    /// Returns once no converter is running, so quitting never leaves one behind.
    public func idle() async {
        for task in tasks.values { await task.value }
    }

    // MARK: Running

    private func isCancelled(_ id: UUID) -> Bool {
        items.first { $0.id == id }?.state != .running
    }

    private func setProgress(_ id: UUID, _ percent: Int) {
        guard !isCancelled(id) else { return }
        change(id) {
            $0.progress = Double(percent) / 100
            $0.status = "\(percent)%"
        }
    }

    private func fail(_ id: UUID, _ sentence: String, toolSays: String = "") {
        change(id) {
            $0.state = .failed
            $0.status = sentence
            $0.toolSays = toolSays
        }
    }

    private func perform(_ id: UUID, plan: FFmpegPlanner.Plan, input: String, label: String, mustBeSmaller: Bool) async {
        defer { tasks[id] = nil }
        let registry = tools()
        guard let ffmpeg = registry.path(.ffmpeg) else { return fail(id, Messages.noConverter) }
        // The plan chose a name nothing had. If something took it since, leave that file alone.
        guard !FileManager.default.fileExists(atPath: plan.output) else { return fail(id, Messages.convertNameTaken) }
        let environment = registry.environment()
        // The new file is this conversion's own; nothing else is ever removed.
        func discard() { try? FileManager.default.removeItem(atPath: plan.output) }

        var ran = await run(id, ffmpeg, plan.arguments, duration: plan.outputDuration, environment: environment)
        if ran?.succeeded != true, !isCancelled(id), let second = plan.fallback {
            // The first kind of encoder refused; the other kind takes over.
            discard()
            ran = await run(id, ffmpeg, second, duration: plan.outputDuration, environment: environment)
        }
        if isCancelled(id) { return discard() }
        guard let ran, ran.succeeded, FileInspector.size(of: plan.output) > 0 else {
            discard()
            return fail(id, ran == nil ? Messages.noConverter : Messages.convertFailed, toolSays: ran?.lastError ?? "")
        }
        let before = FileInspector.size(of: input)
        if mustBeSmaller, before > 0, FileInspector.size(of: plan.output) >= before {
            discard()
            return fail(id, Messages.convertNoSmaller)
        }
        await library?.addCopy(of: input, at: plan.output, label: label)
        change(id) {
            $0.state = .done
            $0.progress = 1
            $0.status = Messages.convertSaved((plan.output as NSString).lastPathComponent,
                                              in: Naming.breadcrumb((plan.output as NSString).deletingLastPathComponent))
        }
    }

    private struct Ran {
        var succeeded: Bool
        var lastError: String
    }

    private final class Errors: @unchecked Sendable {
        private let lock = NSLock()
        private var last = ""
        private var percent = -1
        func note(_ line: String) {
            guard !line.trimmed.isEmpty else { return }
            lock.lock(); last = line; lock.unlock()
        }
        var lastLine: String { lock.lock(); defer { lock.unlock() }; return last }
        /// Each percentage once.
        func changed(to new: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard new != percent else { return false }
            percent = new
            return true
        }
    }

    /// Runs the converter to its end. Cancelling the task stops it. Nil when it could not be started.
    private func run(_ id: UUID, _ ffmpeg: String, _ arguments: [String], duration: Double,
                     environment: [String: String]) async -> Ran? {
        let notes = Errors()
        let request = ProcessRequest(executable: ffmpeg, arguments: arguments, environment: environment)
        guard let running = try? runner.start(request, maxLineLength: JobLog.maxLineLength, onLine: { [weak self] line in
            guard line.source == .standardOutput else { return notes.note(line.text) }
            guard duration > 0, let done = FFmpegPlanner.progressSeconds(line: line.text) else { return }
            let percent = Int(min(max(done / duration, 0), 1) * 100)
            if notes.changed(to: percent) { Task { await self?.setProgress(id, percent) } }
        }) else { return nil }
        let outcome = await withTaskCancellationHandler {
            await running.waitUntilExit()
        } onCancel: {
            running.stop()
        }
        return Ran(succeeded: outcome.succeeded && !outcome.stopRequested, lastError: notes.lastLine)
    }
}
