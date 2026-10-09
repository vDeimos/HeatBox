import Foundation
import Testing
@testable import Engine

@Suite struct CaptionsTests {
    @Test func scrollingAutomaticCaptionsAreNotRepeated() {
        let rolling = """
        WEBVTT
        Kind: captions
        Language: en

        00:00:00.160 --> 00:00:02.070 align:start position:0%
         
        hello<00:00:00.640><c> and</c><00:00:00.800><c> welcome</c>

        00:00:02.070 --> 00:00:02.080 align:start position:0%
        hello and welcome
         

        00:00:02.080 --> 00:00:04.230 align:start position:0%
        hello and welcome
        to<00:00:02.480><c> the</c><00:00:02.560><c> show</c>
        """
        #expect(Captions.parse(rolling) == [Cue(start: 0.16, text: "hello and welcome"), Cue(start: 2.08, text: "to the show")])
    }

    @Test func srtIsReadWithTagsAndEntitiesCleaned() {
        let srt = "1\n00:00:01,500 --> 00:00:03,000\nIt&#39;s a <i>fine</i> day\n\n2\n00:01:05,250 --> 00:01:07,000\n{\\an8}Second line\nand a third\n"
        #expect(Captions.parse(srt) == [Cue(start: 1.5, text: "It's a fine day"), Cue(start: 65.25, text: "Second line"), Cue(start: 65.25, text: "and a third")])
        #expect(Captions.parse("1\r\n00:00:01,000 --> 00:00:02,000\r\nWindows line endings\r\n") == [Cue(start: 1, text: "Windows line endings")])
        #expect(Captions.parse("nothing to see").isEmpty)
    }

    @Test func timesAreRead() {
        #expect(Captions.seconds(from: "01:02:03.500") == 3723.5)
        #expect(Captions.seconds(from: "02:03.5") == 123.5)
        #expect(Captions.seconds(from: "soon") == nil)
        #expect(Captions.seconds(from: "1:-2") == nil)
    }

    @Test func shortCuesAreJoinedIntoPassages() {
        let pieces = Captions.chunk([Cue(start: 0, text: "a b"), Cue(start: 2, text: "c"), Cue(start: 4, text: "d"), Cue(start: 12, text: "e f")])
        #expect(pieces == [Cue(start: 0, text: "a b c d"), Cue(start: 12, text: "e f")])
        let long = (0..<60).map { Cue(start: Double($0) * 0.1, text: "w\($0)") }
        #expect(Captions.chunk(long).allSatisfy { $0.text.split(separator: " ").count <= 28 })
        #expect(Captions.passages(from: [TimedWord(start: 1, text: "good"), TimedWord(start: 1.5, text: "morning"), TimedWord(start: 30, text: "everyone")])
            == [Cue(start: 1, text: "good morning"), Cue(start: 30, text: "everyone")])
    }

    @Test func onlyCaptionsAreFetchedNeverTheVideo() throws {
        let toolchain = YtdlpCommand.Toolchain(ytdlp: "/tools/yt-dlp", ffmpeg: "/tools/ffmpeg", deno: "/tools/deno", environment: [:])
        let args = try #require(Captions.fetchArguments(link: "https://example.com/v", languages: "fr,en", folder: "/tmp/c", cookiesFile: nil, toolchain: toolchain))
        #expect(args.first == "--ignore-config")
        #expect(args.contains("--skip-download") && args.contains("--write-subs") && args.contains("--write-auto-subs") && args.contains("--no-playlist"))
        #expect(args.contains("fr,en") && args.contains("deno:/tools/deno"))
        #expect(Array(args.suffix(2)) == ["--", "https://example.com/v"])
        #expect(!args.contains("--cookies"))
        let signedIn = try #require(Captions.fetchArguments(link: "https://example.com/v", languages: "en", folder: "/t", cookiesFile: "/c/cookies.txt", toolchain: toolchain))
        #expect(signedIn.contains("--cookies") && signedIn.contains("/c/cookies.txt"))
        // Only a web link is ever handed to the tool.
        #expect(Captions.fetchArguments(link: "--exec=rm", languages: "en", folder: "/t", cookiesFile: nil, toolchain: toolchain) == nil)
        #expect(Captions.fetchArguments(link: "", languages: "en", folder: "/t", cookiesFile: nil, toolchain: toolchain) == nil)
        #expect(Captions.languages(for: "en") == "en" && Captions.languages(for: "FR") == "fr,en" && Captions.languages(for: nil) == "en")
    }

    @Test func theFilesOwnTrackAndItsSoundArePlanned() {
        #expect(Captions.embeddedArguments(input: "/m/a.mp4", output: "/t/a.srt").suffix(3) == ["-c:s", "srt", "/t/a.srt"])
        let split = Captions.audioChunkArguments(input: "/m/a.mp4", folder: "/t/chunks")
        #expect(split.contains("segment") && split.contains("50") && split.contains("16000") && split.last == "/t/chunks/chunk_%04d.wav")
        #expect(split.contains("-nostdin") && Captions.embeddedArguments(input: "a", output: "b").contains("-nostdin"))
    }
}

