import Foundation
import Testing
@testable import Engine

// The worker end to end against a stand-in for the download tool: a script
// that answers a look-up, or pretends to download. Product code never runs
// a shell; this is only a fake tool. The real tools are in IntegrationTests.

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [JobEvent] = []
    func add(_ event: JobEvent) { lock.lock(); stored.append(event); lock.unlock() }
    var all: [JobEvent] { lock.lock(); defer { lock.unlock() }; return stored }
    var files: [String] { all.compactMap { if case .file(let path) = $0 { return path } else { return nil } } }
    var log: [String] { all.compactMap { if case .log(let line) = $0 { return line } else { return nil } } }
    var stages: [JobStage] { all.compactMap { if case .stage(let stage) = $0 { return stage } else { return nil } } }
    var progress: [JobProgress] { all.compactMap { if case .progress(let progress) = $0 { return progress } else { return nil } } }
}

/// The start of every stand-in: finds where the worker told the tool to put
/// finished files (`$home`), its scratch folder (`$temp`), the list of
/// finished files (`$list`), the archive (`$archive`) and the link (`$link`).
private let preamble = """
#!/bin/sh
home=""; temp=""; list=""; archive=""; lookup=0; prev=""; prev2=""; link=""
for a in "$@"; do
  if [ "$prev" = "-P" ]; then case "$a" in temp:*) temp="${a#temp:}";; *) home="$a";; esac; fi
  if [ "$prev2" = "--print-to-file" ] && [ "$prev" = "after_move:filepath" ]; then list="$a"; fi
  if [ "$prev" = "--download-archive" ]; then archive="$a"; fi
  if [ "$a" = "-J" ]; then lookup=1; fi
  prev2="$prev"; prev="$a"; link="$a"
done
finish() { printf '%s' "$2" > "$home/$1"; echo "$home/$1" >> "$list"; }

"""

private struct Harness {
    let root: URL
    let paths: AppPaths
    let worker: ToolJobWorker
    let events = Events()
    let destination: URL

    /// `ffmpeg` and `ffprobe` are stand-ins too, for the steps after a download.
    /// Without them those tools are simply not found.
    init(tool body: String, ffmpeg: String? = nil, ffprobe: String? = nil,
         clock: any EngineClock = SystemClock(), lookupTimeout: TimeInterval = 180) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("worker-tests-\(UUID().uuidString.prefix(8))", isDirectory: true).resolvingSymlinksInPath()
        paths = AppPaths(root: root.appendingPathComponent("support"))
        try paths.createFolders()
        destination = root.appendingPathComponent("Movies")
        let tool = root.appendingPathComponent("yt-dlp")
        try Data((preamble + body + "\n").utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        var overrides: [Tool: String] = [.ytdlp: tool.path]
        for (kind, script) in [(Tool.ffmpeg, ffmpeg), (Tool.ffprobe, ffprobe)] {
            guard let script else { continue }
            let file = root.appendingPathComponent(kind.rawValue)
            try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            overrides[kind] = file.path
        }
        // Only the stand-ins are found: no real tool is ever run from here.
        let known = Set(overrides.values)
        let registry = ToolRegistry(managedFolder: root.appendingPathComponent("no-tools").path, overrides: overrides,
                                    isExecutable: { known.contains($0) })
        var worker = ToolJobWorker(tools: registry, runner: ProcessRunner(stopGrace: 0.3, drainTimeout: 1), clock: clock)
        worker.lookupTimeout = lookupTimeout
        worker.trash = FolderTrash(folder: root.appendingPathComponent("Trash"))
        self.worker = worker
    }

    func context(_ job: Job) -> JobContext {
        JobContext(workspace: Workspace(paths: paths, job: job.id),
                   folders: FolderRules(mainFolder: destination.path, audioFolder: root.appendingPathComponent("Music").path),
                   nameStyle: .title, archiveFile: paths.archiveFile.path)
    }

    func run(_ job: Job, context: JobContext? = nil) async -> JobOutcome {
        let events = self.events
        return await worker.run(job, context: context ?? self.context(job)) { events.add($0) }
    }

    func job(_ request: JobRequest) -> Job {
        Job(createdAt: Date(), request: request)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func delivered() -> [String] {
        ((try? FileManager.default.subpathsOfDirectory(atPath: destination.path)) ?? []).sorted()
    }
}

@Suite struct ToolJobWorkerTests {
    @Test func aVideoIsDownloadedInItsWorkspaceAndDeliveredUnderItsCleanName() async throws {
        let harness = try Harness(tool: """
        echo "[generic] Extracting URL: $link"
        echo "[[PROG]] 50.0%|1.00MiB/s|00:01|2.00MiB|NA|NA|NA|A talk"
        echo "[[PROG]]100.0%|1.00MiB/s|00:00|2.00MiB|NA|NA|NA|A talk"
        echo "[Merger] Merging formats"
        finish "A talk [talk].mp4" "video in $temp"
        echo "[MoveFiles] Moving file"
        """)
        defer { harness.cleanUp() }
        let job = harness.job(Sample.video())
        let outcome = await harness.run(job)

        let folder = harness.destination.appendingPathComponent("YouTube")
        #expect(outcome == .finished(message: Messages.savedTo(Naming.breadcrumb(folder.path)), warnings: []))
        #expect(harness.events.files == [folder.appendingPathComponent("A talk.mp4").path])
        #expect(harness.delivered() == ["YouTube", "YouTube/A talk.mp4"])
        // The tool was pointed at the workspace, never at the destination.
        let workspace = Workspace(paths: harness.paths, job: job.id)
        let written = try String(contentsOf: folder.appendingPathComponent("A talk.mp4"), encoding: .utf8)
        #expect(written == "video in \(workspace.partial.path)")
        #expect(harness.events.all.contains(.destination(folder.path)))
        #expect(harness.events.stages == [.starting, .downloading, .processing(Messages.stageMerging), .processing(Messages.stageFinishing), .finishing])
        #expect(harness.events.progress.map(\.fraction) == [0.5, 1])
        #expect(harness.events.progress.last?.size == "2.00MiB")
        // The log starts with the command, as it can be copied, and holds no progress lines.
        let log = harness.events.log
        #expect(log.first?.hasPrefix("$ ") == true)
        #expect(log.first?.contains("--no-playlist") == true)
        #expect(log.first?.contains(workspace.staging.path) == true)
        #expect(log.contains("[generic] Extracting URL: https://example.com/watch?v=talk"))
        #expect(!log.contains { $0.hasPrefix(YtdlpCommand.progressPrefix) })
        #expect(!FileManager.default.fileExists(atPath: workspace.toolRecord.path))
    }

