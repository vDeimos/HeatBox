import Foundation
import Testing
@testable import Engine

private func scratch(_ name: String) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.resolvingSymlinksInPath()
}

private func write(_ text: String, to file: URL) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: file)
}

private func names(in folder: URL) -> [String] {
    ((try? FileManager.default.subpathsOfDirectory(atPath: folder.path)) ?? []).sorted()
}

private func text(_ path: String) -> String? {
    try? String(contentsOfFile: path, encoding: .utf8)
}

@Suite struct WorkspaceTests {
    @Test func aWorkspaceIsAPrivateFolderNamedByTheJob() throws {
        let root = try scratch("workspace")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let id = UUID()
        let workspace = Workspace(paths: paths, job: id)
        #expect(workspace.root == paths.workspace(forJob: id))
        #expect(!workspace.exists)
        try workspace.create()
        try workspace.create()
        #expect(workspace.exists)
        #expect(workspace.staging.path == workspace.root.path + "/files")
        #expect(workspace.partial.path == workspace.root.path + "/partial")
        #expect(workspace.fileList.deletingLastPathComponent() == workspace.root)
        #expect(workspace.archive.deletingLastPathComponent() == workspace.root)
        let permissions = try FileManager.default.attributesOfItem(atPath: workspace.root.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.int16Value == 0o700)
        workspace.remove()
        #expect(!workspace.exists)
        workspace.remove()
    }

    @Test func atLaunchFoldersOfKnownJobsAreKeptAndOthersRemoved() throws {
        let root = try scratch("reconcile")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        try paths.createFolders()
        let kept = UUID(), orphan = UUID()
        try Workspace(paths: paths, job: kept).create()
        try Workspace(paths: paths, job: orphan).create()
        try write("partial", to: Workspace(paths: paths, job: kept).partial.appendingPathComponent("a.part"))
        // Something the app did not make is not the app's to remove.
        try write("mine", to: paths.jobs.appendingPathComponent("notes.txt"))
        try FileManager.default.createDirectory(at: paths.jobs.appendingPathComponent("not-a-job"), withIntermediateDirectories: true)

        #expect(Workspace.reconcile(paths: paths, keeping: [kept]) == [orphan])
        #expect(names(in: paths.jobs).filter { !$0.contains("/") } == [kept.uuidString.lowercased(), "not-a-job", "notes.txt"].sorted())
        #expect(FileManager.default.fileExists(atPath: Workspace(paths: paths, job: kept).partial.appendingPathComponent("a.part").path))
        // With no jobs folder at all there is nothing to do.
        #expect(Workspace.reconcile(paths: AppPaths(root: root.appendingPathComponent("missing")), keeping: []).isEmpty)
    }

    @Test func aToolLeftRunningByAnEarlierLaunchIsStopped() async throws {
        let root = try scratch("leftover")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let kept = UUID(), orphan = UUID()
        var running: [RunningProcess] = []
        for id in [kept, orphan] {
            let workspace = Workspace(paths: paths, job: id)
            try workspace.create()
            let tool = try ProcessRunner().start(ProcessRequest(executable: "/bin/sleep", arguments: ["60"], environment: [:])) { _ in }
            workspace.recordTool(pid: tool.processIdentifier)
            running.append(tool)
        }
        #expect(running.allSatisfy { $0.isRunning })

        Workspace.reconcile(paths: paths, keeping: [kept])
        for tool in running {
            let outcome = await tool.waitUntilExit()
            #expect(outcome.signalled)
        }
        #expect(Workspace(paths: paths, job: kept).exists)
        #expect(!FileManager.default.fileExists(atPath: Workspace(paths: paths, job: kept).toolRecord.path))
        #expect(!Workspace(paths: paths, job: orphan).exists)
    }

