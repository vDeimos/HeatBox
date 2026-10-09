import Foundation
import Testing
@testable import Engine

private let rules = FolderRules(mainFolder: "/Users/sam/Movies", audioFolder: "/Users/sam/Music/App")

private func media(seconds: Double = 600, chapters: Int = 0) -> MediaFacts {
    let formats = [
        MediaFormat(id: "137", ext: "mp4", width: 1920, height: 1080, videoCodec: "avc1.640028", hasVideo: true, hasAudio: false, bytes: 200_000_000),
        MediaFormat(id: "136", ext: "mp4", width: 1280, height: 720, videoCodec: "avc1.64001f", hasVideo: true, hasAudio: false, bytes: 90_000_000),
        MediaFormat(id: "140", ext: "m4a", audioCodec: "mp4a.40.2", hasVideo: false, hasAudio: true, bytes: 9_000_000),
    ]
    return MediaFacts(facts: VideoFacts(id: "abc", title: "A talk", uploader: "Someone"), site: "YouTube",
                      link: "https://www.youtube.com/watch?v=abc", seconds: seconds, duration: TimeText.clock(seconds),
                      chapters: (0..<chapters).map { MediaChapter(start: Double($0) * 60, title: "Part \($0 + 1)") },
                      formats: formats)
}

private let list = PlaylistFacts(title: "Lectures", uploader: "Someone", site: "YouTube", count: 12,
                                 link: "https://www.youtube.com/playlist?list=PL1")

@Suite struct LinkInputTests {
    @Test func textWithoutALinkAsksForNothing() {
        #expect(LinkInput.read("") == .none)
        #expect(LinkInput.read("just words, ftp://example.com/file") == .none)
    }

    @Test func oneLinkIsTakenAsItIs() {
        #expect(LinkInput.read("  https://vimeo.com/12345\n") == .one(link: "https://vimeo.com/12345", playlist: nil))
    }

    @Test func aVideoInsideAPlaylistIsTheVideoWithTheListOfferedSeparately() {
        #expect(LinkInput.read("https://www.youtube.com/watch?v=abc123&list=PLxyz&index=4")
            == .one(link: "https://www.youtube.com/watch?v=abc123", playlist: "https://www.youtube.com/playlist?list=PLxyz"))
        // A Mix is never offered as a playlist.
        #expect(LinkInput.read("https://www.youtube.com/watch?v=abc123&list=RDabc123")
            == .one(link: "https://www.youtube.com/watch?v=abc123", playlist: nil))
    }

    @Test func severalLinksAreKeptInOrderWithoutRepeats() {
        let text = "https://a.example/1\nhttps://b.example/2, https://a.example/1"
        #expect(LinkInput.read(text) == .several(["https://a.example/1", "https://b.example/2"]))
    }
}

@Suite struct DownloadDraftTests {
    @Test func aVideoOffersItsOwnChoicesAndAListTheGeneralOnes() throws {
        let video = DownloadDraft(target: .video(media()))
        #expect(video.choices == ChoiceBuilder.choices(for: media()))
        #expect(video.clipEnd == 600)
        #expect(DownloadDraft(target: .playlist(list)).choices == ChoiceBuilder.generic)
        #expect(DownloadDraft(target: .links(["https://a.example/1", "https://b.example/2"])).choices == ChoiceBuilder.generic)

        #expect(try DownloadDraft(.video(media())).target == .video(media()))
        #expect(try DownloadDraft(.playlist(list)).target == .playlist(list))
        #expect(throws: ProbeFailure.live) { try DownloadDraft(.failure(.live)) }
    }

    @Test func onlyBulkWorkAsksFirst() {
        #expect(!DownloadTarget.video(media()).needsConfirmation)
        #expect(DownloadTarget.playlist(list).needsConfirmation)
        #expect(DownloadTarget.playlist(list).count == 12)
        #expect(DownloadTarget.links(["https://a.example/1", "https://b.example/2"]).needsConfirmation)
        var single = list
        single.count = 1
        #expect(!DownloadTarget.playlist(single).needsConfirmation)
    }

