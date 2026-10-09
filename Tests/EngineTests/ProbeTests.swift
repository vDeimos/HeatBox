import Foundation
import Testing
@testable import Engine

private let toolchain = YtdlpCommand.Toolchain(ytdlp: "/tools/yt-dlp", ffmpeg: "/tools/ffmpeg", deno: "/tools/deno",
                                               environment: ["PATH": "/tools"])

/// The sample Phobos's self-check looks up: one audio stream, H.264 at 1080p and VP9 at 2160p.
let phobosSample: [String: Any] = [
    "id": "abc123", "title": "A Video", "uploader": "Someone", "extractor_key": "Youtube",
    "duration": 754.0, "duration_string": "12:34", "upload_date": "20261004",
    "webpage_url": "https://www.youtube.com/watch?v=abc123",
    "thumbnail": "https://i.ytimg.com/vi/abc123/maxresdefault.jpg",
    "chapters": [
        ["start_time": 0.0, "end_time": 60.0, "title": "Intro"] as [String: Any],
        ["start_time": 60.0, "title": "Main"] as [String: Any],
    ] as [Any],
    "formats": [
        ["format_id": "sb0", "ext": "mhtml", "vcodec": "none", "acodec": "none", "width": 320.0, "height": 180.0] as [String: Any],
        ["format_id": "140", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.2", "filesize": 12_000_000.0] as [String: Any],
        ["format_id": "137", "ext": "mp4", "vcodec": "avc1.640028", "acodec": "none", "width": 1920.0, "height": 1080.0, "filesize": 300_000_000.0] as [String: Any],
        ["format_id": "313", "ext": "webm", "vcodec": "vp09.00.50.08", "acodec": "none", "width": 3840.0, "height": 2160.0, "filesize": 1_900_000_000.0] as [String: Any],
    ] as [Any],
]

/// A stand-in for the download tool: a script that prints what a test asks
/// for. Product code never runs a shell; this is only a fake tool.
private func fakeTool(_ body: String) throws -> (toolchain: YtdlpCommand.Toolchain, folder: URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("probe-tests-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let tool = folder.appendingPathComponent("yt-dlp")
    try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: tool)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
    return (YtdlpCommand.Toolchain(ytdlp: tool.path, environment: ["PATH": "/usr/bin:/bin"]), folder)
}

@Suite struct ProbeTests {
    // MARK: The command

    @Test func theLookupCommandFollowsTheRulesForEveryCall() throws {
        let plan = try Probe.plan(.init(link: "https://www.youtube.com/watch?v=abc123"), toolchain: toolchain)
        #expect(plan.executable == "/tools/yt-dlp")
        #expect(plan.environment == ["PATH": "/tools"])
        #expect(plan.arguments == ["--ignore-config", "--js-runtimes", "deno:/tools/deno",
                                   "-J", "--flat-playlist", "--no-playlist", "--no-warnings",
                                   "--", "https://www.youtube.com/watch?v=abc123"])
    }

    @Test func withoutDenoTheRuntimeIsNotNamed() throws {
        let bare = YtdlpCommand.Toolchain(ytdlp: "/tools/yt-dlp", environment: [:])
        let plan = try Probe.plan(.init(link: "https://example.com/v"), toolchain: bare)
        #expect(plan.arguments == ["--ignore-config", "-J", "--flat-playlist", "--no-playlist", "--no-warnings", "--", "https://example.com/v"])
    }

    @Test func theLookupStartsLikeADownloadCommand() throws {
        let probe = try Probe.plan(.init(link: "https://example.com/v"), toolchain: toolchain)
        let download = try YtdlpCommand.plan(.init(recipe: DownloadRecipe(), links: ["https://example.com/v"], folder: "/out"), toolchain: toolchain)
        #expect(Array(probe.arguments.prefix(3)) == Array(download.visibleArguments.prefix(3)))
    }

    @Test func aSavedSignInWinsOverABrowser() throws {
        let both = try Probe.plan(.init(link: "https://example.com/v", cookiesFile: "/data/cookies.txt", cookieBrowser: .safari), toolchain: toolchain)
        #expect(both.arguments.contains("--cookies"))
        #expect(!both.arguments.contains("--cookies-from-browser"))
        let browser = try Probe.plan(.init(link: "https://example.com/v", cookieBrowser: .firefox), toolchain: toolchain)
        #expect(browser.arguments.suffix(4) == ["--cookies-from-browser", "firefox", "--", "https://example.com/v"])
        let none = try Probe.plan(.init(link: "https://example.com/v", cookiesFile: ""), toolchain: toolchain)
        #expect(!none.arguments.contains("--cookies"))
    }

    @Test func aProxyIsPassedOn() throws {
        let plan = try Probe.plan(.init(link: "https://example.com/v", proxy: " socks5://127.0.0.1:9050 "), toolchain: toolchain)
        #expect(plan.arguments.contains("--proxy"))
        #expect(plan.arguments.contains("socks5://127.0.0.1:9050"))
    }

    @Test(arguments: ["", "not a link", "file:///etc/passwd", "ftp://example.com/v", "--exec=evil", "javascript:alert(1)"])
    func onlyWebLinksAreLookedUp(link: String) {
        #expect(throws: ProbeFailure.invalidLink(link)) { try Probe.plan(.init(link: link), toolchain: toolchain) }
    }

    @Test func theLinkIsTheLastArgumentAfterTheDashes() throws {
        let plan = try Probe.plan(.init(link: "  https://example.com/v?a=1&b=2  ", cookiesFile: "/c.txt", proxy: "http://p:1"), toolchain: toolchain)
        #expect(plan.arguments.suffix(2) == ["--", "https://example.com/v?a=1&b=2"])
    }

    // MARK: Reading the answer (Phobos's lookup checks)

    @Test func aVideoIsRecognisedWithItsFacts() throws {
        guard case .video(let media) = Probe.interpret(phobosSample, link: "x") else {
            Issue.record("a video is recognised")
            return
        }
        #expect(media.site == "YouTube")
        #expect(media.facts == VideoFacts(id: "abc123", title: "A Video", uploader: "Someone", uploadDate: "20261004"))
        #expect(media.link == "https://www.youtube.com/watch?v=abc123")
        #expect(media.seconds == 754)
        #expect(media.duration == "12:34")
        #expect(media.thumbnail?.absoluteString == "https://i.ytimg.com/vi/abc123/maxresdefault.jpg")
        #expect(media.chapters == [MediaChapter(start: 0, end: 60, title: "Intro"), MediaChapter(start: 60, title: "Main")])
        #expect(media.formats.map(\.id) == ["140", "137", "313"], "storyboards are left out")
        #expect(ChoiceBuilder.choices(for: media).map(\.id) == ["best", "compatible", "res1080", "audio"])
        #expect(ChoiceBuilder.choices(for: media).first?.badge == "2160p")
    }

    @Test func aPlaylistIsRecognisedWithItsCount() {
        let sample: [String: Any] = ["_type": "playlist", "title": "L", "extractor_key": "YoutubeTab", "entries": [1, 2, 3] as [Any]]
        guard case .playlist(let list) = Probe.interpret(sample, link: "https://www.youtube.com/playlist?list=PLx") else {
            Issue.record("a playlist is recognised")
            return
        }
        #expect(list.count == 3)
        #expect(list.site == "YouTube")
        #expect(list.title == "L")
        #expect(list.link == "https://www.youtube.com/playlist?list=PLx")
    }

    @Test func aPlaylistListsItsEntries() {
        let sample: [String: Any] = [
            "_type": "playlist", "title": "Talks", "channel": "Someone", "extractor_key": "YoutubeTab", "playlist_count": 40,
            "webpage_url": "https://www.youtube.com/playlist?list=PLx",
            "entries": [
                ["id": "a1", "title": "First", "url": "https://www.youtube.com/watch?v=a1", "duration": 61] as [String: Any],
                ["id": "b2", "url": "https://www.youtube.com/watch?v=b2"] as [String: Any],
                ["id": "c3", "title": "Odd", "url": "c3"] as [String: Any],
            ] as [Any],
        ]
        guard case .playlist(let list) = Probe.interpret(sample, link: "x") else {
            Issue.record("a playlist is recognised")
            return
        }
        #expect(list.count == 40, "the site's own count wins when it is larger than what was listed")
        #expect(list.uploader == "Someone")
        #expect(list.entries == [
            PlaylistEntry(id: "a1", title: "First", link: "https://www.youtube.com/watch?v=a1", seconds: 61),
            PlaylistEntry(id: "b2", title: "https://www.youtube.com/watch?v=b2", link: "https://www.youtube.com/watch?v=b2"),
            PlaylistEntry(id: "c3", title: "Odd", link: nil),
        ])
    }

    @Test func anEmptyPageIsDeclined() {
        #expect(Probe.interpret(["_type": "playlist", "entries": [] as [Any]], link: "x") == .failure(.emptyPage))
    }

    @Test func aLiveStreamIsDeclined() {
        #expect(Probe.interpret(["id": "x", "live_status": "is_live"], link: "x") == .failure(.live))
        #expect(Probe.interpret(["id": "x", "is_live": true], link: "x") == .failure(.live))
        #expect(ProbeFailure.live.message == Messages.live)
    }

    @Test func anUpcomingStreamIsDeclined() {
        #expect(Probe.interpret(["id": "x", "live_status": "is_upcoming"], link: "x") == .failure(.upcoming))
        // The tool usually refuses these itself rather than describing them.
        let refused = Probe.interpret(output: "null", errors: "ERROR: [youtube] dGSqblvgLIE: This live event will begin in 30 hours.", link: "x")
        #expect(refused == .failure(.upcoming))
        #expect(Probe.interpret(output: "null", errors: "ERROR: [youtube] abc: Premieres in 3 days", link: "x") == .failure(.upcoming))
    }

    @Test func aFinishedStreamIsAnOrdinaryVideo() {
        guard case .video = Probe.interpret(["id": "x", "live_status": "was_live", "is_live": false], link: "https://example.com/x") else {
            Issue.record("a finished stream is a video")
            return
        }
    }

    @Test func missingFactsGetPlainDefaults() {
        guard case .video(let media) = Probe.interpret(["channel": "The Channel", "duration": 3725.4], link: "https://example.com/x") else {
            Issue.record("a video is recognised")
            return
        }
        #expect(media.facts.title == "Untitled")
        #expect(media.facts.uploader == "The Channel")
        #expect(media.facts.id == "")
        #expect(media.site == "Other")
        #expect(media.link == "https://example.com/x")
        #expect(media.duration == "1:02:05")
        #expect(media.thumbnail == nil)
        #expect(media.chapters.isEmpty && media.formats.isEmpty)
    }

    @Test func aDirectFileKeepsTheLinkThatWasGiven() {
        let sample: [String: Any] = ["id": "f", "extractor_key": "Generic", "webpage_url": "https://mirror7.example.org/f.mp4",
                                     "webpage_url_domain": "mirror7.example.org"]
        guard case .video(let media) = Probe.interpret(sample, link: "https://example.org/f.mp4") else {
            Issue.record("a video is recognised")
            return
        }
        #expect(media.link == "https://example.org/f.mp4")
        #expect(media.site == "example.org", "named after the link, not the mirror")
        guard case .video(let www) = Probe.interpret(sample, link: "https://WWW.Example.org/f.mp4") else { return }
        #expect(www.site == "example.org")
    }

    @Test func anAddressThatIsNotAWebLinkIsNeverPassedOn() {
        let sample: [String: Any] = ["id": "f", "webpage_url": "file:///etc/passwd", "thumbnail": "javascript:alert(1)"]
        guard case .video(let media) = Probe.interpret(sample, link: "https://example.org/f") else {
            Issue.record("a video is recognised")
            return
        }
        #expect(media.link == "https://example.org/f")
        #expect(media.thumbnail == nil)
    }

    @Test func trueIsNotANumber() {
        #expect(Probe.number(true) == nil)
        #expect(Probe.number(NSNumber(value: 12)) == 12)
        #expect(Probe.number(12.5) == 12.5)
        #expect(Probe.number("12") == nil)
        #expect(Probe.number(nil) == nil)
    }

    // MARK: Failures

    @Test func theToolsLastErrorIsExplained() {
        let errors = """
        WARNING: something minor
        ERROR: [youtube:tab] RDabc: YouTube said: This playlist type is unviewable.
        """
        #expect(Probe.interpret(output: "null", errors: errors, link: "x")
                == .failure(ProbeFailure(kind: .tool(.unviewablePlaylist), message: Messages.unviewablePlaylist)))
    }

    @Test func theErrorLineIsFoundEvenWhenOtherLinesFollow() {
        let errors = "ERROR: [youtube] zzz: Video unavailable\nTraceback noise\n"
        #expect(Probe.failure(fromErrors: errors).kind == .tool(.unavailable))
    }

    @Test func anUnknownErrorIsShownInTheToolsWords() {
        let failure = Probe.failure(fromErrors: "ERROR: Something new went wrong")
        #expect(failure == ProbeFailure(kind: .tool(.unknown), message: "Something new went wrong"))
    }

    @Test func noAnswerAtAllIsUnreadable() {
        #expect(Probe.interpret(output: "", errors: "", link: "x") == .failure(.unreadable))
        #expect(Probe.interpret(output: "null", errors: "  \n", link: "x") == .failure(.unreadable))
        #expect(Probe.interpret(output: "[1, 2]", errors: "", link: "x") == .failure(.unreadable))
        #expect(Probe.interpret(output: "{ not json", errors: "", link: "x") == .failure(.unreadable))
        #expect(ProbeFailure.unreadable.message == Messages.unreadable)
    }

    @Test func anAnswerIsReadWhateverElseTheToolPrinted() {
        guard case .video = Probe.interpret(output: #"{"id": "a", "title": "T"}"#, errors: "ERROR: a later hiccup", link: "https://example.com/a") else {
            Issue.record("the answer is read")
            return
        }
    }

    // MARK: Running

    @Test func aMissingToolIsSaidPlainly() async {
        let empty = ToolRegistry(managedFolder: "/nonexistent/bin", isExecutable: { _ in false })
        #expect(await Probe.lookUp(.init(link: "https://example.com/v"), tools: empty) == .failure(.toolMissing))
        let gone = YtdlpCommand.Toolchain(ytdlp: "/nonexistent/bin/yt-dlp", environment: [:])
        #expect(await Probe.lookUp(.init(link: "https://example.com/v"), toolchain: gone) == .failure(.toolMissing))
        #expect(ProbeFailure.toolMissing.message == Messages.noTool)
    }

    @Test func aBadLinkNeverReachesTheTool() async throws {
        let fake = try fakeTool("touch \"$(dirname \"$0\")/ran\"; echo '{}'")
        defer { try? FileManager.default.removeItem(at: fake.folder) }
        let result = await Probe.lookUp(.init(link: "file:///etc/passwd"), toolchain: fake.toolchain)
        #expect(result == .failure(.invalidLink("file:///etc/passwd")))
        #expect(!FileManager.default.fileExists(atPath: fake.folder.appendingPathComponent("ran").path))
    }

    @Test func aLookupRunsTheToolAndReadsItsAnswer() async throws {
        // The fake tool records its arguments and answers with one long line, as the real one does.
        let fake = try fakeTool("""
        printf '%s\\n' "$@" > "$(dirname "$0")/arguments"
        printf '{"id": "abc", "title": "Seen", "extractor_key": "Vimeo", "webpage_url": "https://vimeo.com/1", "formats": [{"format_id": "http-720", "ext": "mp4", "width": 1280, "height": 720}]}'
        """)
        defer { try? FileManager.default.removeItem(at: fake.folder) }
        let result = await Probe.lookUp(.init(link: "https://vimeo.com/1"), toolchain: fake.toolchain)
        guard case .video(let media) = result else {
            Issue.record("a video is recognised, got \(result)")
            return
        }
        #expect(media.facts.title == "Seen")
        #expect(media.site == "Vimeo")
        #expect(media.formats.count == 1)
        let seen = try String(contentsOf: fake.folder.appendingPathComponent("arguments"), encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(seen == ["--ignore-config", "-J", "--flat-playlist", "--no-playlist", "--no-warnings", "--", "https://vimeo.com/1"])
    }

    @Test func aRefusalFromTheToolBecomesASentence() async throws {
        let fake = try fakeTool("echo null; echo 'ERROR: [youtube] abc: Private video. Sign in if you have access' >&2; exit 1")
        defer { try? FileManager.default.removeItem(at: fake.folder) }
        let result = await Probe.lookUp(.init(link: "https://www.youtube.com/watch?v=abc"), toolchain: fake.toolchain)
        #expect(result == .failure(ProbeFailure(kind: .tool(.privateVideo), message: Messages.privateVideo)))
    }

    @Test func cancellingALookupStopsTheTool() async throws {
        let fake = try fakeTool("echo started > \"$(dirname \"$0\")/started\"; exec /bin/sleep 30")
        defer { try? FileManager.default.removeItem(at: fake.folder) }
        let started = Date()
        let task = Task { await Probe.lookUp(.init(link: "https://example.com/slow"), toolchain: fake.toolchain, runner: ProcessRunner(stopGrace: 0.2)) }
        let marker = fake.folder.appendingPathComponent("started").path
        while !FileManager.default.fileExists(atPath: marker) && Date().timeIntervalSince(started) < 10 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        task.cancel()
        #expect(await task.value == .failure(.stopped))
        #expect(Date().timeIntervalSince(started) < 15, "the lookup ended long before the tool would have")
    }
}