    @Test func aRecordOfAToolThatHasEndedStopsNothing() async throws {
        let root = try scratch("stale")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(root: root)
        let tool = try ProcessRunner().start(ProcessRequest(executable: "/usr/bin/true", arguments: [], environment: [:])) { _ in }
        let pid = tool.processIdentifier
        workspace.recordTool(pid: pid)
        _ = await tool.waitUntilExit()
        // The number may by now belong to anything; the start time tells them apart.
        try JSONEncoder().encode(ProcessIdentity(pid: getpid(), startedAt: 1)).write(to: workspace.toolRecord)
        #expect(!workspace.stopLeftoverTool())
        #expect(!FileManager.default.fileExists(atPath: workspace.toolRecord.path))
        #expect(!workspace.stopLeftoverTool())
    }
}

@Suite struct DeliveryTests {
    private let facts = VideoFacts(id: "abc123", title: "How to: Fold/Unfold", uploader: "Maker", uploadDate: "20261004")

    // MARK: Names

    @Test func aSingleVideoTakesTheNameStyleFromSettings() {
        let stem = "How to： Fold⧸Unfold [abc123]"
        #expect(Delivery.cleanStem(for: stem, rule: .init(guided: true, single: true, style: .title, facts: facts)) == "How to- Fold-Unfold")
        #expect(Delivery.cleanStem(for: stem, rule: .init(guided: true, single: true, style: .uploaderTitle, facts: facts)) == "Maker - How to- Fold-Unfold")
        #expect(Delivery.cleanStem(for: stem, rule: .init(guided: true, single: true, style: .dateTitle, facts: facts)) == "2026-10-04 How to- Fold-Unfold")
        #expect(Delivery.cleanStem(for: stem, rule: .init(guided: true, single: true, facts: facts, clip: true)) == "How to- Fold-Unfold (clip)")
    }

    @Test func aPlaylistItemKeepsItsNumberAndLosesTheId() {
        let rule = Delivery.NameRule(guided: true, single: false, style: .uploaderTitle, facts: nil)
        #expect(Delivery.cleanStem(for: "003 - A Song [xyz]", rule: rule) == "003 - A Song")
        #expect(Delivery.cleanStem(for: "A Song [live] [xyz]", rule: rule) == "A Song [live]")
        #expect(Delivery.cleanStem(for: "No id here", rule: rule) == "No id here")
        #expect(Delivery.cleanStem(for: "[xyz]", rule: rule) == "[xyz]")
        // A single video nothing is known about is treated the same way.
        #expect(Delivery.cleanStem(for: "Video [abc]", rule: .init(guided: true, single: true, facts: nil)) == "Video")
    }

    @Test func aNameTheRecipeChoseIsKept() {
        #expect(Delivery.cleanStem(for: "Maker - Title [abc123]", rule: .init(guided: false, single: true, facts: facts)) == "Maker - Title [abc123]")
    }

    @Test func theRuleComesFromTheJob() {
        var request = Sample.video()
        request.recipe.clip = Clip(start: 1, end: 2)
        let job = Job(createdAt: Date(), request: request)
        #expect(Delivery.NameRule(job: job, style: .dateTitle) == .init(guided: true, single: true, style: .dateTitle, facts: job.facts, clip: true))
        var custom = Sample.playlist()
        custom.recipe.filenameTemplate = .titleOnly
        #expect(Delivery.NameRule(job: Job(createdAt: Date(), request: custom), style: .title) == .init(guided: false, single: false))
    }

    // MARK: Moving

    @Test func aFinishedFileIsMovedWithItsCleanName() throws {
        let root = try scratch("deliver")
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("job/files")
        let destination = root.appendingPathComponent("Movies/YouTube")
        let main = staging.appendingPathComponent("A Talk [abc123].mp4")
        try write("video", to: main)
        let rule = Delivery.NameRule(guided: true, single: true, facts: VideoFacts(id: "abc123", title: "A Talk", uploader: "Maker"))

        let delivered = try Delivery.deliver(mainFile: main.path, staging: staging, folder: destination.path, rule: rule)
        #expect(delivered == destination.appendingPathComponent("A Talk.mp4").path)
        #expect(text(delivered ?? "") == "video")
        #expect(names(in: staging).isEmpty)
        // Asked again (the tool lists a file twice after a resume), there is nothing to move.
        #expect(try Delivery.deliver(mainFile: main.path, staging: staging, folder: destination.path, rule: rule) == nil)
    }

