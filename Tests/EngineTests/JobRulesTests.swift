import Foundation
import Testing
@testable import Engine

// The decisions behind the queue that need no queue to check: when to try
// again, when a scheduled download is due, what a speed limit means, the
// bounded log, and what the tool's lines mean. The first three are Phobos's
// checks, ported.

@Suite struct RetryPolicyTests {
    @Test func problemsThatMayPassAreWorthAnotherGo() {
        #expect(RetryPolicy.isPassing("ERROR: unable to download video data: The read operation timed out"))
        #expect(RetryPolicy.isPassing("ERROR: unable to download video data: HTTP Error 503: Service Unavailable"))
        #expect(RetryPolicy.isPassing("ERROR: [Errno 8] nodename nor servname provided, or not known"))
        #expect(RetryPolicy.isPassing("ERROR: HTTP Error 429: Too Many Requests"))
        #expect(RetryPolicy.isPassing("ERROR: [download] Got error: HTTPConnectionPool(host='127.0.0.1', port=8765): Read timed out."))
        #expect(RetryPolicy.isPassing("ERROR: [generic] one: Unable to download webpage: HTTPConnection(host='127.0.0.1', port=8766): Failed to establish a new connection: [Errno 61] Connection refused"))
    }

    @Test func problemsThatLastAreNot() {
        #expect(!RetryPolicy.isPassing("ERROR: Private video. Sign in if you've been granted access"))
        // A lasting problem wins even inside a download error.
        #expect(!RetryPolicy.isPassing("ERROR: Unable to download webpage: HTTP Error 404: Not Found"))
        #expect(ErrorTranslator.translate("ERROR: [generic] Unable to download webpage: HTTP Error 404: Not Found").kind == .notFound)
        #expect(ErrorTranslator.translate("ERROR: unable to download video data: HTTP Error 403: Forbidden").kind == .refused)
        #expect(!RetryPolicy.isPassing("ERROR: unable to download video data: HTTP Error 403: Forbidden"))
        #expect(!RetryPolicy.isPassing("ERROR: Join this channel to get access to members-only content"))
        #expect(!RetryPolicy.isPassing("ERROR: [youtube] abc: Unable to extract player response"))
        #expect(!RetryPolicy.isPassing("ERROR: unable to write data: [Errno 28] No space left on device"))
        #expect(!RetryPolicy.isPassing("ERROR: something nobody has seen before"))
        #expect(!RetryPolicy.isPassing(""))
        #expect(!RetryPolicy.isPassing("   "))
    }

    @Test func everyKindOfErrorHasAVerdictOrLeavesItToTheWording() {
        #expect(RetryPolicy.isPassing(ErrorKind.unreachable) == true)
        #expect(RetryPolicy.isPassing(ErrorKind.rateLimited) == true)
        #expect(RetryPolicy.isPassing(ErrorKind.unknown) == nil)
        for kind in ErrorKind.allCases where ![.unreachable, .rateLimited, .unknown].contains(kind) {
            #expect(RetryPolicy.isPassing(kind) == false, "\(kind)")
        }
    }

    @Test func waitsGrowAndStopAfterThree() {
        #expect(RetryPolicy.delay(afterAttempt: 0) == 15)
        #expect(RetryPolicy.delay(afterAttempt: 1) == 60)
        #expect(RetryPolicy.delay(afterAttempt: 2) == 180)
        #expect(RetryPolicy.delay(afterAttempt: 3) == nil)
        #expect(RetryPolicy.delay(afterAttempt: -1) == nil)
        #expect(RetryPolicy.maxAttempts == 3)
    }

    @Test func theWaitIsSaidPlainly() {
        #expect(Messages.retrying(inSeconds: 15, retry: 1, of: 3) == "The connection dropped. Trying again in 15 seconds (retry 1 of 3).")
        #expect(Messages.retrying(inSeconds: 60, retry: 2, of: 3).contains("1 minute ("))
        #expect(Messages.retrying(inSeconds: 180, retry: 3, of: 3).contains("3 minutes"))
    }
}

