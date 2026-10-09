import Foundation
import Testing
@testable import Engine

// The steps after a download (plan Phase 6) with the real queue, the real
// worker and the real yt-dlp, FFmpeg and ffprobe, against the local test
// server. Every result is checked with ffprobe or FFmpeg's own measurement.
// Nothing leaves the machine, and nothing goes to the real Trash.

/// A Trash that is a folder inside the test's own scratch folder.
struct FolderTrash: Trash {
    let folder: URL
    @discardableResult
    func trash(_ file: URL) throws -> URL? {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(file.lastPathComponent)
        try FileManager.default.moveItem(at: file, to: target)
        return target
    }
}

/// What ffprobe says about a file.
private struct Probed {
    var format: [String: Any] = [:]
    var streams: [[String: Any]] = []
    var chapters: [[String: Any]] = []

    init(_ file: URL) async {
        guard let result = try? await Real.run(Real.path(.ffprobe), ["-v", "error", "-print_format", "json", "-show_format",
                                                                     "-show_streams", "-show_chapters", file.path]),
              let json = try? JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8)) as? [String: Any] else { return }
        format = json["format"] as? [String: Any] ?? [:]
        streams = json["streams"] as? [[String: Any]] ?? []
        chapters = json["chapters"] as? [[String: Any]] ?? []
    }

    var duration: Double { (format["duration"] as? String).flatMap(Double.init) ?? -1 }
    func stream(_ kind: String) -> [String: Any]? {
        streams.first { $0["codec_type"] as? String == kind && (($0["disposition"] as? [String: Any])?["attached_pic"] as? Int ?? 0) == 0 }
    }
    func codec(_ kind: String) -> String? { stream(kind)?["codec_name"] as? String }
    /// The cover picture, if the file carries one.
    var cover: [String: Any]? {
        streams.first { (($0["disposition"] as? [String: Any])?["attached_pic"] as? Int ?? 0) == 1 }
    }
    /// A tag, wherever the file type keeps it: on the file, or (Ogg) on the sound.
    func tag(_ name: String) -> String? {
        let places = [format["tags"] as? [String: Any], stream("audio")?["tags"] as? [String: Any]]
        for tags in places.compactMap({ $0 }) {
            if let value = tags.first(where: { $0.key.lowercased() == name })?.value as? String { return value }
        }
        return nil
    }
    var chapterTitles: [String] { chapters.compactMap { ($0["tags"] as? [String: Any])?["title"] as? String } }
}

/// How loud a file is over its whole length (LUFS), as FFmpeg measures it.
private func loudness(of file: URL) async -> Double? {
    guard let result = try? await Real.run(Real.path(.ffmpeg), Loudness.measureArguments(input: file.path)) else { return nil }
    return Loudness.parse(result.standardError)?.integrated
}

private func finished(_ queue: JobQueue, _ id: UUID, _ site: Site) async -> Job? {
    if !(await eventually(timeout: 90) { await queue.job(id)?.state.isUnfinished == false }) { Issue.record("\(await site.story(queue, id))") }
    return await queue.job(id)
}

