import Foundation

/// The worker that runs the real tools: `Probe` for the look-up, the command
/// from `YtdlpCommand` for the download, `Delivery` to finalise. The tool
/// works only inside the job's workspace; the engine moves each finished
/// file to its destination as it arrives.
public struct ToolJobWorker: JobWorker {
    private let tools: @Sendable () -> ToolRegistry
    public var runner: ProcessRunner
    public var clock: any EngineClock
    /// How long a look-up may take before it is given up as "the site did not answer".
    public var lookupTimeout: TimeInterval = 180
    /// Where a downloaded original goes when its re-encoded version replaces it.
    public var trash: any Trash = SystemTrash()
    /// Where finished downloads are recorded. Nil records nothing.
    public var library: LibraryRepository?

    /// `tools` is asked at the start of every run, so a tool chosen in
    /// Settings is used by the next job without rebuilding the queue.
    public init(tools: @escaping @Sendable () -> ToolRegistry, runner: ProcessRunner = ProcessRunner(),
                clock: any EngineClock = SystemClock()) {
        self.tools = tools
        self.runner = runner
        self.clock = clock
    }

    public init(tools: ToolRegistry, runner: ProcessRunner = ProcessRunner(), clock: any EngineClock = SystemClock()) {
        self.init(tools: { tools }, runner: runner, clock: clock)
    }

    public func run(_ job: Job, context: JobContext, report: @escaping @Sendable (JobEvent) -> Void) async -> JobOutcome {
        let registry = tools()
        guard let toolchain = YtdlpCommand.Toolchain(registry: registry) else {
            return .failed(message: Messages.noTool, retryable: false)
        }
        do {
            try context.workspace.create()
        } catch {
            return .failed(message: Messages.workspaceUnwritable, retryable: false)
        }
        var job = job
        if job.source == .link {
            switch await lookUp(job, context: context, toolchain: toolchain) {
            case .resolved(let resolution):
                job.apply(resolution)
                report(.resolved(resolution))
            case .ended(let outcome):
                return outcome
            }
        }
        if Task.isCancelled { return .stopped }
        let stepTools = StepTools(ffmpeg: toolchain.ffmpeg, ffprobe: registry.path(.ffprobe),
                                  environment: toolchain.environment, runner: runner)
        return await download(job, context: context, toolchain: toolchain, stepTools: stepTools, report: report)
    }

    // MARK: Look up

    private enum LookedUp {
        case resolved(JobResolution)
        case ended(JobOutcome)
    }

    private func lookUp(_ job: Job, context: JobContext, toolchain: YtdlpCommand.Toolchain) async -> LookedUp {
        let request = Probe.Request(link: job.link, cookiesFile: context.cookiesFile,
                                    cookieBrowser: job.recipe.cookieBrowser, proxy: job.recipe.proxy)
        let runner = self.runner
        // Whichever comes first: the answer, or the time limit (nil).
        let result = await clock.limited(to: lookupTimeout) { await Probe.lookUp(request, toolchain: toolchain, runner: runner) }
        if Task.isCancelled { return .ended(.stopped) }
        switch result {
        case nil:
            return .ended(.failed(message: Messages.lookupTimedOut, retryable: true))
        case .video(let media):
            return .resolved(JobResolution(media))
        case .playlist(let playlist):
            return .resolved(JobResolution(playlist))
        case .failure(let failure):
            switch failure.kind {
            case .stopped:
                return .ended(.stopped)
            case .tool(let kind):
                // The kind decides; when the tool's words are all there is, they do.
                let retryable = RetryPolicy.isPassing(kind) ?? RetryPolicy.isPassing(failure.message)
                return .ended(.failed(message: failure.message, retryable: retryable))
            case .toolMissing, .invalidLink, .live, .upcoming, .emptyPage, .unreadable:
                return .ended(.failed(message: failure.message, retryable: false))
            }
        }
    }

    // MARK: Download, the steps after it, and finalise