@Suite struct ScheduleTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func moment(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func theNextTimeTheClockReadsTheChosenTime() {
        #expect(Schedule.nextOccurrence(hour: 2, minute: 0, after: moment(5, 23, 30), calendar: utc) == moment(6, 2, 0))
        #expect(Schedule.nextOccurrence(hour: 2, minute: 0, after: moment(5, 1, 0), calendar: utc) == moment(5, 2, 0))
        // Exactly 2:00 means the next 2:00.
        #expect(Schedule.nextOccurrence(hour: 2, minute: 0, after: moment(5, 2, 0), calendar: utc) == moment(6, 2, 0))
    }

    @Test func aPickedTimeUsesOnlyItsClockTime() {
        #expect(Schedule.nextOccurrence(matching: moment(1, 7, 15), after: moment(5, 8, 0), calendar: utc) == moment(6, 7, 15))
    }

    @Test func aSpeedLimitIsBytesForTheToolAndNothingWhenOff() {
        #expect(SpeedLimit.bytesPerSecond(kilobytes: 0) == nil)
        #expect(SpeedLimit.options.first?.kilobytes == 0)
        #expect(SpeedLimit.options.first?.label == Messages.speedNoLimit)
        #expect(SpeedLimit.bytesPerSecond(kilobytes: 2048) == 2_097_152)
        #expect(SpeedLimit.rateArgument(kilobytes: 2048) == "2048K")
        #expect(SpeedLimit.rateArgument(kilobytes: 0) == nil)
        // Every offered limit is one the recipe validator accepts.
        for option in SpeedLimit.options {
            var recipe = DownloadRecipe()
            recipe.rateLimit = SpeedLimit.rateArgument(kilobytes: option.kilobytes) ?? ""
            #expect(RecipeValidator.validate(recipe).filter { $0.severity == .error }.isEmpty, "\(option.label)")
        }
    }
}

@Suite struct JobRecipeTests {
    private func job(_ request: JobRequest) -> Job {
        Job(createdAt: Date(timeIntervalSince1970: 0), request: request)
    }

    @Test func aVideoJobDownloadsOneVideoWhateverTheRecipeSays() {
        var recipe = PresetCatalog.best.recipe
        recipe.playlistMode = .full
        var request = Sample.video()
        request.recipe = recipe
        let effective = job(request).downloadRecipe(speedLimitKB: 0)
        #expect(effective.playlistMode == .single)
        #expect(!effective.useArchive)
        #expect(effective.rateLimit.isEmpty)
    }

    @Test func aPlaylistJobGetsPlaylistMannersAndAnArchive() {
        let effective = job(Sample.playlist()).downloadRecipe(speedLimitKB: 0)
        #expect(effective.playlistMode == .full)
        #expect(effective.continueOnErrors)
        #expect(effective.sleepInterval == 1 && effective.maxSleepInterval == 4)
        #expect(effective.useArchive)
    }

    @Test func theSpeedLimitFromSettingsAppliesUnlessTheRecipeHasItsOwn() {
        #expect(job(Sample.video()).downloadRecipe(speedLimitKB: 1024).rateLimit == "1024K")
        var request = Sample.video()
        request.recipe.rateLimit = "300K"
        #expect(job(request).downloadRecipe(speedLimitKB: 1024).rateLimit == "300K")
    }

    @Test func severalPastedLinksBecomeOneJobEachAndAVideoInAListIsTheVideo() {
        let requests = JobRequest.links(["https://www.youtube.com/watch?v=abc123&list=PL1", "https://example.com/v"], preset: PresetCatalog.audioOnly)
        #expect(requests.map(\.resolution.link) == ["https://www.youtube.com/watch?v=abc123", "https://example.com/v"])
        #expect(requests.allSatisfy { $0.resolution.source == .link && $0.label == "Audio only" && $0.recipe.mode == .audio })
        // Until it is looked up, a job is called by the link that was pasted.
        #expect(requests[0].resolution.title == "https://www.youtube.com/watch?v=abc123&list=PL1")
    }

    @Test func statesKnowWhatTheyMean() {
        let date = Date(timeIntervalSince1970: 10)
        let unfinished: [JobState] = [.waiting, .lookingUp, .running(.downloading), .paused, .scheduled(date), .retrying(at: date)]
        let finished: [JobState] = [.done, .doneWithWarnings, .failed, .cancelled]
        #expect(unfinished.allSatisfy { $0.isUnfinished })
        #expect(!finished.contains { $0.isUnfinished })
        #expect(unfinished.filter { $0.isActive } == [.lookingUp, .running(.downloading)])
        #expect(unfinished.filter { $0.isBusy } == [.waiting, .lookingUp, .running(.downloading)])
        #expect(unfinished.compactMap { $0.due } == [date, date])
        #expect(JobStage.processing("Merging streams").label == "Merging streams")
        #expect(JobStage.starting.label == Messages.stageStarting)
    }
}