    // Thirty family emoji are thirty characters, but 750 bytes and 330 UTF-16
    // units: more than any disk takes as one name. The name is cut, the file
    // and what belongs to it are delivered, and a second copy gets its number.
    @Test func aTitleTooLongForTheDiskIsCutAndStillDelivered() throws {
        let root = try scratch("deliver-long")
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("job/files")
        let destination = root.appendingPathComponent("Movies/YouTube")
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        let facts = VideoFacts(id: "abc123", title: String(repeating: family, count: 30), uploader: String(repeating: "字", count: 60))
        let rule = Delivery.NameRule(guided: true, single: true, style: .uploaderTitle, facts: facts, clip: true)

        for round in 1...2 {
            let main = staging.appendingPathComponent("Short [abc123].mp4")
            try write("video \(round)", to: main)
            try write("words", to: staging.appendingPathComponent("Short [abc123].en-orig.vtt"))
            let delivered = try #require(try Delivery.deliver(mainFile: main.path, staging: staging, folder: destination.path, rule: rule))
            #expect(text(delivered) == "video \(round)")
            let name = (delivered as NSString).lastPathComponent
            #expect(name.hasSuffix(round == 1 ? " (clip).mp4" : " (clip) (2).mp4"))
            #expect(name.utf8.count <= 255)
        }
        let saved = names(in: destination)
        #expect(saved.count == 4)
        #expect(saved.allSatisfy { $0.utf8.count <= 255 && $0.utf16.count <= 255 })
        #expect(names(in: staging).isEmpty)
    }