    @Test func nothingIsRequestedUntilAVersionIsPicked() {
        var draft = DownloadDraft(target: .video(media()))
        #expect(draft.choice == nil)
        #expect(draft.requests(defaults: DownloadDefaults()).isEmpty)
        #expect(draft.summary(rules: rules, home: "/Users/sam") == Messages.draftPickFirst)
        draft.pick("no such choice")
        #expect(draft.requests(defaults: DownloadDefaults()).isEmpty)
    }

    @Test func aPlainVideoIsRequestedWithItsChoicesRecipe() throws {
        var draft = DownloadDraft(target: .video(media()))
        draft.pick(PresetCatalog.compatibleID)
        let requests = draft.requests(defaults: DownloadDefaults())
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(request.recipe == PresetCatalog.playsEverywhere.recipe)
        #expect(request.label == PresetCatalog.playsEverywhere.name)
        #expect(request.resolution == JobResolution(media()))
        #expect(request.folder == nil && request.startAfter == nil)
        #expect(draft.folder(rules: rules) == "/Users/sam/Movies/YouTube")
        #expect(draft.summary(rules: rules, home: "/Users/sam") == "Plays everywhere · Movies › YouTube")
    }

    @Test func audioGoesToTheAudioFolder() {
        var draft = DownloadDraft(target: .video(media()))
        draft.pick(PresetCatalog.audioID)
        #expect(draft.folder(rules: rules) == "/Users/sam/Music/App")
        #expect(draft.destination(rules: rules, home: "/Users/sam") == "Music › App")
    }

    @Test func aClipIsCutBetweenTheChosenTimes() throws {
        var draft = DownloadDraft(target: .video(media()))
        draft.pick(PresetCatalog.bestID)
        draft.clipOn = true
        draft.clipStart = 30
        draft.clipEnd = 95
        #expect(draft.clip == Clip(start: 30, end: 95))
        let recipe = try #require(draft.recipe(defaults: DownloadDefaults(exactCut: false)))
        #expect(recipe.clip == Clip(start: 30, end: 95))
        #expect(!recipe.exactCut)
        #expect(try #require(draft.recipe(defaults: DownloadDefaults())).exactCut)
        #expect(RecipeValidator.validate(recipe).filter { $0.severity == .error }.isEmpty)
        #expect(draft.summary(rules: rules, home: "/Users/sam") == "Best available · 0:30 to 1:35 · Movies › YouTube")

        // To the end of the video: no end time is given to the tool.
        draft.clipEnd = 600
        #expect(draft.clip == Clip(start: 30, end: nil))
        #expect(draft.summary(rules: rules, home: "/Users/sam").contains("0:30 to 10:00"))
    }

    @Test func aClipOfTheWholeVideoIsNoClip() {
        var draft = DownloadDraft(target: .video(media()))
        draft.pick(PresetCatalog.bestID)
        draft.clipOn = true
        #expect(draft.clip == nil)
        draft.clipStart = 40
        draft.clipEnd = 40
        #expect(draft.clip == nil)
        draft.clipOn = false
        draft.clipEnd = 90
        #expect(draft.clip == nil)
        #expect(draft.recipe(defaults: DownloadDefaults())?.clip == nil)
    }

    @Test func aVeryShortOrUnmeasuredVideoCannotBeClipped() {
        var short = DownloadDraft(target: .video(media(seconds: 2)))
        short.clipOn = true
        short.clipStart = 1
        #expect(!short.canClip)
        #expect(short.clip == nil)
        #expect(!DownloadDraft(target: .video(media(seconds: 0))).canClip)
        #expect(!DownloadDraft(target: .playlist(list)).canClip)
    }