@Suite struct JobLogTests {
    @Test func theLogKeepsOnlyTheNewestLinesAndSaysSo() {
        var log = JobLog(limit: 100)
        for number in 1...1000 { log.append("line \(number)") }
        #expect(log.lines.count <= 110)
        #expect(log.lines.count >= 100)
        #expect(log.lines.last == "line 1000")
        #expect(log.dropped == 1000 - log.lines.count)
        #expect(log.text.hasPrefix(Messages.logDropped(log.dropped) + "\n"))
        #expect(log.text.hasSuffix("line 1000"))
    }

    @Test func aShortLogIsLeftWhole() {
        var log = JobLog()
        log.append("one")
        log.append("two")
        #expect(log.lines == ["one", "two"])
        #expect(log.dropped == 0)
        #expect(log.text == "one\ntwo")
        #expect(JobLog.maxLines == 2000)
    }
}

@Suite struct ToolOutputTests {
    private let prefix = YtdlpCommand.progressPrefix

    @Test func aProgressLineIsRead() {
        let event = ToolOutput.parse(prefix + " 42.5%|   1.20MiB/s|00:12|  10.00MiB|NA|NA|NA|A Talk")
        #expect(event == .progress(fraction: 0.425, speed: "1.20MiB/s", timeLeft: "00:12", size: "10.00MiB", item: nil, itemCount: nil, title: "A Talk"))
    }

    @Test func aPlaylistProgressLineCarriesItsPlaceAndATitleMayHoldTheSeparator() {
        let event = ToolOutput.parse(prefix + "100.0%|Unknown B/s|Unknown|NA|   5.00MiB|2|14|One | Two | Three")
        #expect(event == .progress(fraction: 1, speed: "", timeLeft: "", size: "~5.00MiB", item: 2, itemCount: 14, title: "One | Two | Three"))
    }

    @Test func aClipHasNoPercentage() {
        guard case .progress(let fraction, let speed, _, _, _, _, _) = ToolOutput.parse(prefix + "N/A|  500.00KiB/s|NA|NA|NA|NA|NA|Clip") else {
            Issue.record("not a progress line")
            return
        }
        #expect(fraction == nil)
        #expect(speed == "500.00KiB/s")
    }

    @Test func aBrokenProgressLineIsStillProgressAndNotALogLine() {
        #expect(ToolOutput.parse(prefix) == .progress(fraction: nil, speed: "", timeLeft: "", size: "", item: nil, itemCount: nil, title: ""))
    }

    @Test func stepsAfterTheDownloadAreNamedInPlainWords() {
        #expect(ToolOutput.parse("[Merger] Merging formats into \"a.mkv\"") == .stage(Messages.stageMerging))
        #expect(ToolOutput.parse("[ExtractAudio] Destination: a.m4a") == .stage(Messages.stageExtractingAudio))
        #expect(ToolOutput.parse("[EmbedThumbnail] mutagen: Adding thumbnail") == .stage(Messages.stageEmbeddingCover))
        #expect(ToolOutput.parse("[MoveFiles] Moving file a to b") == .stage(Messages.stageFinishing))
        #expect(ToolOutput.parse("[youtube] abc: Downloading webpage") == .other)
        #expect(ToolOutput.parse("[download] Destination: a.mp4") == .other)
        #expect(ToolOutput.parse("[unfinished") == .other)
        #expect(ToolOutput.parse("") == .other)
    }

    @Test func playlistItemsErrorsAndSkipsAreRecognised() {
        #expect(ToolOutput.parse("[download] Downloading item 2 of 14") == .item(index: 2, count: 14))
        #expect(ToolOutput.parse("ERROR: [youtube] abc: Private video") == .error("ERROR: [youtube] abc: Private video"))
        #expect(ToolOutput.parse("ERROR: Interrupted by user") == .interrupted)
        // A dropped connection comes as a bare label and the reason on the next line.
        #expect(ToolOutput.parse("ERROR: ") == .other)
        let dropped = "[download] Got error: (\"Connection broken: ConnectionResetError(54, 'Connection reset by peer')\", ConnectionResetError(54, 'Connection reset by peer'))"
        #expect(ToolOutput.parse(dropped) == .error(dropped))
        #expect(RetryPolicy.isPassing(dropped))
        #expect(ErrorTranslator.translate(dropped) == TranslatedError(kind: .unreachable, message: Messages.unreachable))
        #expect(ToolOutput.parse("[download] one: One has already been recorded in the archive") == .alreadyHave)
        #expect(ToolOutput.parse("[download] /a/b.mp4 has already been downloaded") == .alreadyHave)
        // A warning is a log line, not an error.
        #expect(ToolOutput.parse("WARNING: [generic] Falling back on generic information extractor") == .other)
    }
}