@Suite struct TranscriptDBTests {
    @Test func wordsAreStoredFoundReplacedAndForgotten() async {
        let spoken = TranscriptDB(file: nil)
        #expect(await spoken.replace(video: "one", source: .site, cues: [Cue(start: 5, text: "hello and welcome to the show"), Cue(start: 65, text: "today we talk about gardening")]))
        #expect(await spoken.replace(video: "two", source: .speech, cues: [Cue(start: 12, text: "hello again my friends")]))
        #expect(await spoken.search("gardening").map { [$0.video, String($0.start)] } == [["one", "65.0"]])
        #expect(Set(await spoken.search("hello").map(\.video)) == ["one", "two"])
        // An unfinished last word still matches; every word must be present; capitals do not matter.
        #expect(await spoken.search("garden").count == 1)
        #expect(await spoken.search("hello wel").count == 1)
        #expect(await spoken.search("hello gardening").isEmpty)
        #expect(await spoken.search("WELCOME").count == 1)
        #expect(await spoken.search("   !! ").isEmpty)
        #expect(await spoken.search("zebra").isEmpty)
        #expect(await spoken.search("hello", limit: 1).count == 1)
        // Storing again replaces, not repeats.
        #expect(await spoken.replace(video: "one", source: .site, cues: [Cue(start: 5, text: "hello and welcome to the show")]))
        #expect(await spoken.search("welcome").count == 1)
        #expect(await spoken.search("gardening").isEmpty)
        #expect(await spoken.indexedVideos() == ["one": "site", "two": "speech"])
        // A video with no words is remembered, and can be forgotten.
        #expect(await spoken.replace(video: "three", source: .none, cues: []))
        #expect(await spoken.counts() == (searchable: 2, empty: 1))
        await spoken.forgetEmpty()
        #expect(await spoken.counts() == (searchable: 2, empty: 0))
        await spoken.remove(video: "two")
        #expect(await spoken.search("friends").isEmpty)
        #expect(await spoken.indexedVideos()["two"] == nil)
        if spoken.usesFullText, let hit = await spoken.search("welcome").first {
            #expect(TranscriptDB.pieces(of: hit.snippet).contains { $0.matched && $0.text.lowercased() == "welcome" })
        }
    }

    @Test func whatIsTypedIsOnlyEverWords() async {
        #expect(TranscriptDB.tokens("Hello, World! It's") == ["hello", "world", "it", "s"])
        #expect(TranscriptDB.matchQuery(for: ["hello", "wor"]) == "\"hello\" \"wor\"*")
        let pieces = TranscriptDB.pieces(of: "say \u{E000}hello\u{E001} there")
        #expect(pieces == [SpokenPiece(text: "say ", matched: false), SpokenPiece(text: "hello", matched: true), SpokenPiece(text: " there", matched: false)])
        // Search syntax and quotes in what was typed do no harm.
        let spoken = TranscriptDB(file: nil)
        await spoken.replace(video: "one", source: .file, cues: [Cue(start: 1, text: "near and far")])
        #expect(await spoken.search("near\" OR \"x").isEmpty)
        #expect(await spoken.search("NEAR(far)").count == 1)
        #expect(await spoken.search("'; DROP TABLE spoken; --").isEmpty)
        #expect(await spoken.search("far").count == 1)
    }