    private func download(_ job: Job, context: JobContext, toolchain: YtdlpCommand.Toolchain, stepTools: StepTools,
                          report: @escaping @Sendable (JobEvent) -> Void) async -> JobOutcome {
        let workspace = context.workspace
        let recipe = job.downloadRecipe(speedLimitKB: context.speedLimitKB)
        let folder = job.folder ?? context.folders.folder(site: job.site, audioOnly: recipe.mode == .audio,
                                                          playlistTitle: job.isPlaylist ? job.title : nil)
        if job.folder == nil { report(.destination(folder)) }

        // Chapters from the comments are put into the video's details first.
        var notes: [String] = []
        var infoFile: String?
        if recipe.chapterSource != .youtube {
            let stage = CommentChapterStage(toolchain: toolchain, runner: runner, clock: clock, timeout: lookupTimeout, report: report)
            switch await stage.run(job: job, cookiesFile: context.cookiesFile, into: workspace.infoFile) {
            case .prepared(let file): infoFile = file
            case .skipped(let warning): if let warning { notes.append(warning) }
            case .stopped: return .stopped
            }
            if Task.isCancelled { return .stopped }
        }

        // The person's own archive when the recipe asks for one; otherwise a
        // playlist keeps a private one in its workspace.
        let archive = job.recipe.useArchive ? context.archiveFile : (job.isPlaylist ? workspace.archive.path : nil)
        // The tool's "destination" is the workspace; the engine moves finished files on from there.
        var request = job.commandRequest(folder: workspace.staging.path, archiveFile: archive,
                                         cookiesFile: context.cookiesFile, speedLimitKB: context.speedLimitKB)
        request.workspace = workspace.partial.path
        request.outputListFile = workspace.fileList.path
        request.chaptersFile = recipe.splitChapters ? workspace.chapterList.path : nil
        request.infoFile = infoFile
        request.notesFile = library == nil ? nil : workspace.noteList.path
        request.thumbnailFolder = library == nil ? nil : workspace.thumbnails.path
        let plan: YtdlpCommand.Plan
        do {
            plan = try YtdlpCommand.plan(request, toolchain: toolchain)
        } catch let failure as YtdlpCommand.Failure {
            return .failed(message: failure.message, retryable: false)
        } catch {
            return .failed(message: Messages.downloadFailed, retryable: false)
        }
        report(.log("$ " + plan.displayCommand))
        for warning in plan.warnings { report(.log(warning.message)) }
        report(.stage(.starting))

        let inbox = Inbox()
        let run = DownloadRun(job: job, workspace: workspace, folder: folder, notes: notes, report: report) { inbox.add($0) }
        let running: RunningProcess
        do {
            running = try runner.start(plan.processRequest, maxLineLength: JobLog.maxLineLength) { run.handle($0.text) }
        } catch {
            return .failed(message: Messages.noTool, retryable: false)
        }
        workspace.recordTool(pid: running.processIdentifier)
        // Finished files are taken through their steps and delivered one by
        // one while the tool carries on with the next.
        let finisher = FileFinisher(recipe: recipe, workspace: workspace, tools: stepTools, trash: trash, report: report)
        let rule = Delivery.NameRule(job: job, style: context.nameStyle)
        let recorder = library.map { DownloadRecorder(library: $0, job: job, workspace: workspace, clock: clock) }
        async let finishing = Self.finishFiles(from: inbox, finisher: finisher, run: run, folder: folder, rule: rule,
                                               recorder: recorder, report: report)
        let outcome = await withTaskCancellationHandler {
            await running.waitUntilExit()
        } onCancel: {
            running.stop()
        }
        workspace.clearToolRecord()
        // Whatever the tool finished is kept, however the run ended.
        run.listEverything()
        inbox.close()
        // The steps can outlast the tool; whether the run was stopped is asked once they have ended.
        let files = await finishing
        return run.finish(outcome, cancelled: Task.isCancelled, files: files)
    }

    /// What became of the files a run finished.
    fileprivate struct Delivered: Sendable {
        var files: [String] = []
        var warnings: [String] = []
        var failed = false
    }

    private static func finishFiles(from inbox: Inbox, finisher: FileFinisher, run: DownloadRun, folder: String,
                                    rule: Delivery.NameRule, recorder: DownloadRecorder?,
                                    report: @escaping @Sendable (JobEvent) -> Void) async -> Delivered {
        var result = Delivered()
        while let listed = await inbox.next() {
            var file = listed
            if finisher.hasSteps(listed) {
                // A file whose steps were stopped waits in the workspace for the job to resume.
                guard let finished = await finisher.finish(listed) else { continue }
                file = finished.file
                for warning in finished.warnings where !result.warnings.contains(warning) { result.warnings.append(warning) }
                run.announceStage()
            }
            do {
                if let final = try Delivery.deliver(mainFile: file, staging: finisher.workspace.staging, folder: folder, rule: rule) {
                    result.files.append(final)
                    // In the Library before the Queue says "done", so the two never disagree.
                    await recorder?.record(listed: listed, final: final)
                    report(.file(final))
                }
            } catch {
                // The file stays in the workspace; a later run delivers it.
                result.failed = true
                report(.log(Messages.destinationUnwritable(folder)))
            }
        }
        return result
    }
}

/// Finished files waiting for their steps, in the order the tool listed them.
private final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    private var closed = false
    private var waiter: CheckedContinuation<String?, Never>?

    func add(_ item: String) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: item)
        } else {
            items.append(item)
            lock.unlock()
        }
    }

    /// Nothing more will come.
    func close() {
        lock.lock()
        closed = true
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: nil)
    }

    /// The next file, or nil once the inbox is closed and empty. It does not
    /// end early when the task is cancelled: the run always closes it.
    func next() async -> String? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !items.isEmpty {
                let item = items.removeFirst()
                lock.unlock()
                continuation.resume(returning: item)
            } else if closed {
                lock.unlock()
                continuation.resume(returning: nil)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}

/// One run of the download tool for a job: reads its lines, reports what
/// they mean, and hands on each finished file as the tool lists it. Lines
/// arrive one at a time on the runner's queue.
private final class DownloadRun: @unchecked Sendable {
    private let lock = NSLock()
    private let job: Job
    private let workspace: Workspace
    private let folder: String
    private let notes: [String]
    private let report: @Sendable (JobEvent) -> Void
    private let listed: @Sendable (String) -> Void

