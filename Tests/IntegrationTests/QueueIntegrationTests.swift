import Foundation
import Testing
@testable import Engine

// The queue with the real worker and the real tools, downloading generated
// media from a local web server that answers Range requests (plan Phase 4).
// Nothing leaves the machine.

/// Waits for something that happens on another task. Returns false after the time limit.
func eventually(timeout: TimeInterval = 60, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}

/// A clock for the queue whose waits a test can end at once. The worker keeps the real one.
private final class SkippableClock: EngineClock, @unchecked Sendable {
    private let lock = NSLock()
    private var offset: TimeInterval = 0
    private var sleepers: [UUID: (deadline: Date, continuation: CheckedContinuation<Void, Error>)] = [:]

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return Date().addingTimeInterval(offset)
    }

    var isWaiting: Bool {
        lock.lock(); defer { lock.unlock() }
        return !sleepers.isEmpty
    }

    func sleep(until deadline: Date) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.park(id, deadline, continuation)
            }
        } onCancel: {
            self.release(id)?.resume(throwing: CancellationError())
        }
    }

    private func park(_ id: UUID, _ deadline: Date, _ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        sleepers[id] = (deadline, continuation)
        lock.unlock()
    }

    private func release(_ id: UUID) -> CheckedContinuation<Void, Error>? {
        lock.lock(); defer { lock.unlock() }
        return sleepers.removeValue(forKey: id)?.continuation
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        offset += seconds
        let now = Date().addingTimeInterval(offset)
        let due = sleepers.filter { $0.value.deadline <= now }
        for id in due.keys { sleepers[id] = nil }
        lock.unlock()
        for sleeper in due.values { sleeper.continuation.resume() }
    }
}

/// A local site, a place for the app's own files, and a destination folder.
struct Site {
    let root: URL
    let www: URL
    let server: RangeServer
    let paths: AppPaths
    let movies: URL
    let music: URL

    init(_ name: String) throws {
        root = try Real.scratchFolder(name).resolvingSymlinksInPath()
        www = root.appendingPathComponent("www", isDirectory: true)
        try FileManager.default.createDirectory(at: www, withIntermediateDirectories: true)
        server = try RangeServer(root: www)
        paths = AppPaths(root: root.appendingPathComponent("support", isDirectory: true))
        movies = root.appendingPathComponent("Movies", isDirectory: true)
        music = root.appendingPathComponent("Music", isDirectory: true)
    }