extension Site {
    /// A tone with a picture, at a chosen volume.
    @discardableResult
    func makeTone(_ name: String, seconds: Int = 4, volume: String) async throws -> URL {
        let output = www.appendingPathComponent(name)
        let result = try await Real.run(Real.path(.ffmpeg), [
            "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=duration=\(seconds):size=320x180:rate=10",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)",
            "-af", "volume=\(volume)", "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", "-b:a", "128k",
            "-pix_fmt", "yuv420p", "-movflags", "+faststart", output.path,
        ])
        #expect(result.outcome.succeeded, "\(result.standardError)")
        return output
    }

    /// The real download tool, except that a request for a video's details
    /// is answered with `details`: what a site with comments, chapters and a
    /// thumbnail would say. Downloading and everything after it is real.
    func registry(answeringDetailsWith details: [String: Any]) throws -> ToolRegistry {
        let answer = root.appendingPathComponent("details.json")
        try JSONSerialization.data(withJSONObject: details).write(to: answer)
        let wrapper = root.appendingPathComponent("yt-dlp")
        let script = """
        #!/bin/sh
        for a in "$@"; do if [ "$a" = "--dump-single-json" ]; then exec /bin/cat '\(answer.path)'; fi; done
        exec '\(Real.path(.ytdlp))' "$@"
        """
        try Data(script.utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        return ToolRegistry(overrides: [.ytdlp: wrapper.path])
    }

    /// An album as one sound file of six seconds, with a 16:9 picture, and a comment that lists its three songs.
    func makeAlbum() async throws -> (details: [String: Any], request: JobRequest) {
        let sound = try await Real.run(Real.path(.ffmpeg), ["-loglevel", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=330:duration=6",
                                                            "-af", "volume=-20dB", www.appendingPathComponent("album.wav").path])
        #expect(sound.outcome.succeeded, "\(sound.standardError)")
        let picture = try await Real.run(Real.path(.ffmpeg), ["-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=640x360:duration=1",
                                                              "-frames:v", "1", www.appendingPathComponent("cover.jpg").path])
        #expect(picture.outcome.succeeded, "\(picture.standardError)")
        let address = server.url("album.wav")
        let page = server.url("album")
        let details: [String: Any] = [
            "_type": "video", "id": "album1", "title": "Test Album", "duration": 6.0, "uploader": "The Band",
            "extractor": "generic", "extractor_key": "Generic", "webpage_url": page, "original_url": page,
            "url": address, "ext": "wav", "protocol": "http",
            "thumbnail": server.url("cover.jpg"), "thumbnails": [["id": "0", "url": server.url("cover.jpg")]],
            "formats": [["format_id": "a", "url": address, "ext": "wav", "protocol": "http", "vcodec": "none", "acodec": "pcm_s16le"]],
            "requested_formats": [["format_id": "gone"]],
            "comments": [
                ["id": "c1", "author": "Someone", "like_count": 1, "text": "Loved it at 0:03!"],
                ["id": "c2", "author": "Listener", "like_count": 7, "text": "Track list\n0:00 01. Opening Song (Official Audio)\n0:02 The Band - Second Song\n0:04 7 Rings"],
            ],
        ]
        let media = MediaFacts(facts: VideoFacts(id: "album1", title: "Test Album", uploader: "The Band"), site: "Example",
                               link: page, seconds: 6, duration: "0:06")
        return (details, .video(media, preset: PresetCatalog.audioOnly))
    }
}

@Suite struct PostProcessIntegrationTests {
    @Test func audioOfVeryDifferentLoudnessComesOutAtTheSameLevel() async throws {
        let site = try Site("post-loudness")
        defer { site.cleanUp() }
        let quiet = try await site.makeTone("quiet.mp4", volume: "-28dB")
        let loud = try await site.makeTone("loud.mp4", volume: "8dB")
        try site.makeFeed("feed.xml", title: "Two Tones", items: [("Quiet", "quiet.mp4"), ("Loud", "loud.mp4")])
        let before = [await loudness(of: quiet), await loudness(of: loud)].compactMap { $0 }
        #expect(before.count == 2 && before[1] - before[0] > 25, "\(before)")

        let queue = site.queue()
        let id = await queue.add(link(site.server.url("feed.xml"), preset: PresetCatalog.audioOnly) { $0.evenLoudness = true; $0.sleepInterval = 0 })
        let job = try #require(await finished(queue, id, site))
        if job.state != .done { Issue.record("\(await site.story(queue, id))") }
        let folder = site.music.appendingPathComponent("Two Tones")
        #expect(site.files(in: folder) == ["Quiet.m4a", "Loud.m4a"].sorted(), "\(site.files(in: site.music))")

        var levels: [Double] = []
        for name in ["Quiet.m4a", "Loud.m4a"] {
            let file = folder.appendingPathComponent(name)
            let level = try #require(await loudness(of: file))
            levels.append(level)
            // The target is -16 LUFS; a short tone lands within a unit and a half of it.
            #expect(abs(level + 16) < 1.5, "\(name): \(level)")
            let probed = await Probed(file)
            #expect(probed.codec("audio") == "aac" && probed.codec("video") == nil)
            #expect(abs(probed.duration - 4) < 0.15, "\(probed.duration)")
            // The tags the download tool wrote are still there.
            #expect(probed.tag("title") == name.replacingOccurrences(of: ".m4a", with: ""))
        }
        #expect(abs(levels[0] - levels[1]) < 1.5, "\(levels)")
        // Both passes ran for each file, and the queue said so.
        let log = await queue.log(for: id).lines
        #expect(log.filter { $0.hasPrefix("$ ffmpeg") && $0.contains("linear=true") }.count == 2, "\(log.suffix(20))")
        #expect(site.files(in: site.paths.jobs).isEmpty)
    }

