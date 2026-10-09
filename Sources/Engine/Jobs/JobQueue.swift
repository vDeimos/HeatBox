import Foundation

/// The defaults from Settings that the queue works with (plan Rule 6). The
/// app hands them over at launch and whenever the person changes one.
public struct QueueSettings: Equatable, Sendable {
    public static let concurrencyRange = 1...4

    /// How many jobs may run at once.
    public var maxConcurrent = 2
    /// Try again by itself after a failure that may pass.
    public var autoRetry = true
    /// Kilobytes per second; 0 means no limit. Applies from a job's next start.
    public var speedLimitKB = 0
    public var folders: FolderRules
    public var nameStyle = NameStyle.title
    public var cookiesFile: String?

    public init(folders: FolderRules = .standard()) {
        self.folders = folders
    }
}

/// The list of downloads and the rules for running them (an actor
/// that owns the state and publishes snapshots).
///
/// Jobs run oldest first, a few at a time. Nothing runs unless asked: a job
/// starts because the person added, resumed or retried it, or because the
/// time they chose has come. After a restart everything comes back paused,
/// except a download scheduled for a time that has not come yet.
public actor JobQueue {
    private enum StopReason {
        case pause, cancel
    }

    private let paths: AppPaths
    private let worker: any JobWorker
    private let clock: any EngineClock
    private let store: QueueStore
    private var settings: QueueSettings

    /// Oldest first.
    private var jobs: [Job] = []
    private var logs: [UUID: JobLog] = [:]
    /// One task per job that has a worker running, including one that is being stopped.
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var stopping: [UUID: StopReason] = [:]
    private var timer: Task<Void, Never>?
    private var timerDue: Date?
    private var watchers: [UUID: AsyncStream<[Job]>.Continuation] = [:]
    private var lastSaved: [SavedJob]?
    private var restored = false

    public init(paths: AppPaths, worker: any JobWorker, settings: QueueSettings = QueueSettings(),
                clock: any EngineClock = SystemClock()) {
        self.paths = paths
        self.worker = worker
        self.settings = settings
        self.clock = clock
        store = QueueStore(paths: paths)
    }

    // MARK: Launch and quit

    /// Call once at launch, before anything is added. Brings back the
    /// unfinished jobs from `queue.json` and puts the working folders in
    /// order: a tool left running by an earlier launch is stopped, a folder
    /// whose job came back is kept so the job can carry on from it, and every
    /// other folder is removed.
    @discardableResult
    public func restore() -> [Job] {
        guard !restored, tasks.isEmpty else { return jobs }
        restored = true
        try? paths.createFolders()
        let now = clock.now()
        let known = Set(jobs.map(\.id))
        let saved = store.load().map { $0.restored(now: now) }.filter { !known.contains($0.id) }
        jobs = (saved + jobs).sorted { $0.createdAt < $1.createdAt }
        Workspace.reconcile(paths: paths, keeping: Set(jobs.map(\.id)))
        settle()
        return jobs
    }

    /// For quitting: pauses what is running or waiting, keeps what is
    /// scheduled, writes the queue down, and returns once every tool has
    /// stopped. Nothing is deleted, so next time it carries on.
    public func prepareForQuit() async {
        for index in jobs.indices {
            switch jobs[index].state {
            case .lookingUp, .running:
                stop(jobs[index].id, because: .pause)
            case .waiting, .retrying:
                break
            default:
                continue
            }
            jobs[index].state = .paused
            jobs[index].message = Messages.pausedBecauseClosed
        }
        settle()
        await idle()
    }

    /// Returns once no tool is running for any job.
    public func idle() async {
        while let task = tasks.values.first {
            await task.value
        }
    }

    // MARK: Reading

    public func snapshot() -> [Job] { jobs }

    public func job(_ id: UUID) -> Job? {
        jobs.first { $0.id == id }
    }

    public func log(for id: UUID) -> JobLog {
        logs[id] ?? JobLog()
    }

    public func currentSettings() -> QueueSettings { settings }

    /// The list, now and after every change. Only the newest is kept for a
    /// reader that falls behind.
    public func updates() -> AsyncStream<[Job]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<[Job]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        watchers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.forget(watcher: id) }
        }
        continuation.yield(jobs)
        return stream
    }

    private func forget(watcher id: UUID) {
        watchers[id] = nil
    }

    // MARK: Adding

    @discardableResult
    public func add(_ requests: [JobRequest]) -> [UUID] {
        var ids: [UUID] = []
        var now = clock.now()
        for request in requests {
            // Jobs added together keep their order.
            if let last = jobs.last, last.createdAt >= now { now = last.createdAt.addingTimeInterval(0.001) }
            var job = Job(createdAt: now, request: request)
            if let when = request.startAfter, when > now {
                job.state = .scheduled(when)
            } else {
                job.message = Messages.waitingForSlot
            }
            jobs.append(job)
            ids.append(job.id)
        }
        settle()
        return ids
    }

    @discardableResult
    public func add(_ request: JobRequest) -> UUID {
        add([request])[0]
    }

    public func update(_ settings: QueueSettings) {
        self.settings = settings
        settle()
    }

    // MARK: Actions

    /// Stops a download but keeps what has been downloaded so far.
    public func pause(_ id: UUID) {
        guard let index = index(of: id) else { return }
        switch jobs[index].state {
        case .lookingUp, .running:
            stop(id, because: .pause)
        case .waiting, .retrying:
            break
        default:
            return
        }
        jobs[index].state = .paused
        jobs[index].message = Messages.paused
        settle()
    }

    public func resume(_ id: UUID) {
        guard let index = index(of: id), jobs[index].state == .paused else { return }
        makeWaiting(index)
        settle()
    }

    /// Begins a scheduled download, or one waiting to try again, now.
    public func startNow(_ id: UUID) {
        guard let index = index(of: id), jobs[index].state.due != nil else { return }
        makeWaiting(index)
        settle()
    }

    /// Stops a download and discards what it had not finished. Files that
    /// were already complete (earlier items of a playlist) stay.
    public func cancel(_ id: UUID) {
        guard let index = index(of: id), jobs[index].state.isUnfinished else { return }
        discardWork(of: id)
        jobs[index].state = .cancelled
        jobs[index].message = Messages.cancelled
        settle()
    }

    /// Has another go at a download that failed or was cancelled.
    public func retry(_ id: UUID) {
        guard let index = index(of: id), jobs[index].state == .failed || jobs[index].state == .cancelled else { return }
        jobs[index].attempt = 0
        jobs[index].warnings = []
        makeWaiting(index)
        settle()
    }

    /// Takes a job off the list, cancelling it first if it is not finished.
    public func remove(_ id: UUID) {
        guard let index = index(of: id) else { return }
        discardWork(of: id)
        jobs.remove(at: index)
        logs[id] = nil
        settle()
    }

    public func clearFinished() {
        for job in jobs where !job.state.isUnfinished {
            discardWork(of: job.id)
            logs[job.id] = nil
        }
        jobs.removeAll { !$0.state.isUnfinished }
        settle()
    }

    public func pauseAll() {
        for job in jobs { pause(job.id) }
    }

    public func resumeAll() {
        for job in jobs { resume(job.id) }
    }

    public func cancelAll() {
        for job in jobs { cancel(job.id) }
    }

    // MARK: Running

    private func index(of id: UUID) -> Int? {
        jobs.firstIndex { $0.id == id }
    }

    private func makeWaiting(_ index: Int) {
        jobs[index].state = .waiting
        jobs[index].message = Messages.waitingForSlot
    }

    private func stop(_ id: UUID, because reason: StopReason) {
        guard let task = tasks[id] else { return }
        // A cancel is never downgraded to a pause.
        if stopping[id] != .cancel { stopping[id] = reason }
        task.cancel()
    }

    /// Removes a job's working folder: at once when no tool is using it,
    /// otherwise as soon as the tool has stopped.
    private func discardWork(of id: UUID) {
        if tasks[id] != nil {
            stop(id, because: .cancel)
        } else {
            Workspace(paths: paths, job: id).remove()
        }
    }

    /// After every change: start what can start, set the alarm for what is
    /// waiting on a time, write the queue down, and tell whoever is watching.
    private func settle() {
        pump()
        rearm()
        persist()
        publish()
    }

    private func pump() {
        let limit = min(max(settings.maxConcurrent, QueueSettings.concurrencyRange.lowerBound), QueueSettings.concurrencyRange.upperBound)
        // Oldest first. A job that was just paused or cancelled may still be
        // stopping its tool; it holds its slot, and is not started again, until that has ended.
        for job in jobs where job.state == .waiting && tasks[job.id] == nil {
            guard tasks.count < limit else { break }
            if sameWorkIsRunning(as: job) { continue }
            start(job.id)
        }
    }

    /// Two jobs for the same link with the same recipe never run at the same
    /// time; the second waits for the first.
    private func sameWorkIsRunning(as job: Job) -> Bool {
        jobs.contains { $0.id != job.id && tasks[$0.id] != nil && $0.link == job.link && $0.recipe == job.recipe }
    }

    private func start(_ id: UUID) {
        guard let index = index(of: id) else { return }
        if jobs[index].startedAt == nil { jobs[index].startedAt = clock.now() }
        let needsLookup = jobs[index].source == .link
        jobs[index].state = needsLookup ? .lookingUp : .running(.starting)
        jobs[index].message = needsLookup ? Messages.lookingUp : ""
        jobs[index].progress = JobProgress()
        let job = jobs[index]
        let context = JobContext(workspace: Workspace(paths: paths, job: id), folders: settings.folders,
                                 nameStyle: settings.nameStyle, cookiesFile: settings.cookiesFile,
                                 speedLimitKB: settings.speedLimitKB, archiveFile: paths.archiveFile.path)
        let worker = self.worker
        // Events are taken in one at a time, in order, and all of them before the outcome.
        let (events, feed) = AsyncStream<JobEvent>.makeStream()
        tasks[id] = Task { [weak self] in
            let reader = Task { [weak self] in
                for await event in events { await self?.apply(event, to: id) }
            }
            let outcome = await worker.run(job, context: context) { feed.yield($0) }
            feed.finish()
            await reader.value
            await self?.finished(id, outcome: outcome)
        }
    }

    private func apply(_ event: JobEvent, to id: UUID) {
        if case .log(let line) = event {
            logs[id, default: JobLog()].append(line)
            return
        }
        guard let index = index(of: id) else { return }
        switch event {
        case .file(let path):
            // A finished file is real whatever has happened to the job since.
            if !jobs[index].files.contains(path) { jobs[index].files.append(path) }
            persist()
        case .resolved(let resolution):
            jobs[index].apply(resolution)
            if jobs[index].state == .lookingUp {
                jobs[index].state = .running(.starting)
                jobs[index].message = ""
            }
            persist()
        case .destination(let folder):
            if jobs[index].folder == nil { jobs[index].folder = folder }
            persist()
        case .stage(let stage):
            // A job that was paused or cancelled a moment ago is not brought back by a late line.
            guard jobs[index].state.isActive else { return }
            jobs[index].state = .running(stage)
        case .progress(let progress):
            guard jobs[index].state.isActive else { return }
            jobs[index].progress = progress
        case .log:
            return
        }
        publish()
    }

    private func finished(_ id: UUID, outcome: JobOutcome) {
        tasks[id] = nil
        let reason = stopping.removeValue(forKey: id)
        let workspace = Workspace(paths: paths, job: id)
        if reason == .cancel { workspace.remove() }
        guard let index = index(of: id) else {
            // Removed from the list while its tool was stopping.
            workspace.remove()
            settle()
            return
        }
        // When the person paused, cancelled or resumed in the meantime, the job
        // already says what they asked for. Otherwise the outcome decides.
        if jobs[index].state.isActive {
            switch outcome {
            case .finished(let message, let warnings):
                jobs[index].state = warnings.isEmpty ? .done : .doneWithWarnings
                jobs[index].message = message
                jobs[index].warnings = warnings
                jobs[index].progress.fraction = 1
                jobs[index].progress.speed = ""
                jobs[index].progress.timeLeft = ""
                workspace.remove()
            case .failed(let message, let retryable):
                if retryable, settings.autoRetry, let wait = RetryPolicy.delay(afterAttempt: jobs[index].attempt) {
                    // A dropped connection or a busy server: wait, then carry
                    // on from what the workspace holds.
                    jobs[index].attempt += 1
                    jobs[index].state = .retrying(at: clock.now().addingTimeInterval(wait))
                    jobs[index].message = Messages.retrying(inSeconds: Int(wait), retry: jobs[index].attempt, of: RetryPolicy.maxAttempts)
                    logs[id, default: JobLog()].append(message)
                    logs[id, default: JobLog()].append(jobs[index].message)
                } else {
                    // The workspace stays until the job is retried, removed or
                    // cleared, so Retry carries on from what was downloaded.
                    jobs[index].state = .failed
                    jobs[index].message = message
                    logs[id, default: JobLog()].append(message)
                }
            case .stopped:
                jobs[index].state = .paused
                jobs[index].message = Messages.paused
            }
        }
        settle()
    }

    // MARK: Time

    /// One alarm, set for whichever scheduled or retrying job is due first.
    private func rearm() {
        let due = jobs.compactMap(\.state.due).min()
        guard due != timerDue || (due != nil && timer == nil) else { return }
        timer?.cancel()
        timer = nil
        timerDue = due
        guard let due else { return }
        let clock = self.clock
        timer = Task { [weak self] in
            do {
                try await clock.sleep(until: due)
            } catch {
                return
            }
            await self?.alarm(for: due)
        }
    }

    private func alarm(for due: Date) {
        guard timerDue == due else { return }
        timer = nil
        timerDue = nil
        let now = clock.now()
        for index in jobs.indices {
            if let when = jobs[index].state.due, when <= now { makeWaiting(index) }
        }
        settle()
    }

    // MARK: Saving and publishing

    private func persist() {
        let unfinished = jobs.filter(\.state.isUnfinished).map(SavedJob.init)
        guard unfinished != lastSaved else { return }
        if (try? store.save(unfinished)) != nil { lastSaved = unfinished }
    }

    private func publish() {
        for watcher in watchers.values { watcher.yield(jobs) }
    }
}