    func cleanUp() {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    var settings: QueueSettings {
        QueueSettings(folders: FolderRules(mainFolder: movies.path, audioFolder: music.path))
    }

    /// Where a test's worker puts what it would move to the Trash.
    var trash: URL { root.appendingPathComponent("Trash", isDirectory: true) }

    func queue(settings: QueueSettings? = nil, clock: any EngineClock = SystemClock(), tools: ToolRegistry = Real.registry) -> JobQueue {
        var worker = ToolJobWorker(tools: tools, runner: ProcessRunner(stopGrace: 2, drainTimeout: 2))
        worker.trash = FolderTrash(folder: trash)
        return JobQueue(paths: paths, worker: worker, settings: settings ?? self.settings, clock: clock)
    }

    /// A video with sound of a steady size: about `seconds` × 190 KB.
    @discardableResult
    func makeVideo(_ name: String, seconds: Int = 6) async throws -> URL {
        let output = www.appendingPathComponent(name)
        let result = try await Real.run(Real.path(.ffmpeg), [
            "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=duration=\(seconds):size=640x360:rate=30",
            "-f", "lavfi", "-i", "sine=duration=\(seconds)",
            "-c:v", "libx264", "-preset", "ultrafast", "-b:v", "1500k", "-minrate", "1500k", "-maxrate", "1500k", "-bufsize", "1500k",
            "-x264-params", "nal-hrd=cbr", "-c:a", "aac", "-pix_fmt", "yuv420p", "-movflags", "+faststart", output.path,
        ])
        #expect(result.outcome.succeeded, "\(result.standardError)")
        return output
    }

    /// The same kind of video as a stream cut into two-second pieces, which is what a clip can be taken from.
    func makeStream(_ name: String, seconds: Int = 8) async throws {
        let result = try await Real.run(Real.path(.ffmpeg), [
            "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=duration=\(seconds):size=640x360:rate=30",
            "-f", "lavfi", "-i", "sine=duration=\(seconds)",
            "-c:v", "libx264", "-preset", "ultrafast", "-g", "60", "-c:a", "aac", "-pix_fmt", "yuv420p",
            "-f", "hls", "-hls_time", "2", "-hls_playlist_type", "vod",
            "-hls_segment_filename", www.appendingPathComponent("piece%03d.ts").path, www.appendingPathComponent(name).path,
        ])
        #expect(result.outcome.succeeded, "\(result.standardError)")
    }

    /// A feed the download tool reads as a playlist of the given files.
    func makeFeed(_ name: String, title: String, items: [(title: String, file: String)]) throws {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<rss version=\"2.0\"><channel><title>\(title)</title>\n"
        for item in items {
            xml += "<item><title>\(item.title)</title><enclosure url=\"\(server.url(item.file))\" type=\"video/mp4\"/></item>\n"
        }
        xml += "</channel></rss>\n"
        try Data(xml.utf8).write(to: www.appendingPathComponent(name))
    }

    func files(in folder: URL) -> [String] {
        ((try? FileManager.default.subpathsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    func size(_ file: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.intValue ?? -1
    }

    /// The seconds of video and of sound in a file, as ffprobe reads them.
    func lengths(_ file: URL) async -> [String: Double] {
        guard let result = try? await Real.run(Real.path(.ffprobe), ["-v", "error", "-print_format", "json", "-show_streams", file.path]),
              let json = try? JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8)) as? [String: Any] else { return [:] }
        var found: [String: Double] = [:]
        for stream in json["streams"] as? [[String: Any]] ?? [] {
            if let kind = stream["codec_type"] as? String, let length = (stream["duration"] as? String).flatMap(Double.init) { found[kind] = length }
        }
        return found
    }

    /// True when a downloaded file holds all of its source: the same picture
    /// and sound, from start to end. (The bytes differ, because the tool
    /// writes the title and other tags into the file it saves.)
    func isWhole(_ file: URL, like source: URL) async -> Bool {
        let got = await lengths(file)
        let wanted = await lengths(source)
        guard let video = got["video"], let audio = got["audio"], let fullVideo = wanted["video"], let fullAudio = wanted["audio"] else { return false }
        let bytes = Double(size(file)) / Double(max(size(source), 1))
        return abs(video - fullVideo) < 0.1 && abs(audio - fullAudio) < 0.1 && bytes > 0.95 && bytes < 1.05
    }

    /// The tool working in a job's workspace right now, if there is one.
    func tool(for id: UUID) -> ProcessIdentity? {
        guard let data = try? Data(contentsOf: Workspace(paths: paths, job: id).toolRecord) else { return nil }
        return try? JSONDecoder().decode(ProcessIdentity.self, from: data)
    }

    /// Lines of the job's log, to explain a failed expectation.
    func story(_ queue: JobQueue, _ id: UUID) async -> String {
        let job = await queue.job(id)
        let log = await queue.log(for: id).lines.suffix(12).joined(separator: "\n")
        return "state: \(String(describing: job?.state)) message: \(job?.message ?? "") files: \(job?.files ?? [])\n\(log)"
    }
}

/// The job is waiting on a time, or has ended one way or another.
func settled(_ queue: JobQueue, _ id: UUID) async -> Bool {
    let state = await queue.job(id)?.state
    return state?.due != nil || state?.isUnfinished == false
}

func link(_ address: String, preset: Preset = PresetCatalog.best, changing change: (inout DownloadRecipe) -> Void = { _ in }) -> JobRequest {
    var request = JobRequest.links([address], preset: preset)[0]
    change(&request.recipe)
    return request
}

@Suite struct QueueIntegrationTests {
    @Test func aLinkIsLookedUpDownloadedAndDeliveredAndNothingElseIsLeft() async throws {
        let site = try Site("queue-download")
        defer { site.cleanUp() }
        let source = try await site.makeVideo("lecture.mp4", seconds: 2)
        let queue = site.queue()
        await queue.restore()
        let id = await queue.add(link(site.server.url("lecture.mp4")))
        if !(await eventually { await queue.job(id)?.state.isUnfinished == false }) { Issue.record("\(await site.story(queue, id))") }

        let job = try #require(await queue.job(id))
        if !(job.state == .done) { Issue.record("\(await site.story(queue, id))") }
        // The look-up named it; the file took its clean name, in the folder for its site.
        #expect(job.source == .video)
        #expect(job.title == "lecture")
        #expect(job.site == "127.0.0.1")
        let file = site.movies.appendingPathComponent("127.0.0.1/lecture.mp4")
        #expect(job.files == [file.path])
        #expect(job.folder == file.deletingLastPathComponent().path)
        #expect(job.message == Messages.savedTo(Naming.breadcrumb(file.deletingLastPathComponent().path)))
        #expect(site.files(in: site.movies) == ["127.0.0.1", "127.0.0.1/lecture.mp4"])
        #expect(await site.isWhole(file, like: source))
        // Nothing of the job is left in the app's own folder.
        #expect(site.files(in: site.paths.jobs).isEmpty)
        #expect(QueueStore(paths: site.paths).load().isEmpty)
        // The log shows the command that ran, then what the tool said.
        let log = await queue.log(for: id).lines
        #expect(log.first?.hasPrefix("$ ") == true)
        #expect(log.contains { $0.hasPrefix("[download] Destination:") })
        #expect(site.server.requests.contains { $0.path == "/lecture.mp4" })
    }

    @Test func aFinishedDownloadIsRecordedInTheLibraryByTheRealTools() async throws {
        let site = try Site("queue-library")
        defer { site.cleanUp() }
        try await site.makeVideo("lecture.mp4", seconds: 2)
        let library = LibraryRepository(paths: site.paths, trash: FolderTrash(folder: site.trash))
        var worker = ToolJobWorker(tools: Real.registry, runner: ProcessRunner(stopGrace: 2, drainTimeout: 2))
        worker.trash = FolderTrash(folder: site.trash)
        worker.library = library
        let queue = JobQueue(paths: site.paths, worker: worker, settings: site.settings)
        await queue.restore()
        let id = await queue.add(link(site.server.url("lecture.mp4")))
        if !(await eventually { await queue.job(id)?.state.isUnfinished == false }) { Issue.record("\(await site.story(queue, id))") }

        let file = site.movies.appendingPathComponent("127.0.0.1/lecture.mp4")
        let records = await library.records()
        let story = await site.story(queue, id)
        let record = try #require(records.first, "\(story)")
        #expect(records.count == 1 && record.path == file.path && record.title == "lecture" && record.site == "127.0.0.1")
        #expect(record.bytes == (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value)
        // What the tool noted about the file was read (its id and the site's name for itself).
        #expect(record.archiveID?.hasPrefix("generic ") == true, "\(String(describing: record.archiveID))")
        #expect(site.files(in: site.paths.jobs).isEmpty)
    }

    @Test func cancellingLeavesNothingBehind() async throws {
        let site = try Site("queue-cancel")
        defer { site.cleanUp() }
        try await site.makeVideo("long.mp4")
        site.server.throttle(bytesPerSecond: 150_000)
        let queue = site.queue()
        let id = await queue.add(link(site.server.url("long.mp4")))
        if !(await eventually { (await queue.job(id)?.progress.fraction ?? 0) > 0.05 }) { Issue.record("\(await site.story(queue, id))") }
        let tool = try #require(site.tool(for: id))
        #expect(tool.isStillRunning)
        #expect(!site.files(in: Workspace(paths: site.paths, job: id).partial).isEmpty)

        await queue.cancel(id)
        #expect(await queue.job(id)?.state == .cancelled)
        await queue.idle()
        #expect(!tool.isStillRunning)
        #expect(site.files(in: site.paths.jobs).isEmpty)
        #expect(site.files(in: site.movies).filter { $0.hasSuffix(".mp4") || $0.hasSuffix(".part") }.isEmpty)
        #expect(await queue.job(id)?.files.isEmpty == true)
        #expect(QueueStore(paths: site.paths).load().isEmpty)
    }

    @Test func pauseThenResumeContinuesFromThePartialFile() async throws {
        let site = try Site("queue-pause")
        defer { site.cleanUp() }
        let source = try await site.makeVideo("long.mp4")
        site.server.throttle(bytesPerSecond: 200_000)
        let queue = site.queue()
        let id = await queue.add(link(site.server.url("long.mp4")))
        if !(await eventually { (await queue.job(id)?.progress.fraction ?? 0) > 0.2 }) { Issue.record("\(await site.story(queue, id))") }

        await queue.pause(id)
        #expect(await queue.job(id)?.state == .paused)
        await queue.idle()
        let workspace = Workspace(paths: site.paths, job: id)
        let partial = workspace.partial.appendingPathComponent("lecture [long].mp4.part")
        let kept = site.files(in: workspace.partial)
        #expect(kept.count == 1 && kept[0].hasSuffix(".part"), "\(kept)")
        let had = site.size(workspace.partial.appendingPathComponent(kept.first ?? partial.lastPathComponent))
        #expect(had > 100_000 && had < site.size(source))
        #expect(site.files(in: site.movies).filter { $0.hasSuffix(".mp4") }.isEmpty)
        #expect(QueueStore(paths: site.paths).load().map(\.state) == [.paused])
        let before = site.server.requests.count

        site.server.throttle(bytesPerSecond: 0)
        await queue.resume(id)
        if !(await eventually { await queue.job(id)?.state.isUnfinished == false }) { Issue.record("\(await site.story(queue, id))") }
        if !(await queue.job(id)?.state == .done) { Issue.record("\(await site.story(queue, id))") }
        // The tool asked for the rest only, from where the partial file ended.
        let after = site.server.requests.dropFirst(before)
        #expect(after.contains { $0.path == "/long.mp4" && $0.rangeStart == had }, "\(Array(after))")
        // The look-up was not repeated: the job remembered what the link is.
        #expect(await queue.log(for: id).lines.contains { $0.contains("Resuming download at byte \(had)") })
        let file = site.movies.appendingPathComponent("127.0.0.1/long.mp4")
        #expect(await site.isWhole(file, like: source))
        #expect(site.files(in: site.paths.jobs).isEmpty)
    }

    @Test func aPlaylistResumedAfterAPauseDoesNotDownloadFinishedItemsAgain() async throws {
        let site = try Site("queue-playlist")
        defer { site.cleanUp() }
        let one = try await site.makeVideo("one.mp4", seconds: 2)
        for name in ["two.mp4", "three.mp4"] { try FileManager.default.copyItem(at: one, to: site.www.appendingPathComponent(name)) }
        try site.makeFeed("feed.xml", title: "Three Talks", items: [("First", "one.mp4"), ("Second", "two.mp4"), ("Third", "three.mp4")])
        let size = site.size(one)
        site.server.throttle(bytesPerSecond: size / 2)
        let queue = site.queue()
        let id = await queue.add(link(site.server.url("feed.xml")) { $0.sleepInterval = 0 })

        // The first item is delivered while the list is still downloading.
        if !(await eventually { await queue.job(id)?.files.count == 1 }) { Issue.record("\(await site.story(queue, id))") }
        let folder = site.movies.appendingPathComponent("127.0.0.1/Three Talks")
        #expect(site.files(in: folder) == ["001 - First.mp4"])
        #expect(await queue.job(id)?.source == .playlist)
        #expect(await queue.job(id)?.state.isActive == true)
        await queue.pause(id)
        await queue.idle()
        #expect(await queue.job(id)?.state == .paused)
        let sentBefore = site.server.bytesSent("one.mp4")

        // Still slowed down, so that a second fetch of the first item would show in what the server sent.
        site.server.throttle(bytesPerSecond: size * 2)
        await queue.resume(id)
        if !(await eventually { await queue.job(id)?.state.isUnfinished == false }) { Issue.record("\(await site.story(queue, id))") }
        let job = try #require(await queue.job(id))
        if !(job.state == .done) { Issue.record("\(await site.story(queue, id))") }
        #expect(site.files(in: folder) == ["001 - First.mp4", "002 - Second.mp4", "003 - Third.mp4"])
        #expect(job.files == ["001 - First.mp4", "002 - Second.mp4", "003 - Third.mp4"].map { folder.appendingPathComponent($0).path })
        #expect(job.message == Messages.filesSavedTo(3, Naming.breadcrumb(folder.path)))
        // The first item's data was not fetched a second time.
        #expect(site.server.bytesSent("one.mp4") - sentBefore < size / 2, "\(site.server.bytesSent("one.mp4")) after \(sentBefore)")
        #expect(await queue.log(for: id).lines.contains { $0.hasSuffix("has already been recorded in the archive") })
        for name in site.files(in: folder) {
            #expect(await site.isWhole(folder.appendingPathComponent(name), like: one))
        }
        #expect(site.files(in: site.paths.jobs).isEmpty)
    }

    @Test func aDroppedConnectionIsRetriedAndCarriesOn() async throws {
        let site = try Site("queue-drop")
        defer { site.cleanUp() }
        let source = try await site.makeVideo("flaky.mp4", seconds: 3)
        site.server.throttle(bytesPerSecond: 400_000)
        site.server.drop("flaky.mp4", after: 200_000)
        let clock = SkippableClock()
        let queue = site.queue(clock: clock)
        // The tool's own retries are switched off, so the dropped connection reaches the queue.
        let id = await queue.add(link(site.server.url("flaky.mp4")) { $0.retries = 0 })

        if !(await eventually { await settled(queue, id) }) { Issue.record("\(await site.story(queue, id))") }
        let waiting = try #require(await queue.job(id))
        guard case .retrying = waiting.state else {
            Issue.record("expected a retry: \(await site.story(queue, id))")
            return
        }
        #expect(waiting.attempt == 1)
        #expect(waiting.message == Messages.retrying(inSeconds: 15, retry: 1, of: 3))
        #expect(QueueStore(paths: site.paths).load().map(\.state) == [.retrying])
        let partial = Workspace(paths: site.paths, job: id).partial
        #expect(site.files(in: partial).contains { $0.hasSuffix(".part") })

        // Fifteen seconds later, without waiting for them.
        #expect(await eventually { clock.isWaiting })
        clock.advance(by: 15)
        if !(await eventually { await queue.job(id)?.state.isUnfinished == false }) { Issue.record("\(await site.story(queue, id))") }
        if !(await queue.job(id)?.state == .done) { Issue.record("\(await site.story(queue, id))") }
        #expect(site.server.requests.contains { $0.path == "/flaky.mp4" && ($0.rangeStart ?? 0) > 0 })
        let file = site.movies.appendingPathComponent("127.0.0.1/flaky.mp4")
        #expect(await site.isWhole(file, like: source))
    }

    @Test func jobsForTheSameLinkDoNotCollide() async throws {
        let site = try Site("queue-twins")
        defer { site.cleanUp() }
        let source = try await site.makeVideo("talk.mp4", seconds: 2)
        var settings = site.settings
        settings.maxConcurrent = 3
        let queue = site.queue(settings: settings)
        let address = site.server.url("talk.mp4")
        // The same video twice, and once more as audio, all at once.
        let ids = await queue.add([link(address), link(address), link(address, preset: PresetCatalog.audioOnly)])
        #expect(await eventually { await queue.snapshot().allSatisfy { !$0.state.isUnfinished } })
        for id in ids where await queue.job(id)?.state != .done { Issue.record("\(await site.story(queue, id))") }

        let folder = site.movies.appendingPathComponent("127.0.0.1")
        #expect(site.files(in: folder) == ["talk (2).mp4", "talk.mp4"])
        #expect(site.files(in: site.music) == ["talk.m4a"])
        for name in ["talk.mp4", "talk (2).mp4"] {
            #expect(await site.isWhole(folder.appendingPathComponent(name), like: source))
        }
        #expect(site.files(in: site.paths.jobs).isEmpty)
    }

    @Test func aClipIsCutFromAStreamAndNamedAsOne() async throws {
        let site = try Site("queue-clip")
        defer { site.cleanUp() }
        try await site.makeStream("show.m3u8")
        let queue = site.queue()
        // Three seconds from the middle, cut at the exact times rather than at the nearest piece.
        let id = await queue.add(link(site.server.url("show.m3u8")) { $0.clip = Clip(start: 3, end: 6) })
        if !(await eventually { await queue.job(id)?.state.isUnfinished == false }) { Issue.record("\(await site.story(queue, id))") }
        let job = try #require(await queue.job(id))
        if job.state != .done { Issue.record("\(await site.story(queue, id))") }
        let file = site.movies.appendingPathComponent("127.0.0.1/show (clip).mp4")
        #expect(job.files == [file.path])
        let lengths = await site.lengths(file)
        #expect(abs((lengths["video"] ?? 0) - 3) < 0.25, "\(lengths)")
        #expect(abs((lengths["audio"] ?? 0) - 3) < 0.25, "\(lengths)")
        #expect(await queue.log(for: id).lines.first?.contains("--download-sections '*0:03-0:06' --force-keyframes-at-cuts") == true)
        #expect(site.files(in: site.paths.jobs).isEmpty)
    }

    @Test func aLinkThatLeadsNowhereFailsWithASentenceAndIsNotRetried() async throws {
        let site = try Site("queue-missing")
        defer { site.cleanUp() }
        let queue = site.queue()
        let id = await queue.add(link(site.server.url("missing.mp4")))
        #expect(await eventually { await queue.job(id)?.state.isUnfinished == false })
        let job = try #require(await queue.job(id))
        if !(job.state == .failed) { Issue.record("\(await site.story(queue, id))") }
        #expect(job.attempt == 0)
        #expect(!job.message.isEmpty && !job.message.contains("ERROR"))
        #expect(site.files(in: site.movies).isEmpty)
    }

    @Test func aSiteThatDoesNotAnswerIsRetried() async throws {
        let site = try Site("queue-refused")
        defer { site.cleanUp() }
        // The server is gone, so the connection is refused.
        let address = site.server.url("video.mp4")
        site.server.stop()
        let queue = site.queue(clock: SkippableClock())
        let id = await queue.add(link(address))
        #expect(await eventually { await settled(queue, id) })
        let job = try #require(await queue.job(id))
        guard case .retrying = job.state else {
            Issue.record("expected a retry: \(await site.story(queue, id))")
            return
        }
        #expect(job.message == Messages.retrying(inSeconds: 15, retry: 1, of: 3))
        await queue.cancel(id)
    }

    @Test func aForcedKillLeavesTheJobPausedAndResumable() async throws {
        let site = try Site("queue-killed")
        defer { site.cleanUp() }
        let source = try await site.makeVideo("long.mp4")
        site.server.throttle(bytesPerSecond: 200_000)
        let harness = Bundle(for: RangeServer.self).bundleURL.deletingLastPathComponent().appendingPathComponent("QueueHarness")
        try #require(FileManager.default.isExecutableFile(atPath: harness.path), "the QueueHarness helper was not built at \(harness.path)")

        // "The app": a separate program running a real queue.
        let said = Said()
        let app = try ProcessRunner().start(ProcessRequest(executable: harness.path,
                                                           arguments: [site.paths.root.path, site.movies.path, site.server.url("long.mp4")],
                                                           environment: Real.registry.environment())) { said.add($0.text) }
        #expect(await eventually { said.lines.contains("downloading") }, "\(said.lines)")
        let id = try #require(said.lines.first { $0.hasPrefix("added ") }.flatMap { UUID(uuidString: String($0.dropFirst(6))) })
        let tool = try #require(site.tool(for: id))
        #expect(tool.isStillRunning)
        #expect(QueueStore(paths: site.paths).load().map(\.state) == [.running])
        // The tool keeps the newest data in memory for a moment; wait until some of the file is really on disk.
        let workspace = Workspace(paths: site.paths, job: id)
        #expect(await eventually { site.files(in: workspace.partial).contains { site.size(workspace.partial.appendingPathComponent($0)) > 150_000 } })

        // Killed outright: no goodbye, no clean-up.
        kill(app.processIdentifier, SIGKILL)
        let outcome = await app.waitUntilExit()
        #expect(outcome.signalled && outcome.status == SIGKILL)

        // The next launch.
        site.server.throttle(bytesPerSecond: 0)
        let queue = site.queue()
        let restored = await queue.restore()
        #expect(restored.map(\.id) == [id])
        let job = try #require(await queue.job(id))
        #expect(job.state == .paused)
        #expect(job.message == Messages.pausedBecauseClosed)
        #expect(job.source == .video)
        // Whatever the old launch left running is stopped, and nothing has started by itself.
        #expect(!tool.isStillRunning)
        let kept = site.files(in: workspace.partial).filter { $0.hasSuffix(".part") }
        #expect(kept.count == 1, "\(site.files(in: workspace.root))")
        let had = site.size(workspace.partial.appendingPathComponent(kept.first ?? ""))
        #expect(had > 150_000 && had < site.size(source))
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(await queue.job(id)?.state == .paused)
        #expect(site.size(workspace.partial.appendingPathComponent(kept.first ?? "")) == had)

        await queue.resume(id)
        if !(await eventually { await queue.job(id)?.state.isUnfinished == false }) { Issue.record("\(await site.story(queue, id))") }
        if !(await queue.job(id)?.state == .done) { Issue.record("\(await site.story(queue, id))") }
        #expect(site.server.requests.contains { $0.path == "/long.mp4" && $0.rangeStart == had }, "\(site.server.requests)")
        let file = site.movies.appendingPathComponent("127.0.0.1/long.mp4")
        #expect(await site.isWhole(file, like: source))
        #expect(site.files(in: site.paths.jobs).isEmpty)
    }

    @Test func quittingAndReopeningCarriesOn() async throws {
        let site = try Site("queue-quit")
        defer { site.cleanUp() }
        let source = try await site.makeVideo("long.mp4")
        site.server.throttle(bytesPerSecond: 200_000)
        let first = site.queue()
        await first.restore()
        let id = await first.add(link(site.server.url("long.mp4")))
        if !(await eventually { (await first.job(id)?.progress.fraction ?? 0) > 0.1 }) { Issue.record("\(await site.story(first, id))") }
        let tool = try #require(site.tool(for: id))
        await first.prepareForQuit()
        #expect(!tool.isStillRunning)
        #expect(await first.job(id)?.message == Messages.pausedBecauseClosed)

        site.server.throttle(bytesPerSecond: 0)
        let second = site.queue()
        #expect(await second.restore().map(\.state) == [.paused])
        await second.resume(id)
        if !(await eventually { await second.job(id)?.state.isUnfinished == false }) { Issue.record("\(await site.story(second, id))") }
        if !(await second.job(id)?.state == .done) { Issue.record("\(await site.story(second, id))") }
        #expect(site.server.requests.contains { $0.path == "/long.mp4" && ($0.rangeStart ?? 0) > 0 })
        #expect(await site.isWhole(site.movies.appendingPathComponent("127.0.0.1/long.mp4"), like: source))
    }
}

private final class Said: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}