    @Test func itSurvivesReopeningAndAFileThatIsNotOneIsSetAside() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("transcripts-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("transcripts.sqlite")
        do {
            let first = TranscriptDB(file: file)
            await first.replace(video: "one", source: .site, cues: [Cue(start: 3, text: "kept for later")])
        }
        let again = TranscriptDB(file: file)
        #expect(await again.search("later").map(\.start) == [3])

        let broken = folder.appendingPathComponent("other.sqlite")
        try Data("this is not a database, it is a note someone may want".utf8).write(to: broken)
        let fresh = TranscriptDB(file: broken)
        #expect(await fresh.replace(video: "x", source: .site, cues: [Cue(start: 0, text: "works")]))
        let aside = folder.appendingPathComponent("transcripts.unreadable.sqlite")
        #expect(try String(contentsOf: aside, encoding: .utf8).hasPrefix("this is not a database"))
    }
}

// MARK: - The indexer

final class FakeRecognizer: SpeechRecognizer, @unchecked Sendable {
    private let lock = NSLock()
    private var state = SpeechAvailability.ready
    private var asked = 0
    private var heard: [String] = []
    var words: [TimedWord] = [TimedWord(start: 1, text: "spoken"), TimedWord(start: 2, text: "aloud")]

    init(_ state: SpeechAvailability = .ready) { self.state = state }

    private func locked<T>(_ work: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return work() }

    func availability() -> SpeechAvailability { locked { state } }
    func requestAccess() async { locked { asked += 1; if state == .undecided { state = .ready } } }
    func words(in file: URL) async -> [TimedWord] { locked { heard.append(file.lastPathComponent) }; return words }
    var timesAsked: Int { locked { asked } }
    var filesHeard: [String] { locked { heard } }
}

final class FakePower: PowerSource, @unchecked Sendable {
    private let lock = NSLock()
    private var battery: Bool
    init(onBattery: Bool = false) { battery = onBattery }
    var onBattery: Bool {
        get { lock.lock(); defer { lock.unlock() }; return battery }
        set { lock.lock(); battery = newValue; lock.unlock() }
    }
}

/// The converter: hands over a caption track when the scratch folder says the
/// file has one, and cuts the sound into two pieces.
private let spokenConverter = """
for last; do :; done
echo "$@" >> "$HERE/ffmpeg.log"
case "$*" in
  *"-c:s srt"*) if [ -f "$HERE/has-embedded" ]; then printf '1\\n00:00:07,000 --> 00:00:09,000\\nwords inside the file\\n' > "$last"; else exit 1; fi;;
  *segment*) if [ -f "$HERE/no-sound" ]; then exit 1; fi; dir=$(dirname "$last"); : > "$dir/chunk_0000.wav"; : > "$dir/chunk_0001.wav";;
esac
"""

/// The downloader: writes the site's captions into the folder after -P when the scratch folder says the site has some.
private let spokenDownloader = """
echo "$@" >> "$HERE/ytdlp.log"
folder=""
prev=""
for arg; do if [ "$prev" = "-P" ]; then folder="$arg"; fi; prev="$arg"; done
if [ -f "$HERE/has-site" ]; then printf 'WEBVTT\\n\\n00:00:12.000 --> 00:00:14.000\\ncaptions from the site\\n' > "$folder/abc.en.vtt"; fi
"""

@Suite struct SpokenIndexerTests {
    struct Setup {
        let tools: StandIns
        let fixture: LibraryFixture
        let database: TranscriptDB
        let recognizer: FakeRecognizer
        let power: FakePower
        let indexer: SpokenIndexer

        func cleanUp() { tools.cleanUp(); fixture.cleanUp() }

        @discardableResult
        func add(_ title: String, link: String = "https://example.org/v") async throws -> LibraryRecord {
            var record = try fixture.record(title)
            record.link = link
            await fixture.library.add(record)
            return record
        }
    }

    private func setUp(_ name: String, speech: SpeechAvailability = .ready, onBattery: Bool = false) throws -> Setup {
        let tools = try StandIns(name)
        try tools.tool(.ffmpeg, spokenConverter)
        try tools.tool(.ytdlp, spokenDownloader)
        let fixture = try LibraryFixture(name)
        let database = TranscriptDB(file: nil)
        let recognizer = FakeRecognizer(speech)
        let power = FakePower(onBattery: onBattery)
        let registry = tools.registry
        let indexer = SpokenIndexer(database: database, library: fixture.library, tools: { registry }, recognizer: recognizer, power: power,
                                    scratch: tools.root.appendingPathComponent("scratch", isDirectory: true))
        return Setup(tools: tools, fixture: fixture, database: database, recognizer: recognizer, power: power, indexer: indexer)
    }