    @Test func aFinishedDownloadIsRecordedInTheLibraryWithItsPicture() async throws {
        let harness = try Harness(tool: """
        thumbs=""; notes=""; prev=""; prev2=""
        for a in "$@"; do
          case "$a" in thumbnail:*) thumbs="${a#thumbnail:}"; thumbs="${thumbs%/*}";; esac
          if [ "$prev2" = "--print-to-file" ]; then case "$prev" in *title*) notes="$a";; esac; fi
          prev2="$prev"; prev="$a"
        done
        finish "A talk [talk].mp4" "video"
        printf 'jpg' > "$thumbs/talk.jpg"
        echo '{"filepath": "'"$home"'/A talk [talk].mp4", "id": "talk", "title": "A talk", "uploader": "Someone", "duration": 61, "extractor_key": "Generic", "webpage_url": "https://example.com/watch?v=talk"}' >> "$notes"
        """)
        defer { harness.cleanUp() }
        var worker = harness.worker
        let library = LibraryRepository(paths: harness.paths, trash: FolderTrash(folder: harness.root.appendingPathComponent("Trash")))
        worker.library = library
        let job = harness.job(Sample.video())
        let events = harness.events
        _ = await worker.run(job, context: harness.context(job)) { events.add($0) }

        let records = await library.records()
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.title == "A talk" && record.uploader == "Someone" && record.videoID == "talk")
        #expect(record.path == harness.destination.appendingPathComponent("YouTube/A talk.mp4").path)
        #expect(record.duration == "1:01" && record.archiveID == "generic talk" && !record.isCopy)
        #expect(library.thumbnailURL(named: record.thumbnail) != nil)
    }

    @Test func aChosenFolderAndNameStyleAreUsed() async throws {
        let harness = try Harness(tool: "finish 'A talk [talk].m4a' audio")
        defer { harness.cleanUp() }
        var request = Sample.video(preset: PresetCatalog.audioOnly)
        request.folder = harness.root.appendingPathComponent("Chosen").path
        let job = harness.job(request)
        var context = harness.context(job)
        context.nameStyle = .uploaderTitle
        let outcome = await harness.run(job, context: context)
        #expect(outcome == .finished(message: Messages.savedTo(Naming.breadcrumb(request.folder!)), warnings: []))
        #expect(harness.events.files == [request.folder! + "/Someone - A talk.m4a"])
        #expect(!harness.events.all.contains { if case .destination = $0 { return true } else { return false } })
    }

    @Test func audioGoesToTheAudioFolder() async throws {
        let harness = try Harness(tool: "finish 'A talk [talk].m4a' audio")
        defer { harness.cleanUp() }
        _ = await harness.run(harness.job(Sample.video(preset: PresetCatalog.audioOnly)))
        #expect(harness.events.files == [harness.root.appendingPathComponent("Music/A talk.m4a").path])
    }

    @Test func aPastedLinkIsLookedUpThenDownloaded() async throws {
        let harness = try Harness(tool: """
        if [ $lookup = 1 ]; then
          echo '{"id": "xyz", "title": "Found It", "uploader": "Maker", "extractor_key": "Vimeo", "webpage_url": "https://vimeo.com/xyz", "duration": 65}'
          exit 0
        fi
        finish "Found It [xyz].mp4" "from $link"
        """)
        defer { harness.cleanUp() }
        let outcome = await harness.run(harness.job(Sample.link()))
        let resolution = JobResolution(source: .video, link: "https://vimeo.com/xyz", title: "Found It", site: "Vimeo",
                                       facts: VideoFacts(id: "xyz", title: "Found It", uploader: "Maker"), duration: "1:05")
        #expect(harness.events.all.first == .resolved(resolution))
        let file = harness.destination.appendingPathComponent("Vimeo/Found It.mp4")
        #expect(harness.events.files == [file.path])
        // The download used the address the look-up gave.
        #expect(try String(contentsOf: file, encoding: .utf8) == "from https://vimeo.com/xyz")
        #expect(outcome == .finished(message: Messages.savedTo(Naming.breadcrumb(file.deletingLastPathComponent().path)), warnings: []))
    }