    private var stage = JobStage.starting
    private var ended = false
    private var progress = JobProgress()
    private var errors: [String] = []
    private var alreadyHave = 0
    private var listLength: UInt64 = 0
    private var handled = Set<String>()

    init(job: Job, workspace: Workspace, folder: String, notes: [String], report: @escaping @Sendable (JobEvent) -> Void,
         listed: @escaping @Sendable (String) -> Void) {
        self.job = job
        self.workspace = workspace
        self.folder = folder
        self.notes = notes
        self.report = report
        self.listed = listed
        progress.itemCount = max(job.itemCount ?? 1, 1)
    }

    func handle(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        switch ToolOutput.parse(line) {
        case .progress(let fraction, let speed, let timeLeft, let size, let item, let itemCount, _):
            if let item { progress.item = max(item, 1) }
            if let itemCount { progress.itemCount = max(itemCount, 1) }
            progress.speed = speed
            progress.timeLeft = timeLeft
            progress.size = size
            // Over the whole job: finished items plus the part of this one.
            progress.fraction = fraction.map { (Double(progress.item - 1) + $0) / Double(progress.itemCount) }
            set(.downloading)
            report(.progress(progress))
            // Progress lines are not log lines.
            return
        case .item(let index, let count):
            progress.item = index
            progress.itemCount = count
            report(.progress(progress))
        case .stage(let name):
            set(.processing(name))
        case .error(let text):
            errors.append(text)
        case .alreadyHave:
            alreadyHave += 1
        case .interrupted, .other:
            break
        }
        report(.log(line))
        readList()
    }

    private func set(_ next: JobStage) {
        guard next != stage else { return }
        stage = next
        report(.stage(next))
    }

    /// Says again what the tool is doing, after a step on a finished file
    /// had the job's line for a while.
    func announceStage() {
        lock.lock()
        defer { lock.unlock() }
        if !ended { report(.stage(stage)) }
    }

    /// Hands on every download the tool has listed as finished since the last look.
    private func readList() {
        let size = ((try? FileManager.default.attributesOfItem(atPath: workspace.fileList.path))?[.size] as? NSNumber)?.uint64Value ?? 0
        guard size != listLength, let text = try? String(contentsOf: workspace.fileList, encoding: .utf8) else { return }
        // A last line without its line break is still being written; it is read next time.
        guard let end = text.lastIndex(of: "\n") else { return }
        listLength = UInt64(text[...end].utf8.count)
        for path in text[...end].split(separator: "\n").map(String.init) where !handled.contains(path) {
            handled.insert(path)
            listed(path)
        }
    }

    /// After the tool has ended: everything it listed, read once more from the start.
    func listEverything() {
        lock.lock()
        defer { lock.unlock() }
        ended = true
        listLength = 0
        readList()
    }

    func finish(_ outcome: ProcessOutcome, cancelled: Bool, files delivery: ToolJobWorker.Delivered) -> JobOutcome {
        lock.lock()
        defer { lock.unlock() }
        if cancelled || outcome.stopRequested { return .stopped }
        let place = Naming.breadcrumb(folder)
        if delivery.failed { return .failed(message: Messages.destinationUnwritable(place), retryable: false) }

        let files = job.files + delivery.files
        if !files.isEmpty {
            set(.finishing)
            var warnings: [String] = []
            for error in errors {
                let sentence = ErrorTranslator.friendly(error)
                if !sentence.isEmpty && !warnings.contains(sentence) && warnings.count < 5 { warnings.append(sentence) }
            }
            if !outcome.succeeded && warnings.isEmpty { warnings.append(Messages.toolReportedProblem) }
            // What the steps before and after the download could not do.
            for note in notes + delivery.warnings where !warnings.contains(note) { warnings.append(note) }
            do {
                // What the tool left beside the main files: chapter files, a list's picture.
                try Delivery.deliverRest(staging: workspace.staging, folder: folder)
            } catch {
                warnings.append(Messages.destinationUnwritable(place))
            }
            let total = max(progress.itemCount, job.itemCount ?? 1)
            let message: String
            if job.isPlaylist && !errors.isEmpty && total > files.count {
                message = Messages.someSavedTo(files.count, of: total, place)
            } else {
                message = files.count > 1 ? Messages.filesSavedTo(files.count, place) : Messages.savedTo(place)
            }
            return .finished(message: message, warnings: warnings)
        }
        if outcome.succeeded {
            if alreadyHave > 0 { return .finished(message: Messages.alreadyDownloaded, warnings: []) }
            return .failed(message: Messages.nothingSaved, retryable: false)
        }
        guard let raw = errors.last else { return .failed(message: Messages.downloadFailed, retryable: false) }
        let sentence = ErrorTranslator.friendly(raw)
        return .failed(message: sentence.isEmpty ? Messages.downloadFailed : sentence, retryable: RetryPolicy.isPassing(raw))
    }
}