    private let on = SpokenSettings(enabled: true, listen: true)

    @Test func nothingRunsWhileTheSettingIsOff() async throws {
        let s = try setUp("spoken-off")
        defer { s.cleanUp() }
        s.tools.touch("has-embedded")
        try await s.add("A talk")
        await s.indexer.update(SpokenSettings(enabled: false))
        await s.indexer.scan()
        await s.indexer.idle()
        #expect(await s.database.indexedVideos().isEmpty)
        #expect(s.tools.text("ffmpeg.log").isEmpty && s.tools.text("ytdlp.log").isEmpty)
        #expect(await s.indexer.search("words").isEmpty)
        #expect(await s.indexer.status().enabled == false)
        #expect(s.recognizer.timesAsked == 0)
    }

    @Test func captionsInsideTheFileComeFirstAndTheSiteIsNotAsked() async throws {
        let s = try setUp("spoken-file")
        defer { s.cleanUp() }
        s.tools.touch("has-embedded")
        s.tools.touch("has-site")
        let record = try await s.add("A talk")
        await s.indexer.update(on)
        await s.indexer.idle()
        #expect(await s.database.indexedVideos() == [record.id.uuidString: "file"])
        #expect(s.tools.text("ytdlp.log").isEmpty)
        let found = await s.indexer.search("inside")
        #expect(found.count == 1 && found.first?.record.id == record.id && found.first?.start == 7)
        #expect(found.first?.pieces.contains { $0.matched && $0.text == "inside" } == true)
        let status = await s.indexer.status()
        #expect(status.searchable == 1 && status.total == 1 && !status.isWorking && status.message.isEmpty)
        #expect(status.line == "1 of 1 videos searchable")
        // The scratch space is cleared away.
        #expect((try? FileManager.default.contentsOfDirectory(atPath: s.tools.root.appendingPathComponent("scratch").path))?.isEmpty ?? true)
    }

    @Test func otherwiseTheSitesCaptionsAreFetchedWithOneSmallRequest() async throws {
        let s = try setUp("spoken-site")
        defer { s.cleanUp() }
        s.tools.touch("has-site")
        let record = try await s.add("A talk", link: "https://example.org/watch?v=abc")
        var settings = on
        settings.cookiesFile = "/private/cookies.txt"
        settings.languages = "fr,en"
        await s.indexer.update(settings)
        await s.indexer.idle()
        #expect(await s.database.indexedVideos() == [record.id.uuidString: "site"])
        #expect(await s.indexer.search("captions site").first?.start == 12)
        let call = s.tools.text("ytdlp.log")
        #expect(call.split(separator: "\n").count == 1)
        #expect(call.hasPrefix("--ignore-config") && call.contains("--skip-download") && call.contains("--cookies /private/cookies.txt"))
        #expect(call.contains("--sub-langs fr,en") && call.hasSuffix("-- https://example.org/watch?v=abc\n"))
        #expect(s.recognizer.filesHeard.isEmpty)
    }

    @Test func aVideoWithoutCaptionsIsListenedToOnThisMac() async throws {
        let s = try setUp("spoken-listen")
        defer { s.cleanUp() }
        let record = try await s.add("A talk")
        await s.indexer.update(on)
        await s.indexer.idle()
        #expect(await s.database.indexedVideos() == [record.id.uuidString: "speech"])
        #expect(s.recognizer.filesHeard == ["chunk_0000.wav", "chunk_0001.wav"])
        // The second piece's words are fifty seconds further on.
        let found = await s.indexer.search("spoken aloud")
        #expect(Set(found.map(\.start)) == [1, 51])
    }

    @Test func aRecordWithNoWebLinkNeverReachesTheDownloadTool() async throws {
        let s = try setUp("spoken-nolink")
        defer { s.cleanUp() }
        s.tools.touch("has-site")
        try await s.add("A file", link: "")
        try await s.add("Odd", link: "--exec=touch /tmp/x")
        await s.indexer.update(SpokenSettings(enabled: true, listen: false))
        await s.indexer.idle()
        #expect(s.tools.text("ytdlp.log").isEmpty)
        #expect(await s.database.counts() == (searchable: 0, empty: 2))
    }

