import Foundation
import Testing
@testable import Engine

/// The Convert screen's four jobs, Send to iPhone's copy and the reading of
/// spoken words, with the real FFmpeg and ffprobe on files made here. Nothing
/// leaves the machine; every result is read back with ffprobe.
@Suite struct ConvertIntegrationTests {
    private func facts(_ file: String) async throws -> FileFacts {
        try #require(await FileInspector.inspect(file, tools: Real.registry), "ffprobe could not read \(file)")
    }

    /// A four-second 640x360 VP9 and Opus video in WebM: nothing QuickTime or an iPhone plays.
    private func makeWebM(in folder: URL) async throws -> String {
        let output = folder.appendingPathComponent("Talk.webm").path
        let made = try await Real.run(Real.path(.ffmpeg), ["-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=duration=4:size=640x360:rate=24", "-f", "lavfi", "-i", "sine=frequency=440:duration=4",
            "-c:v", "libvpx-vp9", "-b:v", "1500k", "-deadline", "realtime", "-cpu-used", "8", "-c:a", "libopus", output])
        #expect(made.outcome.succeeded, "\(made.standardError)")
        return output
    }

    @Test func eachOfTheFourJobsMakesACorrectFileBesideTheOriginal() async throws {
        let folder = try Real.scratchFolder("convert")
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = try await makeWebM(in: folder)
        let before = try Data(contentsOf: URL(fileURLWithPath: input))
        let original = try await facts(input)
        #expect(original.videoCodec == "vp9" && original.audioCodec == "opus")
        let center = ConvertCenter(tools: { Real.registry })
        var draft = ConvertDraft(input: input, facts: original)
        /// Runs what the draft asks for and gives the new file.
        func run(mustBeSmaller: Bool = false) async throws -> String {
            let plan = try #require(draft.plan())
            let id = await center.start(plan, input: input, label: draft.label, mustBeSmaller: mustBeSmaller)
            return try #require(await center.result(of: id))
        }

        // Make it play everywhere.
        let mp4 = try await run()
        let played = try await facts(mp4)
        #expect(mp4.hasSuffix("Talk (MP4).mp4") && played.videoCodec == "h264" && played.audioCodec == "aac")
        #expect(abs(played.duration - 4) < 0.3 && played.height == 360)
        #expect(PhoneReady.isReady(path: mp4, facts: played))

        // Shrink it: smaller than the original, and scaled only when it is taller than the limit.
        draft.choice = .shrink
        draft.level = .small
        let small = try await run(mustBeSmaller: true)
        let shrunk = try await facts(small)
        #expect(small.hasSuffix("Talk (small).mp4") && shrunk.size < original.size && shrunk.videoCodec == "h264" && shrunk.height == 360)

        // Take the audio out.
        draft.choice = .audio
        let m4a = try await run()
        let sound = try await facts(m4a)
        #expect(m4a.hasSuffix("Talk (audio).m4a") && sound.videoCodec == nil && sound.audioCodec == "aac" && abs(sound.duration - 4) < 0.3)

        // Cut a clip, exactly at the times chosen.
        draft.choice = .clip
        draft.clipStart = 1
        draft.clipEnd = 2.5
        let clip = try await run()
        let cut = try await facts(clip)
        #expect(clip.hasSuffix("Talk (clip).mp4") && abs(cut.duration - 1.5) < 0.15 && cut.videoCodec == "h264")

        // Four new files; the original is byte for byte what it was.
        #expect(try Data(contentsOf: URL(fileURLWithPath: input)) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 5)
        #expect(await center.snapshot().allSatisfy { $0.state == .done })
    }

    @Test func aFileThatIsAlreadyTinyIsRefusedBeforeAnythingRuns() async throws {
        let folder = try Real.scratchFolder("convert-tiny")
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("Tiny.mp4").path
        let made = try await Real.run(Real.path(.ffmpeg), ["-loglevel", "error", "-y", "-f", "lavfi", "-i", "color=c=black:duration=6:size=320x240:rate=5",
                                                           "-f", "lavfi", "-i", "anullsrc=r=22050:cl=mono", "-shortest",
                                                           "-c:v", "libx264", "-crf", "40", "-c:a", "aac", "-b:a", "24k", "-pix_fmt", "yuv420p", output])
        #expect(made.outcome.succeeded, "\(made.standardError)")
        var draft = ConvertDraft(input: output, facts: try await facts(output))
        draft.choice = .shrink
        #expect(draft.plan() == nil)
        #expect(draft.blocker() == Messages.convertAlreadySmall)
        #expect(ShrinkLevel.allCases.map(draft.estimate) == Array(repeating: Messages.convertNoSaving, count: 3))
    }

