import Foundation
import Testing
@testable import Engine

// Stand-ins for the queue's tests: a clock that only moves when told to, and
// a worker that runs no tool and ends when the test says so.

/// Waits for something that happens on another task. Returns false after the time limit.
func eventually(timeout: TimeInterval = 5, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}

final class FakeClock: EngineClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var sleepers: [UUID: (deadline: Date, continuation: CheckedContinuation<Void, Error>)] = [:]
    private var cancelled = Set<UUID>()

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    var sleeperCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sleepers.count
    }

    func sleep(until deadline: Date) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelled.remove(id) != nil {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if deadline <= current {
                    lock.unlock()
                    continuation.resume()
                } else {
                    sleepers[id] = (deadline, continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let sleeper = sleepers.removeValue(forKey: id)
            if sleeper == nil { cancelled.insert(id) }
            lock.unlock()
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        let due = sleepers.filter { $0.value.deadline <= current }
        for id in due.keys { sleepers[id] = nil }
        lock.unlock()
        for sleeper in due.values { sleeper.continuation.resume() }
    }
}

final class FakeWorker: JobWorker, @unchecked Sendable {
    private struct Run {
        var job: Job
        var context: JobContext
        var report: @Sendable (JobEvent) -> Void
        var continuation: CheckedContinuation<JobOutcome, Never>?
        var stopRequested = false
    }

    private let lock = NSLock()
    private var runs: [UUID: Run] = [:]
    private var starts: [UUID] = []
    private var held = false

    /// Every start, in order; a job that ran twice is listed twice.
    var started: [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    /// When true, a stopped run does not end until `releaseStop`, like a tool that takes a while to go.
    var holdStops: Bool {
        get { lock.lock(); defer { lock.unlock() }; return held }
        set { lock.lock(); held = newValue; lock.unlock() }
    }

    func runCount(_ id: UUID) -> Int { started.filter { $0 == id }.count }

    func isRunning(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return runs[id] != nil
    }

    func stopRequested(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return runs[id]?.stopRequested ?? false
    }

    func context(_ id: UUID) -> JobContext? {
        lock.lock()
        defer { lock.unlock() }
        return runs[id]?.context
    }

    func job(_ id: UUID) -> Job? {
        lock.lock()
        defer { lock.unlock() }
        return runs[id]?.job
    }

    func run(_ job: Job, context: JobContext, report: @escaping @Sendable (JobEvent) -> Void) async -> JobOutcome {
        let id = job.id
        begin(Run(job: job, context: context, report: report))
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<JobOutcome, Never>) in
                lock.lock()
                if runs[id]?.stopRequested == true && !held {
                    runs[id] = nil
                    lock.unlock()
                    continuation.resume(returning: .stopped)
                } else {
                    runs[id]?.continuation = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            runs[id]?.stopRequested = true
            var continuation: CheckedContinuation<JobOutcome, Never>?
            if !held {
                continuation = runs[id]?.continuation
                if continuation != nil { runs[id] = nil }
            }
            lock.unlock()
            continuation?.resume(returning: .stopped)
        }
    }

    private func begin(_ run: Run) {
        lock.lock()
        starts.append(run.job.id)
        runs[run.job.id] = run
        lock.unlock()
    }

    func emit(_ id: UUID, _ event: JobEvent) {
        lock.lock()
        let report = runs[id]?.report
        lock.unlock()
        report?(event)
    }

    /// Ends the job's current run with an outcome.
    func finish(_ id: UUID, _ outcome: JobOutcome) {
        lock.lock()
        let continuation = runs[id]?.continuation
        if continuation != nil { runs[id] = nil }
        lock.unlock()
        continuation?.resume(returning: outcome)
    }

    /// Lets a held stop complete.
    func releaseStop(_ id: UUID) {
        finish(id, .stopped)
    }
}

/// A queue on a temporary Application Support folder, with a worker and a clock the test controls.
struct QueueFixture {
    let root: URL
    let paths: AppPaths
    let worker = FakeWorker()
    let clock = FakeClock()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("queue-tests-\(UUID().uuidString.prefix(8))", isDirectory: true)
        paths = AppPaths(root: root)
        try paths.createFolders()
    }

    func queue(settings: QueueSettings = QueueFixture.settings()) -> JobQueue {
        JobQueue(paths: paths, worker: worker, settings: settings, clock: clock)
    }

    static func settings(maxConcurrent: Int = 2) -> QueueSettings {
        var settings = QueueSettings(folders: FolderRules(mainFolder: "/Users/test/Movies", audioFolder: "/Users/test/Music"))
        settings.maxConcurrent = maxConcurrent
        return settings
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    func workspace(_ id: UUID) -> Workspace {
        Workspace(paths: paths, job: id)
    }

    func savedJobs() -> [SavedJob] {
        QueueStore(paths: paths).load()
    }
}

enum Sample {
    static func video(_ name: String = "talk", preset: Preset = PresetCatalog.best, startAfter: Date? = nil) -> JobRequest {
        let media = MediaFacts(facts: VideoFacts(id: name, title: "A \(name)", uploader: "Someone"), site: "YouTube",
                               link: "https://example.com/watch?v=\(name)", duration: "3:00")
        return .video(media, preset: preset, startAfter: startAfter)
    }

    static func playlist(_ name: String = "list") -> JobRequest {
        .playlist(PlaylistFacts(title: "A \(name)", uploader: "Someone", site: "YouTube", count: 3,
                                link: "https://example.com/playlist?list=\(name)"), preset: PresetCatalog.best)
    }

    static func link(_ name: String = "pasted") -> JobRequest {
        JobRequest.links(["https://example.com/watch?v=\(name)"], preset: PresetCatalog.best)[0]
    }

    static let saved = JobOutcome.finished(message: "Saved to Movies › YouTube", warnings: [])
}