    @Test func onBatteryListeningWaitsForMainsPower() async throws {
        let s = try setUp("spoken-battery", onBattery: true)
        defer { s.cleanUp() }
        let record = try await s.add("A talk")
        await s.indexer.update(on)
        await s.indexer.idle()
        #expect(await s.database.indexedVideos().isEmpty)
        #expect(s.recognizer.filesHeard.isEmpty)
        #expect(await s.indexer.status().message == Messages.spokenWaitingForPower)
        // Still on battery: nothing changes. A scan does not queue it twice.
        await s.indexer.powerCheck()
        await s.indexer.scan()
        await s.indexer.idle()
        #expect(s.recognizer.filesHeard.isEmpty)
        s.power.onBattery = false
        await s.indexer.powerCheck()
        await s.indexer.idle()
        #expect(await s.database.indexedVideos() == [record.id.uuidString: "speech"])
        #expect(s.recognizer.filesHeard.count == 2)
        #expect(await s.indexer.status().message.isEmpty)
    }

    @Test func withListeningOffAVideoWithoutCaptionsIsRememberedAsHavingNoWords() async throws {
        let s = try setUp("spoken-nolisten")
        defer { s.cleanUp() }
        let record = try await s.add("A talk")
        await s.indexer.update(SpokenSettings(enabled: true, listen: false))
        await s.indexer.idle()
        #expect(await s.database.indexedVideos() == [record.id.uuidString: "none"])
        #expect(s.recognizer.filesHeard.isEmpty && s.recognizer.timesAsked == 0)
        #expect(await s.indexer.status().line == "0 of 1 videos searchable")
        // It is not read again by itself...
        await s.indexer.scan()
        await s.indexer.idle()
        #expect(s.tools.text("ffmpeg.log").split(separator: "\n").count == 1)
        // ...only when asked to try again, and by then the site has captions.
        s.tools.touch("has-site")
        await s.indexer.startOver()
        await s.indexer.idle()
        #expect(await s.database.indexedVideos() == [record.id.uuidString: "site"])
    }

    @Test func thePersonIsAskedOnceAndARefusalIsSaid() async throws {
        let asking = try setUp("spoken-ask", speech: .undecided)
        defer { asking.cleanUp() }
        try await asking.add("A talk")
        await asking.indexer.update(on)
        await asking.indexer.idle()
        #expect(asking.recognizer.timesAsked == 1)
        #expect(await asking.database.counts().searchable == 1)

        let refused = try setUp("spoken-refused", speech: .notAllowed)
        defer { refused.cleanUp() }
        let record = try await refused.add("A talk")
        await refused.indexer.update(on)
        await refused.indexer.idle()
        #expect(refused.recognizer.timesAsked == 0 && refused.recognizer.filesHeard.isEmpty)
        #expect(await refused.database.indexedVideos() == [record.id.uuidString: "none"])
        let status = await refused.indexer.status()
        #expect(status.speechNotAllowed && status.message == Messages.spokenCannotListen)
        #expect(status.line == "0 of 1 videos searchable. \(Messages.spokenSpeechOff) \(Messages.spokenCannotListen)")
    }

    @Test func onlyDownloadsWhoseFilesAreThereAreRead() async throws {
        let s = try setUp("spoken-which")
        defer { s.cleanUp() }
        s.tools.touch("has-embedded")
        let kept = try await s.add("Kept")
        var copy = try s.fixture.record("Kept (MP4)")
        copy.isCopy = true
        await s.fixture.library.add(copy)
        var gone = try s.fixture.record("Gone")
        gone.missing = true
        await s.fixture.library.add(gone)
        await s.indexer.update(on)
        await s.indexer.idle()
        #expect(await s.database.indexedVideos() == [kept.id.uuidString: "file"])
        // Copies are not counted; a download whose file is gone is, and stays unread.
        #expect(await s.indexer.status().line == "1 of 2 videos searchable")
    }