    @Test func aLookupThatFindsAListDownloadsItAsAPlaylist() async throws {
        let harness = try Harness(tool: """
        if [ $lookup = 1 ]; then
          echo '{"_type": "playlist", "title": "Best Of", "extractor_key": "YoutubeTab", "webpage_url": "https://example.com/list", "entries": [{"id": "a", "title": "A"}, {"id": "b", "title": "B"}]}'
          exit 0
        fi
        echo "archive=$archive"
        echo "[download] Downloading item 1 of 2"
        echo "[[PROG]]100.0%|1.00MiB/s|00:00|1.00MiB|NA|1|2|A"
        finish "001 - A [a].mp4" one
        echo "[download] Downloading item 2 of 2"
        echo "[[PROG]] 50.0%|1.00MiB/s|00:01|1.00MiB|NA|2|2|B"
        finish "002 - B [b].mp4" two
        echo "[MoveFiles] done"
        """)
        defer { harness.cleanUp() }
        let job = harness.job(Sample.link())
        let outcome = await harness.run(job)
        let folder = harness.destination.appendingPathComponent("YouTube/Best Of")
        #expect(outcome == .finished(message: Messages.filesSavedTo(2, Naming.breadcrumb(folder.path)), warnings: []))
        #expect(harness.delivered() == ["YouTube", "YouTube/Best Of", "YouTube/Best Of/001 - A.mp4", "YouTube/Best Of/002 - B.mp4"])
        // Progress counts over the whole list.
        #expect(harness.events.progress.compactMap(\.fraction) == [0, 0.5, 0.5, 0.75])
        // A playlist keeps its own archive in the workspace, and the command says so.
        let workspace = Workspace(paths: harness.paths, job: job.id)
        #expect(harness.events.log.contains("archive=\(workspace.archive.path)"))
        #expect(harness.events.log.first?.contains("--yes-playlist") == true)
    }

    @Test func playlistItemsAreDeliveredAsTheyFinishNotAtTheEnd() async throws {
        let harness = try Harness(tool: """
        finish "001 - A [a].mp4" one
        echo "[download] Downloading item 2 of 3"
        while [ ! -f "$home/../go" ]; do /bin/sleep 0.05; done
        finish "002 - B [b].mp4" two
        echo "[MoveFiles] done"
        """)
        defer { harness.cleanUp() }
        let job = harness.job(Sample.playlist())
        let workspace = Workspace(paths: harness.paths, job: job.id)
        let running = Task { await harness.run(job) }
        // The first item is in its folder while the second is still downloading.
        #expect(await eventually { harness.events.files.count == 1 })
        #expect(harness.events.files.first?.hasSuffix("YouTube/A list/001 - A.mp4") == true)
        FileManager.default.createFile(atPath: workspace.root.appendingPathComponent("go").path, contents: nil)
        let outcome = await running.value
        #expect(harness.events.files.count == 2)
        if case .finished = outcome {} else { Issue.record("\(outcome)") }
    }