    @Test func chaptersAreSplitOnlyWhenThereAreSomeAndNoClip() throws {
        var draft = DownloadDraft(target: .video(media(chapters: 4)))
        draft.pick(PresetCatalog.bestID)
        #expect(draft.canSplitChapters)
        #expect(try #require(draft.recipe(defaults: DownloadDefaults())).splitChapters == false)
        draft.splitChapters = true
        let recipe = try #require(draft.recipe(defaults: DownloadDefaults()))
        #expect(recipe.splitChapters && recipe.chaptersInFolder)
        #expect(RecipeValidator.validate(recipe).filter { $0.severity == .error }.isEmpty)

        // A clip wins: a clip cannot also be split into chapters.
        draft.clipOn = true
        draft.clipStart = 10
        draft.clipEnd = 50
        #expect(!draft.canSplitChapters)
        let clipped = try #require(draft.recipe(defaults: DownloadDefaults()))
        #expect(!clipped.splitChapters)
        #expect(clipped.clip != nil)
        #expect(RecipeValidator.validate(clipped).filter { $0.severity == .error }.isEmpty)

        var plain = DownloadDraft(target: .video(media(chapters: 1)))
        plain.pick(PresetCatalog.bestID)
        plain.splitChapters = true
        #expect(!plain.canSplitChapters)
        #expect(plain.recipe(defaults: DownloadDefaults())?.splitChapters == false)
    }

    @Test func theDefaultsFromSettingsShapeTheRecipe() throws {
        var draft = DownloadDraft(target: .video(media()))
        draft.pick(PresetCatalog.bestID)
        let everything = DownloadDefaults(subtitles: true, coverImage: true, cutSponsors: true, exactCut: false)
        let video = try #require(draft.recipe(defaults: everything))
        #expect(video == DownloadRecipe().withSubtitles().cuttingSponsors().with { $0.embedThumbnail = true })
        // Cut segments are always cut exactly, whatever the clip setting says.
        #expect(video.exactCut)

        // Subtitles and the cover-image switch are for video; audio keeps its own cover.
        draft.pick(PresetCatalog.audioID)
        let audio = try #require(draft.recipe(defaults: everything))
        #expect(audio == PresetCatalog.audioOnly.recipe.cuttingSponsors())
        #expect(!audio.writeSubtitles)

        var settings = AppSettings()
        settings.subtitles = true
        settings.exactCut = false
        #expect(DownloadDefaults(settings) == DownloadDefaults(subtitles: true, exactCut: false))

        // Evening out the volume is for audio downloads only.
        settings.evenLoudness = true
        #expect(DownloadDefaults(settings).evenLoudness)
        #expect(try #require(draft.recipe(defaults: DownloadDefaults(settings))).evenLoudness)
        draft.pick(PresetCatalog.bestID)
        let unchanged = try #require(draft.recipe(defaults: DownloadDefaults(settings)))
        #expect(!unchanged.evenLoudness && RecipeValidator.validate(unchanged).isEmpty)
    }

    @Test func aPlaylistAndSeveralLinksAreRequestedWhole() throws {
        let later = Date(timeIntervalSince1970: 1_800_000_000)
        var playlist = DownloadDraft(target: .playlist(list))
        playlist.pick(PresetCatalog.audioID)
        let request = try #require(playlist.requests(defaults: DownloadDefaults(), startAfter: later).first)
        #expect(request.resolution == JobResolution(list))
        #expect(request.startAfter == later)
        #expect(request.recipe == PresetCatalog.audioOnly.recipe)
        #expect(playlist.folder(rules: rules) == "/Users/sam/Music/App/Lectures")

        var links = DownloadDraft(target: .links(["https://a.example/1", "https://www.youtube.com/watch?v=abc&list=PL1"]))
        links.pick(PresetCatalog.resolutionID(720))
        let requests = links.requests(defaults: DownloadDefaults(subtitles: true))
        #expect(requests.map(\.resolution.link) == ["https://a.example/1", "https://www.youtube.com/watch?v=abc"])
        #expect(requests.allSatisfy { $0.resolution.source == .link && $0.recipe.writeSubtitles })
        #expect(links.folder(rules: rules) == nil)
        #expect(links.summary(rules: rules, home: "/Users/sam") == "Up to 720p · \(Messages.draftEachSiteFolder)")
    }
}

private extension DownloadRecipe {
    func with(_ edit: (inout DownloadRecipe) -> Void) -> DownloadRecipe {
        var copy = self
        edit(&copy)
        return copy
    }
}