    @Test func aNewDownloadIsReadAndOneThatLeftIsForgotten() async throws {
        let s = try setUp("spoken-changes")
        defer { s.cleanUp() }
        s.tools.touch("has-embedded")
        let first = try await s.add("First")
        await s.indexer.update(on)
        await s.indexer.idle()
        let second = try await s.add("Second")
        await s.indexer.scan()
        await s.indexer.idle()
        #expect(Set(await s.database.indexedVideos().keys) == [first.id.uuidString, second.id.uuidString])
        #expect(await s.indexer.search("words inside").count == 2)
        await s.fixture.library.remove(first.id)
        await s.indexer.scan()
        await s.indexer.idle()
        #expect(Set(await s.database.indexedVideos().keys) == [second.id.uuidString])
        #expect(await s.indexer.search("words inside").map(\.record.id) == [second.id])
    }

    @Test func searchNeedsThreeLettersAndSkipsFilesThatAreGone() async throws {
        let s = try setUp("spoken-search")
        defer { s.cleanUp() }
        let here = try await s.add("Here")
        let moved = try await s.add("Moved")
        await s.database.replace(video: here.id.uuidString, source: .site, cues: [Cue(start: 4, text: "the quick brown fox")])
        await s.database.replace(video: moved.id.uuidString, source: .site, cues: [Cue(start: 9, text: "a quick exit")])
        await s.database.replace(video: UUID().uuidString, source: .site, cues: [Cue(start: 1, text: "quick, but of no record")])
        await s.indexer.update(SpokenSettings(enabled: true, listen: false))
        await s.indexer.idle()
        #expect(await s.indexer.search("qu").isEmpty)
        #expect(Set(await s.indexer.search("quick").map(\.record.title)) == ["Here", "Moved"])
        try FileManager.default.removeItem(atPath: moved.path)
        _ = await s.fixture.library.refreshFiles()
        #expect(await s.indexer.search("quick").map(\.record.title) == ["Here"])
        #expect(await s.indexer.search("quick", limit: 1).count == 1)
    }

    @Test func switchingItOffStopsTheReadingAndClearsTheLine() async throws {
        let s = try setUp("spoken-stop")
        defer { s.cleanUp() }
        // A converter that never answers, so the first video is still being read when the setting goes off.
        try s.tools.tool(.ffmpeg, "echo started >> \"$HERE/ffmpeg.log\"; exec sleep 30")
        try await s.add("One")
        try await s.add("Two")
        var lines: [SpokenStatus] = []
        let stream = await s.indexer.updates()
        await s.indexer.update(on)
        #expect(await eventually { s.tools.exists("ffmpeg.log") })
        #expect(await s.indexer.status().isWorking)
        await s.indexer.update(SpokenSettings(enabled: false))
        await s.indexer.idle()
        for await status in stream {
            lines.append(status)
            if !status.enabled && lines.count > 1 { break }
        }
        let status = await s.indexer.status()
        #expect(!status.enabled && !status.isWorking && status.message.isEmpty)
        #expect(await s.database.indexedVideos().isEmpty)
        #expect(lines.contains { $0.message.hasPrefix("Reading") })
        // The second video was never started.
        #expect(await eventually { s.tools.text("ffmpeg.log").split(separator: "\n").count == 1 })
    }

    @Test func withoutAConverterItSaysSoAndTriesAgainLater() async throws {
        let tools = try StandIns("spoken-notool")
        let fixture = try LibraryFixture("spoken-notool")
        defer { tools.cleanUp(); fixture.cleanUp() }
        let database = TranscriptDB(file: nil)
        let registry = tools.registry
        let indexer = SpokenIndexer(database: database, library: fixture.library, tools: { registry })
        await fixture.library.add(try fixture.record("A talk"))
        await indexer.update(SpokenSettings(enabled: true))
        await indexer.idle()
        #expect(await indexer.status().message == Messages.noConverter)
        #expect(await database.indexedVideos().isEmpty)
    }

    @Test func settingsBecomeWhatTheIndexerIsGiven() {
        var settings = AppSettings()
        #expect(settings.spokenSettings(cookiesFile: nil, languageCode: "en") == SpokenSettings(enabled: false, listen: true, cookiesFile: nil, languages: "en"))
        settings.spokenSearch = true
        settings.transcribeLocally = false
        #expect(settings.spokenSettings(cookiesFile: "/c", languageCode: "de") == SpokenSettings(enabled: true, listen: false, cookiesFile: "/c", languages: "de,en"))
    }
}