    @Test func aPlaylistWithItemsThatFailedIsDoneWithWarnings() async throws {
        let harness = try Harness(tool: """
        echo "[download] Downloading item 1 of 3"
        finish "001 - A [a].mp4" one
        echo "[download] Downloading item 2 of 3"
        echo "ERROR: [youtube] b: Private video. Sign in if you've been granted access to this video" >&2
        echo "[download] Downloading item 3 of 3"
        echo "ERROR: [youtube] c: Private video. Sign in if you've been granted access to this video" >&2
        exit 1
        """)
        defer { harness.cleanUp() }
        let outcome = await harness.run(harness.job(Sample.playlist()))
        let place = Naming.breadcrumb(harness.destination.appendingPathComponent("YouTube/A list").path)
        #expect(outcome == .finished(message: Messages.someSavedTo(1, of: 3, place),
                                     warnings: ["This video is private, so it can't be downloaded."]))
    }

    @Test func whatTheToolLeavesBesideTheVideoIsDeliveredToo() async throws {
        let harness = try Harness(tool: """
        mkdir -p "$home/A talk (chapters)"
        printf one > "$home/A talk (chapters)/001 Intro.mp4"
        printf words > "$home/A talk [talk].description"
        finish "A talk [talk].mp4" video
        """)
        defer { harness.cleanUp() }
        _ = await harness.run(harness.job(Sample.video()))
        #expect(harness.delivered() == ["YouTube", "YouTube/A talk (chapters)", "YouTube/A talk (chapters)/001 Intro.mp4",
                                        "YouTube/A talk.description", "YouTube/A talk.mp4"])
        // Only the video itself is reported as a finished file.
        #expect(harness.events.files.count == 1)
    }

    @Test func aFailureIsOneSentenceAndSaysWhetherWaitingMayHelp() async throws {
        let dropped = try Harness(tool: """
        echo "[download] Destination: a.mp4"
        echo "ERROR: [download] Got error: HTTPConnectionPool(host='example.com', port=443): Read timed out." >&2
        exit 1
        """)
        defer { dropped.cleanUp() }
        #expect(await dropped.run(dropped.job(Sample.video())) == .failed(message: Messages.unreachable, retryable: true))

        let gone = try Harness(tool: "echo 'ERROR: [youtube] abc: Private video. Sign in if you have access' >&2; exit 1")
        defer { gone.cleanUp() }
        #expect(await gone.run(gone.job(Sample.video())) == .failed(message: "This video is private, so it can't be downloaded.", retryable: false))

        let silent = try Harness(tool: "echo '[download] something'; exit 3")
        defer { silent.cleanUp() }
        #expect(await silent.run(silent.job(Sample.video())) == .failed(message: Messages.downloadFailed, retryable: false))

        let nothing = try Harness(tool: "exit 0")
        defer { nothing.cleanUp() }
        #expect(await nothing.run(nothing.job(Sample.video())) == .failed(message: Messages.nothingSaved, retryable: false))
        #expect(nothing.delivered().isEmpty)
    }

    @Test func aFailedDownloadDeliversNoStrayFiles() async throws {
        let harness = try Harness(tool: """
        printf words > "$home/A talk [talk].description"
        printf half > "$temp/A talk [talk].mp4.part"
        echo "ERROR: unable to download video data: HTTP Error 503: Service Unavailable" >&2
        exit 1
        """)
        defer { harness.cleanUp() }
        let job = harness.job(Sample.video())
        let outcome = await harness.run(job)
        if case .failed(_, let retryable) = outcome { #expect(retryable) } else { Issue.record("\(outcome)") }
        #expect(harness.delivered().isEmpty)
        // What was downloaded stays in the workspace for the next attempt.
        #expect(FileManager.default.fileExists(atPath: Workspace(paths: harness.paths, job: job.id).partial.appendingPathComponent("A talk [talk].mp4.part").path))
    }

    @Test func somethingAlreadyDownloadedIsNotAFailure() async throws {
        let harness = try Harness(tool: "echo '[download] talk: A talk has already been recorded in the archive'")
        defer { harness.cleanUp() }
        var request = Sample.video()
        request.recipe.useArchive = true
        let outcome = await harness.run(harness.job(request))
        #expect(outcome == .finished(message: Messages.alreadyDownloaded, warnings: []))
        // A recipe that asks for the archive gets the person's own, not a private one.
        #expect(harness.events.log.first?.contains("--download-archive \(DisplayCommand.shellQuote(harness.paths.archiveFile.path))") == true)
    }

    @Test func aFailedLookupNeverStartsADownload() async throws {
        let live = try Harness(tool: """
        if [ $lookup = 1 ]; then echo '{"id": "x", "title": "Now", "live_status": "is_live", "extractor_key": "Youtube"}'; exit 0; fi
        finish "should not happen.mp4" x
        """)
        defer { live.cleanUp() }
        #expect(await live.run(live.job(Sample.link())) == .failed(message: Messages.live, retryable: false))
        #expect(live.delivered().isEmpty)

        let offline = try Harness(tool: "echo 'ERROR: [generic] Unable to download webpage: <urlopen error [Errno 8] nodename nor servname provided, or not known>' >&2; exit 1")
        defer { offline.cleanUp() }
        #expect(await offline.run(offline.job(Sample.link())) == .failed(message: Messages.unreachable, retryable: true))

        let odd = try Harness(tool: "echo 'ERROR: The read operation timed out' >&2; exit 1")
        defer { odd.cleanUp() }
        #expect(await odd.run(odd.job(Sample.link())) == .failed(message: Messages.unreachable, retryable: true))

        // A problem the app has no sentence for is told in the tool's words; its wording decides about another go.
        let unknown = try Harness(tool: "echo 'ERROR: Something nobody has seen: broken pipe' >&2; exit 1")
        defer { unknown.cleanUp() }
        #expect(await unknown.run(unknown.job(Sample.link())) == .failed(message: "Something nobody has seen: broken pipe", retryable: true))
    }

    @Test func aLookupThatTakesTooLongIsGivenUpAndMayBeRetried() async throws {
        let clock = FakeClock()
        let harness = try Harness(tool: "if [ $lookup = 1 ]; then /bin/sleep 30; fi", clock: clock, lookupTimeout: 120)
        defer { harness.cleanUp() }
        let running = Task { await harness.run(harness.job(Sample.link())) }
        #expect(await eventually { clock.sleeperCount == 1 })
        clock.advance(by: 119)
        try await Task.sleep(nanoseconds: 50_000_000)
        clock.advance(by: 1)
        let started = Date()
        #expect(await running.value == .failed(message: Messages.lookupTimedOut, retryable: true))
        // The tool was stopped, not waited for.
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func cancellingStopsTheToolKeepsTheWorkspaceAndReportsStopped() async throws {
        let harness = try Harness(tool: """
        printf half > "$temp/A talk [talk].mp4.part"
        echo "[[PROG]] 10.0%|1.00MiB/s|00:09|10.00MiB|NA|NA|NA|A talk"
        /bin/sleep 30
        finish "A talk [talk].mp4" video
        """)
        defer { harness.cleanUp() }
        let job = harness.job(Sample.video())
        let workspace = Workspace(paths: harness.paths, job: job.id)
        let running = Task { await harness.run(job) }
        #expect(await eventually { !harness.events.progress.isEmpty })
        // While it runs, the workspace says which process is working in it.
        let record = try JSONDecoder().decode(ProcessIdentity.self, from: Data(contentsOf: workspace.toolRecord))
        #expect(record.isStillRunning)

        running.cancel()
        #expect(await running.value == .stopped)
        #expect(!record.isStillRunning)
        #expect(!FileManager.default.fileExists(atPath: workspace.toolRecord.path))
        #expect(FileManager.default.fileExists(atPath: workspace.partial.appendingPathComponent("A talk [talk].mp4.part").path))
        #expect(harness.delivered().isEmpty)
    }

    @Test func cancellingDuringALookupReportsStopped() async throws {
        let harness = try Harness(tool: "if [ $lookup = 1 ]; then echo started >&2; /bin/sleep 30; fi")
        defer { harness.cleanUp() }
        let running = Task { await harness.run(harness.job(Sample.link())) }
        try await Task.sleep(nanoseconds: 300_000_000)
        running.cancel()
        #expect(await running.value == .stopped)
    }

    @Test func itemsFinishedBeforeAStopAreKept() async throws {
        let harness = try Harness(tool: """
        finish "001 - A [a].mp4" one
        echo "[[PROG]] 10.0%|1.00MiB/s|00:09|10.00MiB|NA|2|3|B"
        /bin/sleep 30
        """)
        defer { harness.cleanUp() }
        let running = Task { await harness.run(harness.job(Sample.playlist())) }
        #expect(await eventually { !harness.events.progress.isEmpty })
        running.cancel()
        #expect(await running.value == .stopped)
        #expect(harness.delivered() == ["YouTube", "YouTube/A list", "YouTube/A list/001 - A.mp4"])
        #expect(harness.events.files.count == 1)
    }

    @Test func aDestinationThatCannotBeWrittenFailsAndKeepsTheFileForRetry() async throws {
        let harness = try Harness(tool: "finish 'A talk [talk].mp4' video")
        defer { harness.cleanUp() }
        // A file where the destination folder should be.
        FileManager.default.createFile(atPath: harness.destination.path, contents: Data("in the way".utf8))
        let job = harness.job(Sample.video())
        let blocked = Naming.breadcrumb(harness.destination.appendingPathComponent("YouTube").path)
        #expect(await harness.run(job) == .failed(message: Messages.destinationUnwritable(blocked), retryable: false))
        let workspace = Workspace(paths: harness.paths, job: job.id)
        #expect(FileManager.default.fileExists(atPath: workspace.staging.appendingPathComponent("A talk [talk].mp4").path))

        // Once the folder can be written, another run delivers it.
        try FileManager.default.removeItem(at: harness.destination)
        if case .finished = await harness.run(job) {} else { Issue.record("the second run should deliver") }
        #expect(harness.delivered() == ["YouTube", "YouTube/A talk.mp4"])
    }

    @Test func aRecipeThatCannotRunFailsBeforeAnyToolIsStarted() async throws {
        let harness = try Harness(tool: "finish 'x.mp4' x")
        defer { harness.cleanUp() }
        var request = Sample.video()
        request.recipe.extraArguments = "--exec rm"
        let outcome = await harness.run(harness.job(request))
        if case .failed(let message, let retryable) = outcome {
            #expect(message.contains("--exec"))
            #expect(!retryable)
        } else {
            Issue.record("\(outcome)")
        }
        #expect(harness.delivered().isEmpty)
    }

    @Test func withoutTheDownloadToolNothingRuns() async throws {
        let harness = try Harness(tool: "exit 0")
        defer { harness.cleanUp() }
        let registry = ToolRegistry(managedFolder: "/nonexistent", overrides: [:], isExecutable: { _ in false })
        let worker = ToolJobWorker(tools: registry)
        let job = harness.job(Sample.video())
        #expect(await worker.run(job, context: harness.context(job)) { _ in } == .failed(message: Messages.noTool, retryable: false))
    }

    @Test func longLinesFromTheToolAreCutBeforeTheyReachTheLog() async throws {
        let harness = try Harness(tool: """
        /usr/bin/printf '%09000d\\n' 7
        finish 'A talk [talk].mp4' video
        """)
        defer { harness.cleanUp() }
        _ = await harness.run(harness.job(Sample.video()))
        let long = try #require(harness.events.log.first { $0.hasPrefix("0000") })
        #expect(long.utf8.count == JobLog.maxLineLength + LineSplitter.truncationMark.utf8.count)
        #expect(long.hasSuffix(LineSplitter.truncationMark))
    }
}

// MARK: - The steps after a download

/// An ffprobe that says: one AAC sound stream.
private let probeSound = #"echo '{"format": {"duration": "10.0"}, "streams": [{"codec_type": "audio", "codec_name": "aac", "sample_rate": "44100"}]}'"#
/// An ffprobe that says: a ten-second VP9 video with Opus sound.
private let probeVideo = #"echo '{"format": {"duration": "10.0"}, "streams": [{"codec_type": "video", "codec_name": "vp9", "width": 640, "height": 360}, {"codec_type": "audio", "codec_name": "opus"}]}'"#
/// An FFmpeg that "measures" when asked to write nothing, and otherwise writes "<word>" into its last argument.
private func converter(writing word: String) -> String {
    """
    for last; do :; done
    if [ "$last" = "-" ]; then echo '{"input_i": "-30.0", "input_tp": "-20.0", "input_lra": "1.0", "input_thresh": "-40.0", "target_offset": "0.1"}' >&2; exit 0; fi
    echo "out_time_us=5000000"
    printf '\(word)' > "$last"
    """
}

private func evenedAudio() -> JobRequest {
    var request = Sample.video(preset: PresetCatalog.audioOnly)
    request.recipe.evenLoudness = true
    return request
}

private func reencoded(replace: Bool, encoder: VideoEncoder = .x264) -> JobRequest {
    var request = Sample.video()
    request.recipe.encodeEnabled = true
    request.recipe.encoder = encoder
    request.recipe.container = .mp4
    request.recipe.replaceOriginal = replace
    return request
}

@Suite struct PostDownloadStepTests {
    @Test func aPlainDownloadRunsNoStepAndNeedsNoConverter() async throws {
        let harness = try Harness(tool: "finish 'A talk [talk].mp4' video")
        defer { harness.cleanUp() }
        let folder = harness.destination.appendingPathComponent("YouTube")
        #expect(await harness.run(harness.job(Sample.video())) == .finished(message: Messages.savedTo(Naming.breadcrumb(folder.path)), warnings: []))
        #expect(harness.events.stages == [.starting, .finishing])
    }

    @Test func theVolumeIsEvenedOutBeforeTheFileIsDelivered() async throws {
        let harness = try Harness(tool: "finish 'A talk [talk].m4a' downloaded", ffmpeg: converter(writing: "evened"), ffprobe: probeSound)
        defer { harness.cleanUp() }
        let job = harness.job(evenedAudio())
        let outcome = await harness.run(job)
        let file = harness.root.appendingPathComponent("Music/A talk.m4a")
        #expect(outcome == .finished(message: Messages.savedTo(Naming.breadcrumb(file.deletingLastPathComponent().path)), warnings: []))
        #expect(try String(contentsOf: file, encoding: .utf8) == "evened")
        #expect(harness.events.files == [file.path])
        #expect(harness.events.stages.contains(.processing(Messages.stageLoudness)))
        // The second pass was given the first one's figures, and is in the log.
        let pass = try #require(harness.events.log.first { $0.hasPrefix("$ ffmpeg") })
        #expect(pass.contains("measured_I=-30.00") && pass.contains("linear=true"))
        // The download command lists the finished file, and the step ran before delivery, not after.
        let stageIndex = try #require(harness.events.all.firstIndex(of: .stage(.processing(Messages.stageLoudness))))
        #expect(stageIndex < (try #require(harness.events.all.firstIndex(of: .file(file.path)))))
    }

    @Test func aFailedStepLeavesTheDownloadIntactAndTheJobDoneWithANote() async throws {
        let harness = try Harness(tool: "finish 'A talk [talk].m4a' downloaded", ffmpeg: "echo 'Conversion failed!' >&2; exit 1", ffprobe: probeSound)
        defer { harness.cleanUp() }
        let job = harness.job(evenedAudio())
        let outcome = await harness.run(job)
        let file = harness.root.appendingPathComponent("Music/A talk.m4a")
        #expect(outcome == .finished(message: Messages.savedTo(Naming.breadcrumb(file.deletingLastPathComponent().path)), warnings: [Messages.loudnessFailed]))
        // Byte for byte what the download tool wrote.
        #expect(try String(contentsOf: file, encoding: .utf8) == "downloaded")
        #expect(harness.events.log.contains(Messages.loudnessFailed))
        // Nothing half-made was delivered with it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == ["A talk.m4a"])
    }

    @Test func withoutTheConverterTheFileIsStillSavedWithANote() async throws {
        let harness = try Harness(tool: "finish 'A talk [talk].m4a' downloaded")
        defer { harness.cleanUp() }
        let outcome = await harness.run(harness.job(evenedAudio()))
        guard case .finished(_, let warnings) = outcome else { Issue.record("\(outcome)"); return }
        #expect(warnings == [Messages.noConverter])
        #expect(try String(contentsOf: harness.root.appendingPathComponent("Music/A talk.m4a"), encoding: .utf8) == "downloaded")
    }

    @Test func aFileThatCannotBeReadIsLeftAsItIs() async throws {
        // The converter works, but nothing can say what is in the file.
        let harness = try Harness(tool: "finish 'A talk [talk].m4a' downloaded", ffmpeg: converter(writing: "evened"), ffprobe: "exit 1")
        defer { harness.cleanUp() }
        let outcome = await harness.run(harness.job(evenedAudio()))
        guard case .finished(_, let warnings) = outcome else { Issue.record("\(outcome)"); return }
        #expect(warnings == [Messages.loudnessFailed])
        #expect(try String(contentsOf: harness.root.appendingPathComponent("Music/A talk.m4a"), encoding: .utf8) == "downloaded")
    }

    @Test func aReencodedVideoReplacesTheDownloadWhichGoesToTheTrash() async throws {
        let harness = try Harness(tool: "finish 'A talk [talk].webm' downloaded", ffmpeg: converter(writing: "encoded"), ffprobe: probeVideo)
        defer { harness.cleanUp() }
        let outcome = await harness.run(harness.job(reencoded(replace: true)))
        let folder = harness.destination.appendingPathComponent("YouTube")
        #expect(outcome == .finished(message: Messages.savedTo(Naming.breadcrumb(folder.path)), warnings: []))
        #expect(harness.delivered() == ["YouTube", "YouTube/A talk.mp4"])
        #expect(try String(contentsOf: folder.appendingPathComponent("A talk.mp4"), encoding: .utf8) == "encoded")
        #expect(harness.events.files == [folder.appendingPathComponent("A talk.mp4").path])
        #expect(try String(contentsOf: harness.root.appendingPathComponent("Trash/A talk [talk].webm"), encoding: .utf8) == "downloaded")
        #expect(harness.events.log.contains(Messages.originalInTrash))
        // Its progress was shown as it went.
        #expect(harness.events.stages.contains(.processing(Messages.stageEncoding(percent: 50))))
    }

    @Test func withoutReplacingBothFilesAreDeliveredUnderTheSameCleanName() async throws {
        let harness = try Harness(tool: "finish 'A talk [talk].webm' downloaded", ffmpeg: converter(writing: "encoded"), ffprobe: probeVideo)
        defer { harness.cleanUp() }
        let outcome = await harness.run(harness.job(reencoded(replace: false)))
        guard case .finished(_, let warnings) = outcome else { Issue.record("\(outcome)"); return }
        #expect(warnings.isEmpty)
        #expect(harness.delivered() == ["YouTube", "YouTube/A talk.encoded.mp4", "YouTube/A talk.webm"])
        #expect(!FileManager.default.fileExists(atPath: harness.root.appendingPathComponent("Trash").path))
    }

    @Test func whenTheHardwareRefusesTheSoftwareEncoderTakesOver() async throws {
        let ffmpeg = """
        for a in "$@"; do if [ "$a" = "hevc_videotoolbox" ]; then echo 'Error: cannot create compression session' >&2; exit 1; fi; done
        for last; do :; done
        printf software > "$last"
        """
        let harness = try Harness(tool: "finish 'A talk [talk].webm' downloaded", ffmpeg: ffmpeg, ffprobe: probeVideo)
        defer { harness.cleanUp() }
        let outcome = await harness.run(harness.job(reencoded(replace: true, encoder: .videoToolboxHEVC)))
        guard case .finished(_, let warnings) = outcome else { Issue.record("\(outcome)"); return }
        #expect(warnings.isEmpty)
        #expect(try String(contentsOf: harness.destination.appendingPathComponent("YouTube/A talk.mp4"), encoding: .utf8) == "software")
        #expect(harness.events.log.contains(Messages.encodeFallback))
        #expect(harness.events.log.contains("Error: cannot create compression session"))
    }

    @Test func aReencodeThatFailsLeavesTheDownloadAndNothingInTheTrash() async throws {
        let harness = try Harness(tool: "finish 'A talk [talk].webm' downloaded", ffmpeg: "echo 'Unknown encoder' >&2; exit 1", ffprobe: probeVideo)
        defer { harness.cleanUp() }
        let outcome = await harness.run(harness.job(reencoded(replace: true)))
        guard case .finished(_, let warnings) = outcome else { Issue.record("\(outcome)"); return }
        #expect(warnings == [Messages.encodeFailed])
        #expect(harness.delivered() == ["YouTube", "YouTube/A talk.webm"])
        #expect(try String(contentsOf: harness.destination.appendingPathComponent("YouTube/A talk.webm"), encoding: .utf8) == "downloaded")
        #expect(!FileManager.default.fileExists(atPath: harness.root.appendingPathComponent("Trash").path))
        #expect(harness.events.log.contains("Unknown encoder"))
    }

    @Test func aStepThatIsStoppedLeavesTheFileForTheNextRunWhichFinishesIt() async throws {
        let harness = try Harness(tool: "finish 'A talk [talk].m4a' downloaded", ffmpeg: "echo started >&2; /bin/sleep 30", ffprobe: probeSound)
        defer { harness.cleanUp() }
        let job = harness.job(evenedAudio())
        let workspace = Workspace(paths: harness.paths, job: job.id)
        let running = Task { await harness.run(job) }
        #expect(await eventually { FileManager.default.fileExists(atPath: workspace.stepToolRecord.path) })
        let record = try JSONDecoder().decode(ProcessIdentity.self, from: Data(contentsOf: workspace.stepToolRecord))
        running.cancel()
        let stopped = await running.value
        #expect(stopped == .stopped, "\(harness.events.log)")
        // The step's tool is gone, nothing was delivered, and the download waits untouched in the workspace.
        #expect(!record.isStillRunning && !FileManager.default.fileExists(atPath: workspace.stepToolRecord.path))
        #expect(harness.delivered().isEmpty && harness.events.files.isEmpty)
        #expect(try String(contentsOf: workspace.staging.appendingPathComponent("A talk [talk].m4a"), encoding: .utf8) == "downloaded")

        // The next run finds the tool has nothing new to download; the step runs and the file is delivered.
        let second = try Harness(tool: "echo '[download] A talk [talk].m4a has already been downloaded'", ffmpeg: converter(writing: "evened"), ffprobe: probeSound)
        defer { second.cleanUp() }
        var context = harness.context(job)
        context.workspace = workspace
        let outcome = await second.worker.run(job, context: context) { second.events.add($0) }
        guard case .finished(_, let warnings) = outcome else { Issue.record("\(outcome)"); return }
        #expect(warnings.isEmpty)
        #expect(try String(contentsOf: harness.root.appendingPathComponent("Music/A talk.m4a"), encoding: .utf8) == "evened")
    }

    // MARK: Chapters from comments

    /// A download tool that answers the request for details with `details`,
    /// and on the download says whether it was handed prepared details.
    private func commentTool(details: String) -> String {
        """
        for a in "$@"; do if [ "$a" = "--dump-single-json" ]; then cat <<'JSON'
        \(details)
        JSON
        exit 0; fi; done
        info=""; p=""
        for a in "$@"; do if [ "$p" = "--load-info-json" ]; then info="$a"; fi; p="$a"; done
        if [ -n "$info" ]; then /bin/cp "$info" "$home/A talk [talk].info"; fi
        finish 'A talk [talk].mp4' video
        """
    }

    private let withList = #"{"id": "talk", "title": "A talk", "duration": 600.0, "requested_formats": [{"format_id": "1"}], "comments": [{"id": "c1", "author": "Listener", "like_count": 4, "text": "0:00 Intro\n2:00 Middle\n5:00 End"}]}"#
    private let withoutList = #"{"id": "talk", "title": "A talk", "duration": 600.0, "comments": [{"id": "c1", "author": "Listener", "text": "Great talk"}]}"#

    private func fromComments(_ source: ChapterSource = .comments) -> JobRequest {
        var request = Sample.video()
        request.recipe.chapterSource = source
        return request
    }

    @Test func chaptersFromACommentArePutIntoTheDetailsTheDownloadLoads() async throws {
        let harness = try Harness(tool: commentTool(details: withList))
        defer { harness.cleanUp() }
        let outcome = await harness.run(harness.job(fromComments()))
        guard case .finished(_, let warnings) = outcome else { Issue.record("\(outcome)"); return }
        #expect(warnings.isEmpty)
        #expect(harness.events.stages.first == .processing(Messages.stageCommentChapters))
        #expect(harness.events.log.contains(Messages.commentChaptersUsed(3, author: "Listener")))
        // What the download tool was handed: the chapters, and none of the earlier run's choices or the comments.
        let handed = harness.destination.appendingPathComponent("YouTube/A talk.info")
        let info = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: handed)) as? [String: Any])
        #expect((info["chapters"] as? [[String: Any]])?.compactMap { $0["title"] as? String } == ["Intro", "Middle", "End"])
        #expect((info["chapters"] as? [[String: Any]])?.compactMap { ($0["end_time"] as? NSNumber)?.doubleValue } == [120, 300, 600])
        #expect(info["requested_formats"] == nil && info["comments"] == nil)
        // The log's command is still one a person can copy: it names the link, not the app's file.
        #expect(harness.events.log.first { $0.hasPrefix("$ ") }?.contains("load-info-json") == false)
    }

    @Test func theCommentThatWasPickedIsTheOneUsed() async throws {
        // Two lists: the longer one would win by itself; the person picked the shorter.
        let two = #"{"id": "talk", "title": "A talk", "duration": 600.0, "comments": [{"id": "long", "author": "Thorough", "text": "0:00 A\n1:00 B\n2:00 C\n3:00 D"}, {"id": "short", "author": "Brief", "text": "0:00 One\n4:00 Two\n8:00 Three"}]}"#
        let harness = try Harness(tool: commentTool(details: two))
        defer { harness.cleanUp() }
        var request = fromComments()
        request.chapterComment = "short"
        let outcome = await harness.run(harness.job(request))
        guard case .finished(_, let warnings) = outcome else { Issue.record("\(outcome)"); return }
        #expect(warnings.isEmpty)
        #expect(harness.events.log.contains(Messages.commentChaptersUsed(3, author: "Brief")))

        // A picked comment that is no longer there: the video is saved without those chapters, with a note.
        let gone = try Harness(tool: commentTool(details: two))
        defer { gone.cleanUp() }
        request.chapterComment = "deleted"
        guard case .finished(_, let notes) = await gone.run(gone.job(request)) else { Issue.record("not finished"); return }
        #expect(notes == [Messages.commentChaptersGone])
    }

    @Test func noChapterListInTheCommentsIsANoteNotAFailure() async throws {
        let harness = try Harness(tool: commentTool(details: withoutList))
        defer { harness.cleanUp() }
        let outcome = await harness.run(harness.job(fromComments()))
        let folder = harness.destination.appendingPathComponent("YouTube")
        #expect(outcome == .finished(message: Messages.savedTo(Naming.breadcrumb(folder.path)), warnings: [Messages.commentChaptersNone]))
        // The video was downloaded the ordinary way, from its link.
        #expect(harness.delivered() == ["YouTube", "YouTube/A talk.mp4"])
    }

    @Test func onlyWhenMissingReadsTheCommentsOnlyWhenTheVideoHasNoChapters() async throws {
        let own = #"{"id": "talk", "title": "A talk", "duration": 600.0, "chapters": [{"title": "Own", "start_time": 0, "end_time": 600}]}"#
        let harness = try Harness(tool: commentTool(details: own))
        defer { harness.cleanUp() }
        _ = await harness.run(harness.job(fromComments(.commentsIfMissing)))
        #expect(harness.events.stages.first == .processing(Messages.stageCheckingChapters))
        #expect(!harness.events.stages.contains(.processing(Messages.stageCommentChapters)))
        #expect(harness.events.log.contains(Messages.commentChaptersKeptOwn))

        // No chapters of its own and none in the comments: quietly without, and no note.
        let bare = try Harness(tool: commentTool(details: withoutList))
        defer { bare.cleanUp() }
        let outcome = await bare.run(bare.job(fromComments(.commentsIfMissing)))
        guard case .finished(_, let warnings) = outcome else { Issue.record("\(outcome)"); return }
        #expect(warnings.isEmpty)
        #expect(bare.events.stages.prefix(2) == [.processing(Messages.stageCheckingChapters), .processing(Messages.stageCommentChapters)])
    }

    @Test func commentsThatCannotBeReadAndPlaylistsCarryOnWithANote() async throws {
        let broken = try Harness(tool: """
        for a in "$@"; do if [ "$a" = "--dump-single-json" ]; then echo 'ERROR: unable to download webpage' >&2; exit 1; fi; done
        finish 'A talk [talk].mp4' video
        """)
        defer { broken.cleanUp() }
        guard case .finished(_, let warnings) = await broken.run(broken.job(fromComments())) else { Issue.record("not finished"); return }
        #expect(warnings == [Messages.commentChaptersUnreadable])

        let list = try Harness(tool: """
        echo "$home/A list - one [1].mp4" > /dev/null
        finish '001 - One [1].mp4' one
        """)
        defer { list.cleanUp() }
        var request = Sample.playlist()
        request.recipe.chapterSource = .comments
        guard case .finished(_, let notes) = await list.run(list.job(request)) else { Issue.record("not finished"); return }
        #expect(notes == [Messages.commentChaptersOneVideoOnly])
    }

    @Test func cancellingWhileTheCommentsAreReadReportsStopped() async throws {
        let harness = try Harness(tool: "echo started >&2; /bin/sleep 30")
        defer { harness.cleanUp() }
        let running = Task { await harness.run(harness.job(fromComments())) }
        try await Task.sleep(nanoseconds: 300_000_000)
        running.cancel()
        #expect(await running.value == .stopped)
        #expect(harness.delivered().isEmpty)
    }
}