    @Test func aFileAPhoneCannotPlayGetsACopyAndOneItCanIsSentAsItIs() async throws {
        let folder = try Real.scratchFolder("phone")
        defer { try? FileManager.default.removeItem(at: folder) }
        let webm = try await makeWebM(in: folder)
        guard case .needsCopy(let plan) = PhoneSend.decide(path: webm, facts: try await facts(webm)) else {
            Issue.record("a WebM needs a phone-friendly copy")
            return
        }
        let center = ConvertCenter(tools: { Real.registry })
        let copy = try #require(await center.result(of: center.start(plan, input: webm, label: Messages.convertLabelPhone, announce: false)))
        #expect(PhoneSend.decide(path: copy, facts: try await facts(copy)) == .ready)
        // An MKV that already holds H.264 and AAC is only repackaged: quick, and nothing is re-encoded.
        let mkv = folder.appendingPathComponent("Ready.mkv").path
        _ = try await Real.run(Real.path(.ffmpeg), ["-loglevel", "error", "-y", "-i", copy, "-c", "copy", mkv])
        guard case .needsCopy(let repackage) = PhoneSend.decide(path: mkv, facts: try await facts(mkv)) else {
            Issue.record("an MKV needs a copy")
            return
        }
        #expect(repackage.copiesOnly)
        let repackaged = try #require(await center.result(of: center.start(repackage, input: mkv, label: Messages.convertLabelPhone)))
        #expect(PhoneSend.decide(path: repackaged, facts: try await facts(repackaged)) == .ready)
    }

    /// Hears "one two" in every piece it is given.
    private final class Parrot: SpeechRecognizer, @unchecked Sendable {
        private let lock = NSLock()
        private var sizes: [Int64] = []
        func availability() -> SpeechAvailability { .ready }
        func requestAccess() async {}
        func words(in file: URL) async -> [TimedWord] {
            note(FileInspector.size(of: file.path))
            return [TimedWord(start: 0.5, text: "one"), TimedWord(start: 1, text: "two")]
        }
        private func note(_ size: Int64) { lock.lock(); sizes.append(size); lock.unlock() }
        var pieces: [Int64] { lock.lock(); defer { lock.unlock() }; return sizes }
    }

    @Test func wordsAreReadFromCaptionsInsideAFileAndFromItsSound() async throws {
        let folder = try Real.scratchFolder("spoken")
        defer { try? FileManager.default.removeItem(at: folder) }
        let clip = try await Real.makeClip(in: folder, named: "plain.mp4")
        // The same video with a caption track inside it.
        let srt = folder.appendingPathComponent("words.srt")
        try Data("1\n00:00:00,200 --> 00:00:00,900\nthe owl flies at midnight\n".utf8).write(to: srt)
        let captioned = folder.appendingPathComponent("captioned.mkv").path
        let made = try await Real.run(Real.path(.ffmpeg), ["-loglevel", "error", "-y", "-i", clip.path, "-i", srt.path, "-c", "copy", "-c:s", "srt", captioned])
        #expect(made.outcome.succeeded, "\(made.standardError)")

        let library = LibraryRepository(database: nil, thumbnails: folder.appendingPathComponent("thumbnails"), trash: SystemTrash())
        let withCaptions = LibraryRecord(title: "Captioned", path: captioned, added: Date())
        let withoutCaptions = LibraryRecord(title: "Plain", path: clip.path, added: Date())
        await library.add([withCaptions, withoutCaptions])
        let database = TranscriptDB(file: folder.appendingPathComponent("transcripts.sqlite"))
        let parrot = Parrot()
        let indexer = SpokenIndexer(database: database, library: library, tools: { Real.registry }, recognizer: parrot,
                                    scratch: folder.appendingPathComponent("scratch", isDirectory: true))
        await indexer.update(SpokenSettings(enabled: true, listen: true))
        await indexer.idle()

        #expect(await database.indexedVideos() == [withCaptions.id.uuidString: "file", withoutCaptions.id.uuidString: "speech"])
        let owl = await indexer.search("owl midnight")
        #expect(owl.count == 1 && owl.first?.record.title == "Captioned" && abs((owl.first?.start ?? 9) - 0.2) < 0.05)
        #expect(await indexer.search("one two").map(\.record.title) == ["Plain"])
        // The one-second sound became one piece of real 16 kHz mono sound.
        #expect(parrot.pieces.count == 1 && (parrot.pieces.first ?? 0) > 20_000)
        #expect(await indexer.status().line == "2 of 2 videos searchable")
    }
}