    @Test func aLongNameTheRecipeChoseIsCutOnlyAsFarAsTheDiskNeeds() throws {
        let root = try scratch("deliver-own-long")
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("job/files")
        let destination = root.appendingPathComponent("out")
        // 250 letters and ".mp4" is a name the disk takes, but there is no room left for a number.
        let stem = String(repeating: "a", count: 250)
        let main = staging.appendingPathComponent(stem + ".mp4")
        try write("video", to: main)
        let delivered = try #require(try Delivery.deliver(mainFile: main.path, staging: staging, folder: destination.path,
                                                           rule: Delivery.NameRule(guided: false, single: true)))
        #expect((delivered as NSString).lastPathComponent == String(repeating: "a", count: 244) + ".mp4")
    }

    @Test func aTakenNameGetsANumberAndNothingIsOverwritten() throws {
        let root = try scratch("deliver-taken")
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("job/files")
        let destination = root.appendingPathComponent("Movies")
        try write("the user's own", to: destination.appendingPathComponent("A Talk.mp4"))
        try write("an earlier copy", to: destination.appendingPathComponent("A Talk (2).mp4"))
        let main = staging.appendingPathComponent("A Talk [abc123].mp4")
        try write("new", to: main)
        let rule = Delivery.NameRule(guided: true, single: true, facts: VideoFacts(id: "abc123", title: "A Talk", uploader: ""))

        let delivered = try Delivery.deliver(mainFile: main.path, staging: staging, folder: destination.path, rule: rule)
        #expect(delivered == destination.appendingPathComponent("A Talk (3).mp4").path)
        #expect(text(destination.appendingPathComponent("A Talk.mp4").path) == "the user's own")
        #expect(text(destination.appendingPathComponent("A Talk (2).mp4").path) == "an earlier copy")
        #expect(text(destination.appendingPathComponent("A Talk (3).mp4").path) == "new")
    }

    @Test func filesThatBelongToTheVideoTravelWithItUnderOneName() throws {
        let root = try scratch("deliver-group")
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("job/files")
        let destination = root.appendingPathComponent("Movies")
        for (ending, body) in [(".mkv", "video"), (".en.srt", "subtitles"), (".jpg", "picture"), (".description", "words")] {
            try write(body, to: staging.appendingPathComponent("A Talk [abc123]" + ending))
        }
        // Another video's files, and a folder, stay where they are.
        try write("other", to: staging.appendingPathComponent("A Talk [zzz].mkv"))
        try write("chapter", to: staging.appendingPathComponent("A Talk (chapters)/001 Intro.mkv"))
        // Only the subtitles' name is taken at the destination; the whole group moves on to the next number.
        try write("taken", to: destination.appendingPathComponent("A Talk.en.srt"))
        let rule = Delivery.NameRule(guided: true, single: true, facts: VideoFacts(id: "abc123", title: "A Talk", uploader: ""))

        let delivered = try Delivery.deliver(mainFile: staging.appendingPathComponent("A Talk [abc123].mkv").path,
                                             staging: staging, folder: destination.path, rule: rule)
        #expect(delivered == destination.appendingPathComponent("A Talk (2).mkv").path)
        #expect(names(in: destination) == ["A Talk (2).description", "A Talk (2).en.srt", "A Talk (2).jpg", "A Talk (2).mkv", "A Talk.en.srt"])
        #expect(text(destination.appendingPathComponent("A Talk (2).en.srt").path) == "subtitles")
        #expect(names(in: staging) == ["A Talk (chapters)", "A Talk (chapters)/001 Intro.mkv", "A Talk [zzz].mkv"])
    }

    @Test func aTemplateThatSortsIntoFoldersKeepsDoingSo() throws {
        let root = try scratch("deliver-folders")
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("job/files")
        let destination = root.appendingPathComponent("Music")
        let main = staging.appendingPathComponent("Artist/Album/01 Song.m4a")
        try write("song", to: main)
        try write("already there", to: destination.appendingPathComponent("Artist/Album/00 Intro.m4a"))
        let delivered = try Delivery.deliver(mainFile: main.path, staging: staging, folder: destination.path,
                                             rule: .init(guided: false, single: false))
        #expect(delivered == destination.appendingPathComponent("Artist/Album/01 Song.m4a").path)
        #expect(names(in: destination).filter { $0.hasSuffix(".m4a") } == ["Artist/Album/00 Intro.m4a", "Artist/Album/01 Song.m4a"])
    }

    @Test func aFileOutsideTheWorkspaceIsNeverMoved() throws {
        let root = try scratch("deliver-outside")
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("job/files")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("elsewhere.mp4")
        try write("not the job's", to: outside)
        let sneaky = staging.path + "/../../elsewhere.mp4"
        let rule = Delivery.NameRule(guided: false, single: true)
        #expect(try Delivery.deliver(mainFile: outside.path, staging: staging, folder: root.appendingPathComponent("out").path, rule: rule) == nil)
        #expect(try Delivery.deliver(mainFile: sneaky, staging: staging, folder: root.appendingPathComponent("out").path, rule: rule) == nil)
        #expect(text(outside.path) == "not the job's")
    }

    @Test func whatIsLeftIsMovedWithItsFoldersMerged() throws {
        let root = try scratch("deliver-rest")
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("job/files")
        let destination = root.appendingPathComponent("Movies")
        try write("one", to: staging.appendingPathComponent("A Talk (chapters)/001 Intro.mp4"))
        try write("two", to: staging.appendingPathComponent("A Talk (chapters)/002 Main.mp4"))
        try write("cover", to: staging.appendingPathComponent("cover.jpg"))
        try write("from an earlier download", to: destination.appendingPathComponent("A Talk (chapters)/001 Intro.mp4"))

        let delivered = try Delivery.deliverRest(staging: staging, folder: destination.path)
        #expect(delivered.count == 3)
        #expect(names(in: destination) == ["A Talk (chapters)", "A Talk (chapters)/001 Intro (2).mp4", "A Talk (chapters)/001 Intro.mp4",
                                           "A Talk (chapters)/002 Main.mp4", "cover.jpg"])
        #expect(text(destination.appendingPathComponent("A Talk (chapters)/001 Intro.mp4").path) == "from an earlier download")
        #expect(names(in: staging) == ["A Talk (chapters)"])
        #expect(try Delivery.deliverRest(staging: root.appendingPathComponent("missing"), folder: destination.path).isEmpty)
    }

    @Test func aDestinationThatCannotBeWrittenIsAnErrorAndTheFileStays() throws {
        let root = try scratch("deliver-blocked")
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("job/files")
        let main = staging.appendingPathComponent("A Talk.mp4")
        try write("video", to: main)
        // A file where the folder should be.
        try write("in the way", to: root.appendingPathComponent("blocked"))
        #expect(throws: (any Error).self) {
            _ = try Delivery.deliver(mainFile: main.path, staging: staging, folder: root.appendingPathComponent("blocked").path,
                                     rule: .init(guided: false, single: true))
        }
        #expect(text(main.path) == "video")
    }
}