@Suite struct QueueTextTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func job(_ state: JobState, _ request: JobRequest = Sample.video()) -> Job {
        Job(createdAt: now, request: request, state: state)
    }

    @Test func theListIsSummedUp() {
        #expect(QueueCounts([]).summary == Messages.queueAllFinished)
        let jobs = [job(.waiting), job(.running(.downloading)), job(.lookingUp), job(.retrying(at: now)),
                    job(.paused), job(.scheduled(now)), job(.done), job(.failed), job(.cancelled), job(.doneWithWarnings)]
        let counts = QueueCounts(jobs)
        #expect(counts.busy == 4 && counts.paused == 1 && counts.scheduled == 1 && counts.finished == 4)
        #expect(counts.active == 5 && counts.unfinished == 6)
        #expect(counts.summary == "4 in progress or waiting · 1 paused · 1 scheduled")
        #expect(QueueCounts([job(.done)]).summary == "All finished")
    }

    @Test func onlyDownloadsThatEndedByThemselvesAreReported() {
        let running = job(.running(.downloading))
        let failing = job(.lookingUp)
        let stopped = job(.running(.starting))
        let old = job(.done)
        var finished = running, failed = failing, cancelled = stopped
        finished.state = .doneWithWarnings
        failed.state = .failed
        cancelled.state = .cancelled
        let added = job(.waiting)
        let endings = JobEnding.between([running, failing, stopped, old], [finished, failed, cancelled, old, added])
        #expect(endings == [.finished(finished), .failed(failed)])
        #expect(JobEnding.between([finished, failed], [finished, failed]).isEmpty)
        #expect(JobEnding.between([], [finished]).isEmpty)
    }

    @Test func everyStateHasAWord() {
        let states: [JobState] = [.waiting, .lookingUp, .running(.starting), .paused, .scheduled(now), .retrying(at: now),
                                  .done, .doneWithWarnings, .failed, .cancelled]
        let labels = states.map(\.label)
        #expect(Set(labels).count == states.count)
        #expect(labels.allSatisfy { !$0.isEmpty })
    }

    @Test func progressIsSaidWithOnlyWhatIsKnown() {
        var progress = JobProgress(fraction: 0.4267)
        #expect(progress.line == "42%")
        progress.size = "31.50MiB"
        progress.speed = "2.10MiB/s"
        progress.timeLeft = "00:35"
        #expect(progress.line == "42% · 31.50MiB · 2.10MiB/s · 00:35 left")
        progress.item = 2
        progress.itemCount = 5
        #expect(progress.line.hasSuffix(" · 2 of 5"))
        #expect(JobProgress(fraction: nil).line == "")
        #expect(JobProgress(fraction: 1.7).line == "100%")
    }

    @Test func aDownloadsLinesSayWhatItIsAndWhereItStands() {
        var running = job(.running(.downloading))
        #expect(running.detail == "Best available · YouTube · 3:00")
        running.progress = JobProgress(fraction: 0.5)
        #expect(running.statusLine(now: now) == "Downloading · 50%")
        running.state = .running(.processing(Messages.stageMerging))
        #expect(running.statusLine(now: now) == Messages.stageMerging)
        running.state = .running(.starting)
        #expect(running.statusLine(now: now) == Messages.stageStarting)

        var retrying = job(.retrying(at: now.addingTimeInterval(15)))
        retrying.attempt = 1
        #expect(retrying.statusLine(now: now) == Messages.retrying(inSeconds: 15, retry: 1, of: 3))
        #expect(retrying.statusLine(now: now.addingTimeInterval(14.2)).contains("in 1 second ("))
        #expect(retrying.statusLine(now: now.addingTimeInterval(60)).contains("in 1 second ("))

        var failed = job(.failed)
        failed.message = "The site couldn't be reached."
        #expect(failed.statusLine(now: now) == "The site couldn't be reached.")

        let list = job(.waiting, Sample.playlist())
        #expect(list.detail == "Best available · YouTube · 3 items")
    }
}