    @Test func aStepThatFailsLeavesTheDownloadIntactAndTheJobDoneWithNotes() async throws {
        let site = try Site("post-failed")
        defer { site.cleanUp() }
        let quiet = try await site.makeTone("quiet.mp4", volume: "-28dB")
        // Everything is real except the tool that reads a file's details, which fails.
        let broken = site.root.appendingPathComponent("ffprobe")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: broken)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: broken.path)
        let queue = site.queue(tools: ToolRegistry(overrides: [.ffprobe: broken.path]))
        let id = await queue.add(link(site.server.url("quiet.mp4"), preset: PresetCatalog.audioOnly) { $0.evenLoudness = true })
        let job = try #require(await finished(queue, id, site))

        if job.state != .doneWithWarnings { Issue.record("\(await site.story(queue, id))") }
        #expect(job.warnings == [Messages.loudnessFailed])
        let file = site.music.appendingPathComponent("quiet.m4a")
        #expect(job.files == [file.path])
        // As quiet as it was downloaded, whole, and nothing else beside it.
        let level = try #require(await loudness(of: file))
        let original = try #require(await loudness(of: quiet))
        #expect(abs(level - original) < 1, "\(level) and \(original)")
        let saved = await Probed(file)
        #expect(abs(saved.duration - 4) < 0.15)
        #expect(site.files(in: site.music) == ["quiet.m4a"])
        #expect(site.files(in: site.paths.jobs).isEmpty)
    }

    @Test func aVideoIsReencodedAndTakesTheDownloadsPlaceWhichGoesToTheTrash() async throws {
        let site = try Site("post-encode")
        defer { site.cleanUp() }
        try await site.makeVideo("lecture.mp4", seconds: 2)
        let queue = site.queue()
        let id = await queue.add(link(site.server.url("lecture.mp4")) {
            $0.encodeEnabled = true
            $0.encoder = .x265
            $0.encoderSpeed = .ultrafast
            $0.qualityFactor = 30
            $0.container = .mov
            $0.encodeAudioBitrate = .b96
            $0.replaceOriginal = true
        })
        let job = try #require(await finished(queue, id, site))
        if job.state != .done { Issue.record("\(await site.story(queue, id))") }

        // One file, under the clean name, with the new ending.
        let file = site.movies.appendingPathComponent("127.0.0.1/lecture.mov")
        #expect(job.files == [file.path])
        #expect(site.files(in: site.movies) == ["127.0.0.1", "127.0.0.1/lecture.mov"])
        let probed = await Probed(file)
        #expect(probed.codec("video") == "hevc" && probed.codec("audio") == "aac")
        #expect(probed.stream("video")?["codec_tag_string"] as? String == "hvc1")
        #expect(probed.stream("video")?["height"] as? Int == 360)
        #expect(abs(probed.duration - 2) < 0.15, "\(probed.duration)")
        #expect(probed.tag("title") == "lecture")
        // The download itself was not deleted: it is in the Trash, whole. (The
        // download tool had already repackaged it as the chosen file type.)
        let trashed = site.files(in: site.trash)
        #expect(trashed == ["lecture [lecture].mov"], "\(trashed)")
        let original = await Probed(site.trash.appendingPathComponent("lecture [lecture].mov"))
        #expect(original.codec("video") == "h264" && abs(original.duration - 2) < 0.15)
        let log = await queue.log(for: id).lines
        #expect(log.contains { $0.hasPrefix("$ ffmpeg") && $0.contains("libx265") })
        #expect(log.contains(Messages.originalInTrash))
        #expect(site.files(in: site.paths.jobs).isEmpty)
    }

    @Test func withoutReplacingTheReencodedVideoIsSavedBesideTheDownload() async throws {
        let site = try Site("post-encode-beside")
        defer { site.cleanUp() }
        let source = try await site.makeVideo("lecture.mp4", seconds: 2)
        let queue = site.queue()
        let id = await queue.add(link(site.server.url("lecture.mp4")) {
            $0.encodeEnabled = true
            $0.encoder = .x264
            $0.encoderSpeed = .ultrafast
            $0.container = .mkv
            $0.encodeAudio = false
        })
        let job = try #require(await finished(queue, id, site))
        if job.state != .done { Issue.record("\(await site.story(queue, id))") }
        let folder = site.movies.appendingPathComponent("127.0.0.1")
        #expect(site.files(in: folder) == ["lecture.encoded.mkv", "lecture.mkv"])
        // The download is delivered untouched beside it.
        let downloaded = await Probed(folder.appendingPathComponent("lecture.mkv"))
        #expect(downloaded.codec("video") == "h264" && abs(downloaded.duration - 2) < 0.15)
        #expect(site.size(folder.appendingPathComponent("lecture.mkv")) > site.size(source) * 9 / 10)
        let encoded = await Probed(folder.appendingPathComponent("lecture.encoded.mkv"))
        // Sound that fits is copied when re-encoding it is switched off.
        #expect(encoded.codec("video") == "h264" && encoded.codec("audio") == "aac")
        #expect(abs(encoded.duration - 2) < 0.15)
        #expect(!FileManager.default.fileExists(atPath: site.trash.path))
    }

    @Test func chaptersFromACommentAreEmbeddedSplitAndEachTrackTaggedWithASquareCover() async throws {
        let site = try Site("post-chapters")
        defer { site.cleanUp() }
        let album = try await site.makeAlbum()
        let queue = site.queue(tools: try site.registry(answeringDetailsWith: album.details))
        var request = album.request
        request.recipe.chapterSource = .comments
        request.recipe.splitChapters = true
        let id = await queue.add(request)
        let job = try #require(await finished(queue, id, site))
        if job.state != .done { Issue.record("\(await site.story(queue, id))") }
        let log = await queue.log(for: id).lines
        #expect(log.contains(Messages.commentChaptersUsed(3, author: "Listener")), "\(log.prefix(6))")

        // The whole album: the comment's chapters are in the file, and its cover is square.
        let main = site.music.appendingPathComponent("Test Album.m4a")
        #expect(job.files == [main.path])
        let whole = await Probed(main)
        #expect(whole.chapterTitles == ["01. Opening Song (Official Audio)", "The Band - Second Song", "7 Rings"], "\(whole.chapterTitles)")
        #expect(whole.cover != nil && whole.cover?["width"] as? Int == whole.cover?["height"] as? Int)
        #expect(abs(whole.duration - 6) < 0.15)

        // One file per chapter, each with its own tidied title, its number, and the cover.
        let folder = site.music.appendingPathComponent("Test Album (chapters)")
        let tracks = site.files(in: folder)
        #expect(tracks.count == 3 && tracks.allSatisfy { $0.hasSuffix(".m4a") }, "\(site.files(in: site.music))")
        var found: [[String?]] = []
        for name in tracks {
            let track = await Probed(folder.appendingPathComponent(name))
            found.append([track.tag("title"), track.tag("track"), track.tag("artist")])
            #expect(abs(track.duration - 2) < 0.2, "\(name): \(track.duration)")
            #expect(track.cover != nil && track.cover?["width"] as? Int == track.cover?["height"] as? Int, "\(name)")
            #expect(track.tag("album_artist") == "The Band", "\(name)")
        }
        #expect(found == [["Opening Song", "1/3", "The Band"], ["Second Song", "2/3", "The Band"], ["7 Rings", "3/3", "The Band"]], "\(found)")
        #expect(log.contains(Messages.taggedTrack(3, of: 3, "7 Rings")))
        #expect(site.files(in: site.paths.jobs).isEmpty)
    }

    @Test func oggTracksKeepTheirCoverThroughTaggingAndEveningOut() async throws {
        let site = try Site("post-ogg")
        defer { site.cleanUp() }
        let album = try await site.makeAlbum()
        let queue = site.queue(tools: try site.registry(answeringDetailsWith: album.details))
        var request = album.request
        request.recipe.audioFormat = .opus
        request.recipe.chapterSource = .commentsIfMissing
        request.recipe.splitChapters = true
        request.recipe.evenLoudness = true
        let id = await queue.add(request)
        let job = try #require(await finished(queue, id, site))
        if job.state != .done { Issue.record("\(await site.story(queue, id))") }

        let main = site.music.appendingPathComponent("Test Album.opus")
        let folder = site.music.appendingPathComponent("Test Album (chapters)")
        let tracks = site.files(in: folder)
        #expect(tracks.count == 3 && tracks.allSatisfy { $0.hasSuffix(".opus") }, "\(site.files(in: site.music))")
        for (index, file) in ([main] + tracks.map { folder.appendingPathComponent($0) }).enumerated() {
            let probed = await Probed(file)
            #expect(probed.codec("audio") == "opus", "\(file.lastPathComponent)")
            // The picture survived the tagging and the second encode, as the tag Ogg keeps it in.
            #expect(probed.cover != nil, "\(file.lastPathComponent): \(probed.streams.count) streams")
            let level = try #require(await loudness(of: file))
            #expect(abs(level + 16) < 2, "\(file.lastPathComponent): \(level)")
            if index > 0 { #expect(probed.tag("track") == "\(index)/3", "\(file.lastPathComponent)") }
        }
        let second = await Probed(folder.appendingPathComponent(tracks[1]))
        #expect(second.tag("title") == "Second Song")
        let whole = await Probed(main)
        #expect(whole.chapterTitles.count == 3)
    }
}