@Suite struct QueueStoreTests {
    private func job(_ state: JobState, _ name: String = "talk") -> Job {
        var job = Job(createdAt: Date(timeIntervalSince1970: 1_800_000_000), request: Sample.video(name))
        job.state = state
        job.folder = "/Users/test/Movies/YouTube"
        job.files = ["/Users/test/Movies/YouTube/one.mp4"]
        job.attempt = 2
        job.startedAt = Date(timeIntervalSince1970: 1_800_000_100)
        return job
    }

    private let now = Date(timeIntervalSince1970: 1_800_001_000)

    @Test func aSavedQueueIsWrittenAndReadBackUnchanged() throws {
        let root = try scratch("store")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = QueueStore(paths: AppPaths(root: root.appendingPathComponent("not yet made")))
        #expect(store.load().isEmpty)
        var clip = job(.scheduled(now.addingTimeInterval(60)), "clip")
        clip.recipe.clip = Clip(start: 10, end: 20)
        let saved = [job(.running(.downloading)), clip, job(.retrying(at: now.addingTimeInterval(15)), "again")].map(SavedJob.init)
        try store.save(saved)
        #expect(store.load() == saved)
        #expect(saved.map(\.state) == [.running, .scheduled, .retrying])
        #expect(saved.map(\.startAfter) == [nil, now.addingTimeInterval(60), now.addingTimeInterval(15)])
        // A file a person can read, with a version to tell formats apart.
        let written = try #require(String(data: Data(contentsOf: store.file), encoding: .utf8))
        #expect(written.contains("\"version\" : 1"))
        #expect(written.contains("\"link\" : \"https:\\/\\/example.com\\/watch?v=clip\""))
    }

