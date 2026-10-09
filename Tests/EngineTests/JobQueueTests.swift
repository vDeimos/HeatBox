import Foundation
import Testing
@testable import Engine

// Every transition of the queue, with a worker that runs no tool and a clock
// that only moves when told to (plan Phase 4).

@Suite struct JobQueueTests {
    // MARK: Running

    @Test func anAddedJobRunsAndFinishes() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let queue = fixture.queue()
        let id = await queue.add(Sample.video())
        #expect(await queue.job(id)?.state == .running(.starting))
        #expect(await eventually { fixture.worker.isRunning(id) })
        #expect(await queue.job(id)?.startedAt == fixture.clock.now())
        #expect(fixture.savedJobs().map(\.state) == [.running])

        fixture.worker.finish(id, Sample.saved)
        #expect(await eventually { await queue.job(id)?.state == .done })
        let job = try #require(await queue.job(id))
        #expect(job.message == "Saved to Movies › YouTube")
        #expect(job.progress.fraction == 1)
        // A finished job is no longer written down, and its working folder is gone.
        #expect(fixture.savedJobs().isEmpty)
        #expect(!fixture.workspace(id).exists)
    }

    @Test func warningsMakeItDoneWithWarnings() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let queue = fixture.queue()
        let id = await queue.add(Sample.playlist())
        #expect(await eventually { fixture.worker.isRunning(id) })
        fixture.worker.finish(id, .finished(message: "2 of 3 saved", warnings: ["This video is private, so it can't be downloaded."]))
        #expect(await eventually { await queue.job(id)?.state == .doneWithWarnings })
        #expect(await queue.job(id)?.warnings == ["This video is private, so it can't be downloaded."])
    }

    @Test func jobsRunOldestFirstAFewAtATime() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let queue = fixture.queue()
        let ids = await queue.add([Sample.video("a"), Sample.video("b"), Sample.video("c"), Sample.video("d")])
        #expect(await eventually { fixture.worker.started.count == 2 })
        // The two oldest, in whichever order their workers got going.
        #expect(Set(fixture.worker.started) == [ids[0], ids[1]])
        #expect(await queue.job(ids[2])?.state == .waiting)
        #expect(await queue.job(ids[2])?.message == Messages.waitingForSlot)

        fixture.worker.finish(ids[1], Sample.saved)
        #expect(await eventually { fixture.worker.started.count == 3 })
        #expect(fixture.worker.started.last == ids[2])
        #expect(await queue.job(ids[3])?.state == .waiting)
    }

    @Test func theLimitIsKeptBetweenOneAndFour() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let queue = fixture.queue(settings: QueueFixture.settings(maxConcurrent: 10))
        await queue.add((0..<6).map { Sample.video("v\($0)") })
        #expect(await eventually { fixture.worker.started.count == 4 })
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(fixture.worker.started.count == 4)

        let other = try QueueFixture()
        defer { other.cleanUp() }
        let single = other.queue(settings: QueueFixture.settings(maxConcurrent: 0))
        await single.add([Sample.video("a"), Sample.video("b")])
        #expect(await eventually { other.worker.started.count == 1 })
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(other.worker.started.count == 1)
    }

    @Test func raisingTheLimitStartsMore() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let queue = fixture.queue(settings: QueueFixture.settings(maxConcurrent: 1))
        let ids = await queue.add([Sample.video("a"), Sample.video("b")])
        #expect(await eventually { fixture.worker.started == [ids[0]] })
        await queue.update(QueueFixture.settings(maxConcurrent: 2))
        #expect(await eventually { fixture.worker.started == ids })
    }

    @Test func twoJobsForTheSameWorkDoNotRunTogether() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let queue = fixture.queue(settings: QueueFixture.settings(maxConcurrent: 3))
        let ids = await queue.add([Sample.video("same"), Sample.video("same"), Sample.video("other"),
                                   Sample.video("same", preset: PresetCatalog.audioOnly)])
        // The twin waits; a different video, and the same video as audio, do not.
        #expect(await eventually { fixture.worker.started.count == 3 })
        #expect(Set(fixture.worker.started) == [ids[0], ids[2], ids[3]])
        #expect(await queue.job(ids[1])?.state == .waiting)
        fixture.worker.finish(ids[0], Sample.saved)
        #expect(await eventually { fixture.worker.started.last == ids[1] })
    }

    @Test func theWorkerIsGivenTheSettingsAndItsOwnWorkspace() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        var settings = QueueFixture.settings()
        settings.speedLimitKB = 2048
        settings.cookiesFile = "/Users/test/cookies.txt"
        settings.nameStyle = .dateTitle
        let queue = fixture.queue(settings: settings)
        let id = await queue.add(Sample.video())
        #expect(await eventually { fixture.worker.isRunning(id) })
        let context = try #require(fixture.worker.context(id))
        #expect(context.workspace == fixture.workspace(id))
        #expect(context.speedLimitKB == 2048)
        #expect(context.cookiesFile == "/Users/test/cookies.txt")
        #expect(context.nameStyle == .dateTitle)
        #expect(context.folders == settings.folders)
        #expect(context.archiveFile == fixture.paths.archiveFile.path)
        #expect(await queue.currentSettings() == settings)
    }

    // MARK: What a worker reports

    @Test func stagesProgressFilesAndLogLinesShowInTheSnapshot() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let queue = fixture.queue()
        let id = await queue.add(Sample.video())
        #expect(await eventually { fixture.worker.isRunning(id) })
        var progress = JobProgress(fraction: 0.4)
        progress.speed = "1.2MiB/s"
        fixture.worker.emit(id, .destination("/Users/test/Movies/YouTube"))
        fixture.worker.emit(id, .stage(.downloading))
        fixture.worker.emit(id, .progress(progress))
        fixture.worker.emit(id, .log("[youtube] Extracting URL"))
        fixture.worker.emit(id, .stage(.processing("Merging streams")))
        fixture.worker.emit(id, .file("/Users/test/Movies/YouTube/A talk.mp4"))
        fixture.worker.emit(id, .file("/Users/test/Movies/YouTube/A talk.mp4"))
        #expect(await eventually { await queue.job(id)?.files.count == 1 })
        let job = try #require(await queue.job(id))
        #expect(job.state == .running(.processing("Merging streams")))
        #expect(job.state == .running(.processing(Messages.stageMerging)))
        #expect(job.progress == progress)
        #expect(job.folder == "/Users/test/Movies/YouTube")
        #expect(await queue.log(for: id).lines == ["[youtube] Extracting URL"])
        // The folder and the finished file are written down, so they survive a restart.
        #expect(fixture.savedJobs().first?.folder == "/Users/test/Movies/YouTube")
        #expect(fixture.savedJobs().first?.files == ["/Users/test/Movies/YouTube/A talk.mp4"])
    }

    @Test func aFolderChosenForTheJobIsNotReplaced() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let queue = fixture.queue()
        var request = Sample.video()
        request.folder = "/Volumes/Big/Videos"
        let id = await queue.add(request)
        #expect(await eventually { fixture.worker.isRunning(id) })
        fixture.worker.emit(id, .destination("/somewhere/else"))
        fixture.worker.emit(id, .stage(.downloading))
        #expect(await eventually { await queue.job(id)?.state == .running(.downloading) })
        #expect(await queue.job(id)?.folder == "/Volumes/Big/Videos")
    }

    @Test func theListIsPublishedAfterEveryChange() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let queue = fixture.queue()
        let stream = await queue.updates()
        let seen = Task { () -> [JobState] in
            var states: [JobState] = []
            for await jobs in stream {
                if let state = jobs.first?.state, states.last != state { states.append(state) }
                if jobs.first?.state == .done { break }
            }
            return states
        }
        let id = await queue.add(Sample.video())
        #expect(await eventually { fixture.worker.isRunning(id) })
        fixture.worker.emit(id, .stage(.downloading))
        #expect(await eventually { await queue.job(id)?.state == .running(.downloading) })
        fixture.worker.finish(id, Sample.saved)
        let states = await seen.value
        #expect(states.last == .done)
        #expect(states.contains(.running(.downloading)))
    }

    // MARK: Look up

    @Test func aPastedLinkIsLookedUpFirst() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let queue = fixture.queue()
        let id = await queue.add(Sample.link())
        #expect(await queue.job(id)?.state == .lookingUp)
        #expect(await queue.job(id)?.message == Messages.lookingUp)
        #expect(await queue.job(id)?.title == "https://example.com/watch?v=pasted")
        #expect(await eventually { fixture.worker.isRunning(id) })

        let facts = VideoFacts(id: "pasted", title: "A Pasted Video", uploader: "Someone")
        fixture.worker.emit(id, .resolved(JobResolution(source: .video, link: "https://example.com/watch?v=pasted",
                                                        title: "A Pasted Video", site: "YouTube", facts: facts, duration: "2:10")))
        #expect(await eventually { await queue.job(id)?.state == .running(.starting) })
        let job = try #require(await queue.job(id))
        #expect(job.source == .video)
        #expect(job.title == "A Pasted Video")
        #expect(job.site == "YouTube")
        #expect(job.facts == facts)
        #expect(job.message.isEmpty)
        // What was found out is written down: a resumed job does not look it up again.
        #expect(fixture.savedJobs().first?.source == .video)
    }

    @Test func aLookupThatFailsFailsTheJobWithItsSentence() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let queue = fixture.queue()
        let id = await queue.add(Sample.link())
        #expect(await eventually { fixture.worker.isRunning(id) })
        fixture.worker.finish(id, .failed(message: Messages.live, retryable: false))
        #expect(await eventually { await queue.job(id)?.state == .failed })
        #expect(await queue.job(id)?.message == Messages.live)
    }

    @Test func pausingDuringALookupStopsItAndResumingLooksAgain() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let queue = fixture.queue()
        let id = await queue.add(Sample.link())
        #expect(await eventually { fixture.worker.isRunning(id) })
        await queue.pause(id)
        #expect(await queue.job(id)?.state == .paused)
        #expect(await queue.job(id)?.message == Messages.paused)
        #expect(await eventually { !fixture.worker.isRunning(id) })
        #expect(fixture.savedJobs().map(\.state) == [.paused])

        await queue.resume(id)
        #expect(await eventually { fixture.worker.runCount(id) == 2 })
        #expect(await queue.job(id)?.state == .lookingUp)
    }

    // MARK: Pause, resume, cancel

    @Test func pausingKeepsTheWorkspaceAndResumingRunsAgain() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let queue = fixture.queue()
        let id = await queue.add(Sample.video())
        #expect(await eventually { fixture.worker.isRunning(id) })
        try fixture.workspace(id).create()

        await queue.pause(id)
        #expect(await queue.job(id)?.state == .paused)
        await queue.idle()
        #expect(fixture.workspace(id).exists)
        #expect(await queue.job(id)?.state == .paused)

        await queue.resume(id)
        #expect(await eventually { fixture.worker.runCount(id) == 2 })
        #expect(await queue.job(id)?.state == .running(.starting))
        #expect(fixture.workspace(id).exists)
    }

    @Test func aPausedJobHoldsItsSlotUntilItsToolHasStopped() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let queue = fixture.queue(settings: QueueFixture.settings(maxConcurrent: 1))
        fixture.worker.holdStops = true
        let ids = await queue.add([Sample.video("a"), Sample.video("b")])
        #expect(await eventually { fixture.worker.isRunning(ids[0]) })

        await queue.pause(ids[0])
        #expect(await queue.job(ids[0])?.state == .paused)
        #expect(await eventually { fixture.worker.stopRequested(ids[0]) })
        // The tool has not gone yet, so the next job waits and a resume does not start a second run.
        await queue.resume(ids[0])
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(fixture.worker.started == [ids[0]])
        #expect(await queue.job(ids[0])?.state == .waiting)
        #expect(await queue.job(ids[1])?.state == .waiting)

        fixture.worker.holdStops = false
        fixture.worker.releaseStop(ids[0])
        // Oldest first: the resumed job goes again before the second one.
        #expect(await eventually { fixture.worker.started == [ids[0], ids[0]] })
        #expect(await queue.job(ids[1])?.state == .waiting)
    }

    @Test func aLateLineDoesNotBringAPausedJobBack() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let queue = fixture.queue()
        fixture.worker.holdStops = true
        let id = await queue.add(Sample.video())
        #expect(await eventually { fixture.worker.isRunning(id) })
        await queue.pause(id)
        fixture.worker.emit(id, .stage(.downloading))
        fixture.worker.emit(id, .progress(JobProgress(fraction: 0.9)))
        fixture.worker.emit(id, .file("/Users/test/Movies/done.mp4"))
        #expect(await eventually { await queue.job(id)?.files == ["/Users/test/Movies/done.mp4"] })
        #expect(await queue.job(id)?.state == .paused)
        #expect(await queue.job(id)?.progress.fraction == 0)
        fixture.worker.holdStops = false
        fixture.worker.releaseStop(id)
        await queue.idle()
        #expect(await queue.job(id)?.state == .paused)
    }

    @Test func aWaitingJobCanBePausedAndIsThenPassedOver() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let queue = fixture.queue(settings: QueueFixture.settings(maxConcurrent: 1))
        let ids = await queue.add([Sample.video("a"), Sample.video("b"), Sample.video("c")])
        #expect(await eventually { fixture.worker.isRunning(ids[0]) })
        await queue.pause(ids[1])
        fixture.worker.finish(ids[0], Sample.saved)
        #expect(await eventually { fixture.worker.started == [ids[0], ids[2]] })
        #expect(await queue.job(ids[1])?.state == .paused)
    }

    @Test func cancellingARunningJobRemovesItsWorkspaceOnceTheToolHasStopped() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let queue = fixture.queue()
        fixture.worker.holdStops = true
        let id = await queue.add(Sample.video())
        #expect(await eventually { fixture.worker.isRunning(id) })
        try fixture.workspace(id).create()

        await queue.cancel(id)
        #expect(await queue.job(id)?.state == .cancelled)
        #expect(await queue.job(id)?.message == Messages.cancelled)
        #expect(await eventually { fixture.worker.stopRequested(id) })
        // Not while the tool may still be writing in it.
        #expect(fixture.workspace(id).exists)
        fixture.worker.holdStops = false
        fixture.worker.releaseStop(id)
        await queue.idle()
        #expect(!fixture.workspace(id).exists)
        #expect(await queue.job(id)?.state == .cancelled)
        #expect(fixture.savedJobs().isEmpty)
    }

    @Test func cancellingWhilePausedRemovesTheWorkspaceAtOnce() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let queue = fixture.queue()
        let id = await queue.add(Sample.video())
        #expect(await eventually { fixture.worker.isRunning(id) })
        try fixture.workspace(id).create()
        await queue.pause(id)
        await queue.idle()
        #expect(fixture.workspace(id).exists)

        await queue.cancel(id)
        #expect(await queue.job(id)?.state == .cancelled)
        #expect(!fixture.workspace(id).exists)
        // Nothing brings it back.
        await queue.resume(id)
        #expect(await queue.job(id)?.state == .cancelled)
        #expect(fixture.worker.runCount(id) == 1)
    }

    @Test func cancellingWhileThePausedToolIsStillStoppingAlsoRemovesTheWorkspace() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let queue = fixture.queue()
        fixture.worker.holdStops = true
        let id = await queue.add(Sample.video())
        #expect(await eventually { fixture.worker.isRunning(id) })
        try fixture.workspace(id).create()
        await queue.pause(id)
        await queue.cancel(id)
        fixture.worker.holdStops = false
        fixture.worker.releaseStop(id)
        await queue.idle()
        #expect(await queue.job(id)?.state == .cancelled)
        #expect(!fixture.workspace(id).exists)
    }

    @Test func aWaitingOrScheduledJobCanBeCancelledAndAFinishedOneCannot() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let queue = fixture.queue(settings: QueueFixture.settings(maxConcurrent: 1))
        let later = fixture.clock.now().addingTimeInterval(3600)
        let ids = await queue.add([Sample.video("a"), Sample.video("b"), Sample.video("c", startAfter: later)])
        #expect(await eventually { fixture.worker.isRunning(ids[0]) })
        await queue.cancel(ids[1])
        await queue.cancel(ids[2])
        #expect(await queue.job(ids[1])?.state == .cancelled)
        #expect(await queue.job(ids[2])?.state == .cancelled)
        fixture.worker.finish(ids[0], Sample.saved)
        #expect(await eventually { await queue.job(ids[0])?.state == .done })
        await queue.cancel(ids[0])
        #expect(await queue.job(ids[0])?.state == .done)
        #expect(fixture.worker.started == [ids[0]])
    }

    @Test func aRunThatStopsByItselfLeavesTheJobPaused() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let queue = fixture.queue()
        let id = await queue.add(Sample.video())
        #expect(await eventually { fixture.worker.isRunning(id) })
        fixture.worker.finish(id, .stopped)
        #expect(await eventually { await queue.job(id)?.state == .paused })
    }

    @Test func everythingCanBePausedResumedAndCancelledAtOnce() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let queue = fixture.queue(settings: QueueFixture.settings(maxConcurrent: 1))
        let ids = await queue.add([Sample.video("a"), Sample.video("b")])
        #expect(await eventually { fixture.worker.isRunning(ids[0]) })
        await queue.pauseAll()
        #expect(await queue.snapshot().map(\.state) == [.paused, .paused])
        await queue.idle()
        await queue.resumeAll()
        #expect(await eventually { fixture.worker.runCount(ids[0]) == 2 })
        #expect(await queue.job(ids[1])?.state == .waiting)
        await queue.cancelAll()
        #expect(await queue.snapshot().map(\.state) == [.cancelled, .cancelled])
    }

    // MARK: Trying again

    @Test func aPassingFailureIsRetriedWithGrowingWaitsUntilTheyRunOut() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let queue = fixture.queue()
        let id = await queue.add(Sample.video())
        let dropped = JobOutcome.failed(message: Messages.unreachable, retryable: true)

        for (retry, wait) in [(1, 15.0), (2, 60.0), (3, 180.0)] {
            #expect(await eventually { fixture.worker.isRunning(id) && fixture.worker.runCount(id) == retry })
            try fixture.workspace(id).create()
            fixture.worker.finish(id, dropped)
            let due = fixture.clock.now().addingTimeInterval(wait)
            #expect(await eventually { await queue.job(id)?.state == .retrying(at: due) })
            let job = try #require(await queue.job(id))
            #expect(job.attempt == retry)
            #expect(job.message == Messages.retrying(inSeconds: Int(wait), retry: retry, of: 3))
            // What was downloaded is kept for the next attempt, and the wait is written down.
            #expect(fixture.workspace(id).exists)
            #expect(fixture.savedJobs().first?.state == .retrying)

            // Not a moment early.
            fixture.clock.advance(by: wait - 1)
            try await Task.sleep(nanoseconds: 30_000_000)
            #expect(fixture.worker.runCount(id) == retry)
            fixture.clock.advance(by: 1)
        }
        // The fourth failure is final.
        #expect(await eventually { fixture.worker.isRunning(id) && fixture.worker.runCount(id) == 4 })
        fixture.worker.finish(id, dropped)
        #expect(await eventually { await queue.job(id)?.state == .failed })
        let job = try #require(await queue.job(id))
        #expect(job.message == Messages.unreachable)
        #expect(job.attempt == 3)
        // Kept, so that Retry carries on from what was downloaded.
        #expect(fixture.workspace(id).exists)
        #expect(fixture.savedJobs().isEmpty)
        #expect(await queue.log(for: id).lines.contains(Messages.unreachable))
    }

    @Test func aLastingFailureIsNotRetried() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let queue = fixture.queue()
        let id = await queue.add(Sample.video())
        #expect(await eventually { fixture.worker.isRunning(id) })
        fixture.worker.finish(id, .failed(message: "This video is private, so it can't be downloaded.", retryable: false))
        #expect(await eventually { await queue.job(id)?.state == .failed })
        #expect(await queue.job(id)?.attempt == 0)
        #expect(fixture.clock.sleeperCount == 0)
    }

    @Test func withAutomaticRetryOffNothingIsRetried() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        var settings = QueueFixture.settings()
        settings.autoRetry = false
        let queue = fixture.queue(settings: settings)
        let id = await queue.add(Sample.video())
        #expect(await eventually { fixture.worker.isRunning(id) })
        fixture.worker.finish(id, .failed(message: Messages.unreachable, retryable: true))
        #expect(await eventually { await queue.job(id)?.state == .failed })
    }

    @Test func aRetryCanBeStartedNowOrPaused() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let queue = fixture.queue()
        let ids = await queue.add([Sample.video("a"), Sample.video("b")])
        #expect(await eventually { fixture.worker.started.count == 2 })
        for id in ids { fixture.worker.finish(id, .failed(message: Messages.unreachable, retryable: true)) }
        #expect(await eventually { await queue.snapshot().allSatisfy { $0.state.due != nil } })

        await queue.startNow(ids[0])
        #expect(await eventually { fixture.worker.runCount(ids[0]) == 2 })
        await queue.pause(ids[1])
        #expect(await queue.job(ids[1])?.state == .paused)
        // Its wait is over, but a paused job stays paused.
        fixture.clock.advance(by: 600)
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(fixture.worker.runCount(ids[1]) == 1)
        #expect(await queue.job(ids[1])?.state == .paused)
    }

    @Test func retryGivesAFailedOrCancelledJobAFreshGo() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        var settings = QueueFixture.settings()
        settings.autoRetry = false
        let queue = fixture.queue(settings: settings)
        let ids = await queue.add([Sample.video("a"), Sample.video("b")])
        #expect(await eventually { fixture.worker.started.count == 2 })
        fixture.worker.finish(ids[0], .failed(message: Messages.unreachable, retryable: true))
        await queue.cancel(ids[1])
        #expect(await eventually { await queue.job(ids[0])?.state == .failed })
        await queue.idle()

        await queue.retry(ids[0])
        await queue.retry(ids[1])
        #expect(await eventually { fixture.worker.runCount(ids[0]) == 2 && fixture.worker.runCount(ids[1]) == 2 })
        #expect(await queue.job(ids[0])?.state == .running(.starting))
        #expect(await queue.job(ids[0])?.attempt == 0)
        // A job that is not failed or cancelled is left alone.
        await queue.retry(ids[0])
        #expect(fixture.worker.runCount(ids[0]) == 2)
    }

    // MARK: Scheduling

    @Test func aScheduledJobWaitsForItsTime() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let queue = fixture.queue()
        let when = fixture.clock.now().addingTimeInterval(7200)
        let id = await queue.add(Sample.video(startAfter: when))
        #expect(await queue.job(id)?.state == .scheduled(when))
        #expect(fixture.savedJobs().first?.state == .scheduled)
        #expect(fixture.savedJobs().first?.startAfter == when)

        fixture.clock.advance(by: 7199)
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(fixture.worker.started.isEmpty)
        fixture.clock.advance(by: 1)
        #expect(await eventually { fixture.worker.isRunning(id) })
        #expect(await queue.job(id)?.state == .running(.starting))
    }

    @Test func theEarliestOfSeveralScheduledJobsGoesFirstAndTheOthersKeepWaiting() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let queue = fixture.queue()
        let now = fixture.clock.now()
        let ids = await queue.add([Sample.video("late", startAfter: now.addingTimeInterval(600)),
                                   Sample.video("early", startAfter: now.addingTimeInterval(60))])
        fixture.clock.advance(by: 60)
        #expect(await eventually { fixture.worker.started == [ids[1]] })
        #expect(await queue.job(ids[0])?.state == .scheduled(now.addingTimeInterval(600)))
        fixture.clock.advance(by: 540)
        #expect(await eventually { fixture.worker.started == [ids[1], ids[0]] })
    }

    @Test func aScheduledJobCanStartNowAndATimeThatHasPassedMeansNow() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let queue = fixture.queue()
        let id = await queue.add(Sample.video("later", startAfter: fixture.clock.now().addingTimeInterval(3600)))
        // A scheduled job is not paused: it is started now or cancelled.
        await queue.pause(id)
        #expect(await queue.job(id)?.state.due != nil)
        await queue.startNow(id)
        #expect(await eventually { fixture.worker.isRunning(id) })

        let past = await queue.add(Sample.video("past", startAfter: fixture.clock.now().addingTimeInterval(-60)))
        #expect(await eventually { fixture.worker.isRunning(past) })
    }

    // MARK: Surviving a restart

    @Test func afterARestartEverythingIsPausedExceptAFutureSchedule() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let first = fixture.queue(settings: QueueFixture.settings(maxConcurrent: 1))
        let now = fixture.clock.now()
        let ids = await first.add([Sample.video("running"), Sample.video("waiting"), Sample.video("paused"), Sample.video("retrying"),
                                   Sample.video("future", startAfter: now.addingTimeInterval(3600)),
                                   Sample.video("missed", startAfter: now.addingTimeInterval(60)),
                                   Sample.video("finished"), Sample.video("cancelled")])
        await first.pause(ids[2])
        await first.cancel(ids[7])
        #expect(await eventually { fixture.worker.isRunning(ids[0]) })
        fixture.worker.emit(ids[0], .file("/Users/test/Movies/one.mp4"))
        // Run "retrying" and "finished" by hand, one at a time.
        await first.pause(ids[0]); await first.pause(ids[1])
        #expect(await eventually { fixture.worker.isRunning(ids[3]) })
        fixture.worker.finish(ids[3], .failed(message: Messages.unreachable, retryable: true))
        #expect(await eventually { fixture.worker.isRunning(ids[6]) })
        fixture.worker.finish(ids[6], Sample.saved)
        #expect(await eventually { await first.job(ids[6])?.state == .done })
        await first.resume(ids[0]); await first.resume(ids[1])
        #expect(await eventually { fixture.worker.runCount(ids[0]) == 2 })
        for id in ids.prefix(6) { try fixture.workspace(id).create() }
        let stray = fixture.workspace(UUID())
        try stray.create()
        #expect(Set(fixture.savedJobs().map(\.state)) == [.running, .waiting, .paused, .retrying, .scheduled])

        // The app is gone without a goodbye. Two minutes later it is opened again.
        let later = QueueFixture.Relaunch(fixture, after: 120)
        let second = later.queue
        let restored = await second.restore()
        #expect(restored.map(\.id) == Array(ids.prefix(6)))
        func job(_ index: Int) async -> Job? { await second.job(ids[index]) }
        for index in 0..<4 {
            #expect(await job(index)?.state == .paused)
            #expect(await job(index)?.message == Messages.pausedBecauseClosed)
        }
        #expect(await job(0)?.files == ["/Users/test/Movies/one.mp4"])
        #expect(await job(0)?.facts?.id == "running")
        #expect(await job(0)?.recipe == PresetCatalog.best.recipe)
        #expect(await job(3)?.attempt == 1)
        #expect(await job(4)?.state == .scheduled(now.addingTimeInterval(3600)))
        #expect(await job(5)?.state == .paused)
        #expect(await job(5)?.message == Messages.missedSchedule)
        // Working folders of jobs that came back are kept; any other is removed.
        for id in ids.prefix(6) { #expect(fixture.workspace(id).exists) }
        #expect(!stray.exists)

        // Nothing starts by itself.
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(later.worker.started.isEmpty)
        // The future schedule still fires when its time comes.
        later.clock.advance(by: 3600 - 120)
        #expect(await eventually { later.worker.started == [ids[4]] })
        // And Resume carries on.
        await second.resume(ids[0])
        #expect(await eventually { later.worker.started == [ids[4], ids[0]] })
        #expect(later.worker.job(ids[0])?.files == ["/Users/test/Movies/one.mp4"])
    }

    @Test func restoringTwiceOrAfterAddingDoesNotDuplicateOrDisturb() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let first = fixture.queue()
        let id = await first.add(Sample.video(startAfter: fixture.clock.now().addingTimeInterval(3600)))

        let second = fixture.queue()
        #expect(await second.restore().map(\.id) == [id])
        #expect(await second.restore().map(\.id) == [id])
        #expect(await second.snapshot().count == 1)
    }

    @Test func quittingPausesWhatRunsWaitsForTheToolsAndKeepsSchedules() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let queue = fixture.queue(settings: QueueFixture.settings(maxConcurrent: 1))
        let when = fixture.clock.now().addingTimeInterval(3600)
        let ids = await queue.add([Sample.video("a"), Sample.video("b"), Sample.video("c", startAfter: when)])
        #expect(await eventually { fixture.worker.isRunning(ids[0]) })
        try fixture.workspace(ids[0]).create()

        await queue.prepareForQuit()
        #expect(!fixture.worker.isRunning(ids[0]))
        #expect(await queue.snapshot().map(\.state) == [.paused, .paused, .scheduled(when)])
        #expect(await queue.job(ids[0])?.message == Messages.pausedBecauseClosed)
        #expect(await queue.job(ids[1])?.message == Messages.pausedBecauseClosed)
        #expect(fixture.workspace(ids[0]).exists)
        #expect(fixture.savedJobs().map(\.state) == [.paused, .paused, .scheduled])
        #expect(fixture.worker.started == [ids[0]])
    }

    // MARK: Removing

    @Test func removingARunningJobCancelsItAndClearsItsWorkspace() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let queue = fixture.queue()
        fixture.worker.holdStops = true
        let id = await queue.add(Sample.video())
        #expect(await eventually { fixture.worker.isRunning(id) })
        try fixture.workspace(id).create()
        await queue.remove(id)
        #expect(await queue.snapshot().isEmpty)
        #expect(fixture.savedJobs().isEmpty)
        #expect(await eventually { fixture.worker.stopRequested(id) })
        fixture.worker.holdStops = false
        fixture.worker.releaseStop(id)
        await queue.idle()
        #expect(!fixture.workspace(id).exists)
    }

    @Test func clearingFinishedLeavesUnfinishedJobsAlone() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let queue = fixture.queue(settings: QueueFixture.settings(maxConcurrent: 4))
        let ids = await queue.add([Sample.video("done"), Sample.video("failed"), Sample.video("cancelled"), Sample.video("running")])
        #expect(await eventually { fixture.worker.started.count == 4 })
        fixture.worker.finish(ids[0], Sample.saved)
        try fixture.workspace(ids[1]).create()
        fixture.worker.finish(ids[1], .failed(message: "No.", retryable: false))
        await queue.cancel(ids[2])
        #expect(await eventually { await queue.job(ids[0])?.state == .done })
        #expect(await eventually { await queue.job(ids[1])?.state == .failed })
        #expect(fixture.workspace(ids[1]).exists)
        fixture.worker.emit(ids[1], .log("gone"))

        await queue.clearFinished()
        #expect(await queue.snapshot().map(\.id) == [ids[3]])
        #expect(!fixture.workspace(ids[1]).exists)
        #expect(await queue.log(for: ids[1]).lines.isEmpty)
        #expect(await queue.job(ids[3])?.state == .running(.starting))
    }
}

extension QueueFixture {
    /// The same Application Support folder, opened again later by a new launch of the app.
    struct Relaunch {
        let worker = FakeWorker()
        let clock: FakeClock
        let queue: JobQueue

        init(_ fixture: QueueFixture, after seconds: TimeInterval) {
            clock = FakeClock(fixture.clock.now().addingTimeInterval(seconds))
            queue = JobQueue(paths: fixture.paths, worker: worker, settings: QueueFixture.settings(), clock: clock)
        }
    }
}