    @Test func everyUnfinishedStateHasASavedForm() {
        let date = now
        let pairs: [(JobState, SavedJob.State)] = [(.waiting, .waiting), (.lookingUp, .running), (.running(.finishing), .running),
                                                   (.paused, .paused), (.scheduled(date), .scheduled), (.retrying(at: date), .retrying)]
        for (state, saved) in pairs { #expect(SavedJob(job(state)).state == saved) }
    }

    @Test func afterARestartOnlyAFutureScheduleStaysScheduled() {
        let future = SavedJob(job(.scheduled(now.addingTimeInterval(3600)))).restored(now: now)
        #expect(future.state == .scheduled(now.addingTimeInterval(3600)))
        #expect(future.message.isEmpty)

        let missed = SavedJob(job(.scheduled(now.addingTimeInterval(-60)))).restored(now: now)
        #expect(missed.state == .paused)
        #expect(missed.message == Messages.missedSchedule)

        // A wait before a retry, and everything else, comes back paused.
        for state in [JobState.retrying(at: now.addingTimeInterval(3600)), .waiting, .lookingUp, .running(.downloading), .paused] {
            let restored = SavedJob(job(state)).restored(now: now)
            #expect(restored.state == .paused, "\(state)")
            #expect(restored.message == Messages.pausedBecauseClosed)
        }
    }

    @Test func aRestoredJobRemembersThePickedComment() throws {
        var request = Sample.video()
        request.chapterComment = "c7"
        let original = Job(createdAt: now, request: request)
        #expect(original.chapterComment == "c7")
        let data = try JSONEncoder().encode(SavedJob(original))
        let restored = try JSONDecoder().decode(SavedJob.self, from: data).restored(now: now)
        #expect(restored.chapterComment == "c7")
        // A job saved before the picker existed has none.
        #expect(SavedJob(Job(createdAt: now, request: Sample.video())).restored(now: now).chapterComment == nil)
    }

    @Test func aRestoredJobKeepsWhatItKnew() {
        let original = job(.running(.downloading))
        let restored = SavedJob(original).restored(now: now)
        #expect(restored.id == original.id)
        #expect(restored.createdAt == original.createdAt)
        #expect(restored.recipe == original.recipe)
        #expect(restored.facts == original.facts)
        #expect(restored.folder == original.folder)
        #expect(restored.files == original.files)
        #expect(restored.attempt == 2)
        #expect(restored.startedAt == original.startedAt)
        #expect(restored.label == "Best available")
        #expect(restored.site == "YouTube")
    }

    @Test func aFileFromAnotherVersionKeepsWhatStillFits() throws {
        let id = UUID()
        let json = """
        {"version": 7, "somethingNew": true, "jobs": [
          {"id": "\(id.uuidString)", "link": "https://example.com/v", "state": "dancing", "source": "hologram",
           "recipe": {"mode": "audio", "container": "avi", "notAField": 1}, "extra": [1, 2]},
          {"link": "https://example.com/no-id"},
          "not a job",
          {"id": "\(UUID().uuidString)", "link": "https://example.com/second", "state": "scheduled", "startAfter": "2027-01-01T00:00:00Z"}
        ]}
        """
        let jobs = try #require(QueueStore.decode(Data(json.utf8)))
        #expect(jobs.count == 2)
        #expect(jobs[0].id == id)
        // What it cannot read falls back to the safe choice: paused, and looked up again.
        #expect(jobs[0].state == .paused)
        #expect(jobs[0].source == .link)
        #expect(jobs[0].recipe.mode == .audio)
        #expect(jobs[0].recipe.container == .automatic)
        #expect(jobs[0].title == "https://example.com/v")
        #expect(jobs[1].state == .scheduled)
        #expect(jobs[1].startAfter == Date(timeIntervalSince1970: 1_798_761_600))
    }

    @Test func aFileThatIsNotAQueueIsSetAsideNotWrittenOver() throws {
        let root = try scratch("store-bad")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = QueueStore(paths: AppPaths(root: root))
        try write("not json at all", to: store.file)
        #expect(QueueStore.decode(Data("not json at all".utf8)) == nil)
        #expect(QueueStore.decode(Data("[1, 2]".utf8)) == nil)
        #expect(store.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.file.path))
        #expect(text(root.appendingPathComponent("queue.unreadable.json").path) == "not json at all")
        try store.save([])
        #expect(store.load().isEmpty)
    }

    @Test func savedJobsComeBackOldestFirst() throws {
        let root = try scratch("store-order")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = QueueStore(paths: AppPaths(root: root))
        var early = SavedJob(job(.waiting, "early"))
        var late = SavedJob(job(.waiting, "late"))
        early.createdAt = Date(timeIntervalSince1970: 100)
        late.createdAt = Date(timeIntervalSince1970: 200)
        try store.save([late, early])
        #expect(store.load().map(\.link) == [early.link, late.link])
    }
}
