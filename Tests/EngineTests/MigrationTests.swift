import Foundation
import Testing
@testable import Engine

private func scratch(_ name: String) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// A Phobos support folder as Phobos writes it (shapes read from its source).
private func makePhobosFolder(in root: URL, mediaFile: String) throws -> URL {
    let folder = root.appendingPathComponent("Phobos", isDirectory: true)
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("thumbs"), withIntermediateDirectories: true)
    let library = """
    [{"id": "11111111-1111-1111-1111-111111111111", "videoID": "abc", "title": "A talk", "uploader": "Someone", "duration": "1:01",
      "site": "YouTube", "choice": "Plays everywhere", "path": "\(mediaFile)", "link": "https://www.youtube.com/watch?v=abc",
      "date": "2026-09-01T10:00:00Z", "watched": true},
     {"id": "22222222-2222-2222-2222-222222222222", "videoID": "", "title": "Converted", "site": "Vimeo", "choice": "Smaller",
      "path": "/nowhere/x.mp4", "link": "", "date": "2026-09-02T10:00:00.500Z", "isCopy": true},
     {"title": "No path"}, {"path": "relative/only.mp4", "title": "Relative"}]
    """
    try Data(library.utf8).write(to: folder.appendingPathComponent("library.json"))
    try Data("picture".utf8).write(to: folder.appendingPathComponent("thumbs/abc.jpg"))
    let following = """
    [{"id": "33333333-3333-3333-3333-333333333333", "name": "Some Channel", "site": "YouTube", "link": "https://www.youtube.com/@some/videos",
      "seen": ["a", "b"], "lastChecked": "2026-09-03T10:00:00Z", "choiceID": "res1080"}, {"name": "No link"}]
    """
    try Data(following.utf8).write(to: folder.appendingPathComponent("following.json"))
    try Data("sqlite".utf8).write(to: folder.appendingPathComponent("transcripts.sqlite"))
    try Data("[]".utf8).write(to: folder.appendingPathComponent("queue.json"))
    try Data("# cookies".utf8).write(to: folder.appendingPathComponent("cookies.txt"))
    return folder
}

private let phobosSettings = Data("""
{"folders": {"mainFolder": "/Volumes/Big/Video", "audioFolder": "/Volumes/Big/Audio", "perSite": {"Vimeo": "/Volumes/Big/V"}, "playlistSubfolder": false},
 "nameStyle": "uploaderTitle", "maxAtOnce": 3, "subtitles": true, "theme": "light", "accent": "teal", "speedLimitKB": 500,
 "useSignIn": true, "signInBrowser": "firefox", "spokenSearch": true, "tourSeen": true, "knownSites": ["Vimeo"]}
""".utf8)

private func listing(_ folder: URL) -> [String] {
    ((try? FileManager.default.subpathsOfDirectory(atPath: folder.path)) ?? []).sorted()
}

@Suite struct PhobosImportTests {
    @Test func theLibraryFollowingAndSettingsAreRead() throws {
        let root = try scratch("phobos")
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("a.mp4")
        try Data(repeating: 1, count: 42).write(to: media)
        let folder = try makePhobosFolder(in: root, mediaFile: media.path)

        let result = PhobosImporter.read(supportFolder: folder, preferences: phobosSettings)
        #expect(result.records.count == 2)
        let talk = try #require(result.records.first { $0.videoID == "abc" })
        #expect(talk.id == UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        #expect(talk.title == "A talk" && talk.uploader == "Someone" && talk.choice == "Plays everywhere" && talk.watched)
        #expect(talk.added == Date(timeIntervalSince1970: 1_788_256_800) && talk.bytes == 42 && !talk.isCopy)
        let copy = try #require(result.records.first { $0.title == "Converted" })
        #expect(copy.isCopy && copy.added.timeIntervalSince1970 == 1_788_343_200.5)
        #expect(result.pictures == [talk.id: folder.appendingPathComponent("thumbs/abc.jpg")])

        #expect(result.channels.count == 1)
        #expect(result.channels[0].seen == ["a", "b"] && result.channels[0].choiceID == "res1080")

        let settings = try #require(result.settings)
        #expect(settings.folders.mainFolder == "/Volumes/Big/Video" && settings.folders.perSite["Vimeo"] == "/Volumes/Big/V")
        #expect(!settings.folders.playlistSubfolder && settings.nameStyle == .uploaderTitle && settings.maxConcurrent == 3)
        #expect(settings.subtitles && settings.theme == .light && settings.accent == .teal && settings.speedLimitKB == 500)
        #expect(settings.knownSites == ["Vimeo"])
        #expect(result.transcriptDatabase != nil)
        #expect(result.notes == [Messages.importPhobosQueueLeft, Messages.importPhobosSignInLeft])
    }

    @Test func nothingIsReadFromAFolderThatIsNotThere() {
        let result = PhobosImporter.read(supportFolder: URL(fileURLWithPath: "/nonexistent/Phobos"), preferences: nil)
        #expect(result.records.isEmpty && result.channels.isEmpty && result.settings == nil && result.notes.isEmpty)
    }
}

@Suite struct StudioImportTests {
    private func options(_ extra: String) -> Data {
        Data("""
        {"mode": "audio", "audioFormat": "opus", "audioQuality": "k64", "channels": "mono", "normalizeAudio": true, "volumeDB": 3,
         "crf": 20, "writeSubs": true, "subLangs": "de", "sponsorBlockMode": "remove", "preciseCuts": false,
         "outputDirectory": "/Users/x/Downloads", "futureField": 1, "container": "flv", \(extra) "retries": 3}
        """.utf8)
    }

    @Test func optionsBecomeARecipeWithStudiosNamesMapped() throws {
        var notes: [String] = []
        let object = try #require(try JSONSerialization.jsonObject(with: options(#""trimEnabled": true, "trimStart": "0:10", "trimEnd": "1:00","#)) as? [String: Any])
        let recipe = StudioImporter.recipe(fromOptions: object, notes: &notes, context: "Mine")
        #expect(recipe.mode == .audio && recipe.audioFormat == .opus && recipe.audioQuality == .k64 && recipe.channels == .mono)
        #expect(recipe.evenLoudness && recipe.gainDB == 3 && recipe.qualityFactor == 20 && recipe.retries == 3)
        #expect(recipe.writeSubtitles && recipe.subtitleLanguages == "de" && recipe.sponsorBlock == .remove && !recipe.exactCut)
        #expect(recipe.clip == Clip(start: 10, end: 60))
        // A container that no longer exists keeps the default; a note says so.
        #expect(recipe.container == DownloadRecipe.studioDefaults.container)
        #expect(notes == [Messages.importLegacyContainer("Mine", "FLV")])
    }

    @Test func extraArgumentsThatRunProgramsAreLeftOutWithANote() throws {
        var notes: [String] = []
        let ok = try #require(try JSONSerialization.jsonObject(with: Data(#"{"extraArgs": "--no-mtime", "customPPA": "Merger+ffmpeg_o:-x"}"#.utf8)) as? [String: Any])
        let kept = StudioImporter.recipe(fromOptions: ok, notes: &notes, context: "A")
        #expect(kept.extraArguments == "--no-mtime" && notes == [Messages.importPostprocessorArgs("A")])
        notes = []
        let bad = try #require(try JSONSerialization.jsonObject(with: Data(#"{"extraArgs": "--exec 'rm -rf ~'"}"#.utf8)) as? [String: Any])
        let refused = StudioImporter.recipe(fromOptions: bad, notes: &notes, context: "B")
        #expect(refused.extraArguments.isEmpty && notes == [Messages.importExtraArgumentsRefused("B")])
        #expect(RecipeValidator.errors(in: refused).isEmpty)
    }

    @Test func presetsDefaultsAndToolPathsComeOver() throws {
        let presets = Data(#"[{"id": "AAAA", "name": "Podcast", "options": {"mode": "audio"}}, {"name": " ", "options": {}}, {"name": "No options"}]"#.utf8)
        let source = StudioImporter.Source(currentOptions: options(""), userPresets: presets, ytdlpOverride: "/opt/y/yt-dlp", ffmpegOverride: "/not/there/ffmpeg")
        let result = StudioImporter.importSettings(source, isExecutable: { $0 == "/opt/y/yt-dlp" })
        #expect(result.defaultsPreset?.name == "Studio defaults" && result.defaultsPreset?.group == .user)
        #expect(result.presets.map(\.name) == ["Podcast"] && result.presets[0].recipe.mode == .audio)
        #expect(result.toolPaths == [.ytdlp: "/opt/y/yt-dlp"])
        #expect(StudioImporter.importSettings(StudioImporter.Source()) == StudioImporter.Result())
    }
}

@Suite struct MigrationTests {
    private struct Setup {
        let root: URL, paths: AppPaths, phobos: URL, media: URL, library: LibraryRepository
        init() throws {
            root = try scratch("migration")
            paths = AppPaths(root: root.appendingPathComponent("support"))
            try paths.createFolders()
            media = root.appendingPathComponent("a.mp4")
            try Data(repeating: 1, count: 42).write(to: media)
            phobos = try makePhobosFolder(in: root, mediaFile: media.path)
            library = LibraryRepository(paths: paths)
        }
        func run(studio: StudioImporter.Source = StudioImporter.Source()) async -> Migration.Summary? {
            await Migration.runOnce(paths: paths, library: library, phobosFolder: phobos,
                                    defaults: { domain, key in domain == "local.deimos.phobos" && key == "settings.v2" ? phobosSettings : nil },
                                    studio: studio, isExecutable: { _ in true })
        }
    }

    @Test func everythingComesOverAndTheOriginalsAreUntouched() async throws {
        let setup = try Setup()
        defer { try? FileManager.default.removeItem(at: setup.root) }
        let before = listing(setup.phobos).map { name in (name, (try? Data(contentsOf: setup.phobos.appendingPathComponent(name))) ?? Data()) }
        let studio = StudioImporter.Source(currentOptions: Data(#"{"mode": "audio"}"#.utf8), userPresets: Data(#"[{"name": "P", "options": {}}]"#.utf8), ytdlpOverride: "/opt/y")

        let summary = try #require(await setup.run(studio: studio))
        #expect(summary.records == 2 && summary.channels == 1 && summary.presets == 2 && summary.settings && summary.transcripts)
        #expect(summary.sentence == "Brought over from your earlier apps: 2 downloads, 1 followed channel, 2 presets, your settings.")

        #expect(await setup.library.count() == 2)
        let talk = try #require(await setup.library.record(UUID(uuidString: "11111111-1111-1111-1111-111111111111")!))
        #expect(talk.watched && setup.library.thumbnailURL(named: talk.thumbnail) != nil)
        #expect(FollowStore(paths: setup.paths).load().map(\.name) == ["Some Channel"])
        #expect(PresetStore(paths: setup.paths).load().map(\.name) == ["Studio defaults", "P"])
        let settings = SettingsStore(paths: setup.paths).load()
        #expect(settings.folders.mainFolder == "/Volumes/Big/Video" && settings.toolPaths[Tool.ytdlp.rawValue] == "/opt/y")
        #expect(FileManager.default.fileExists(atPath: setup.paths.transcriptsDatabase.path))

        // Phobos's own folder is exactly as it was.
        let after = listing(setup.phobos).map { name in (name, (try? Data(contentsOf: setup.phobos.appendingPathComponent(name))) ?? Data()) }
        #expect(before.map(\.0) == after.map(\.0) && before.map(\.1) == after.map(\.1))
        #expect(FileManager.default.fileExists(atPath: setup.phobos.appendingPathComponent("thumbs/abc.jpg").path))
        #expect(Migration.lastSummary(paths: setup.paths) == summary)
    }

    @Test func itRunsOnlyOnce() async throws {
        let setup = try Setup()
        defer { try? FileManager.default.removeItem(at: setup.root) }
        #expect(await setup.run() != nil)
        await setup.library.setWatched(UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, true)
        #expect(await setup.run() == nil)
        #expect(await setup.library.count() == 2)
    }

    @Test func applyingTwiceAddsNothingAndKeepsThePersonsChanges() async throws {
        let setup = try Setup()
        defer { try? FileManager.default.removeItem(at: setup.root) }
        let result = PhobosImporter.read(supportFolder: setup.phobos, preferences: phobosSettings)
        let first = await Migration.apply(phobos: result, studio: StudioImporter.Result(), paths: setup.paths, library: setup.library)
        #expect(first.records == 2)
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        await setup.library.setWatched(id, false)
        var settings = SettingsStore(paths: setup.paths).load()
        settings.maxConcurrent = 4
        try SettingsStore(paths: setup.paths).save(settings)

        let second = await Migration.apply(phobos: result, studio: StudioImporter.Result(), paths: setup.paths, library: setup.library)
        #expect(second.isEmpty && !second.settings)
        #expect(await setup.library.record(id)?.watched == false && SettingsStore(paths: setup.paths).load().maxConcurrent == 4)
    }

    @Test func aMacWithNeitherAppBringsNothingAndMayTryAgainLater() async throws {
        let root = try scratch("migration-none")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root.appendingPathComponent("support"))
        let library = LibraryRepository(paths: paths)
        let summary = await Migration.runOnce(paths: paths, library: library, phobosFolder: root.appendingPathComponent("Phobos"),
                                              defaults: { _, _ in nil }, studio: StudioImporter.Source())
        #expect(summary == nil && !FileManager.default.fileExists(atPath: paths.importRecord.path))
    }
}

@Suite struct FollowingTests {
    private let sample: [String: Any] = [
        "extractor_key": "YoutubeTab", "channel": "Some Channel - Videos",
        "entries": [
            ["id": "a1", "title": "One", "url": "https://www.youtube.com/watch?v=a1", "duration": 61],
            ["id": "a1", "title": "Repeat"],
            ["id": "b2", "title": "Two", "url": "b2", "duration": 3725],
            ["entries": [["id": "v1", "title": "In a tab"]]],
            ["title": "No id"],
        ],
    ]

    @Test func aChannelListingIsRead() throws {
        let feed = try #require(Following.parse(sample))
        #expect(feed.title == "Some Channel" && feed.site == "YouTube")
        #expect(feed.entries.map(\.id) == ["a1", "b2", "v1"])
        #expect(feed.entries.map(\.duration) == ["1:01", "1:02:05", ""])
        #expect(feed.entries[1].url == "https://www.youtube.com/watch?v=b2")
        #expect(Following.parse(["id": "x", "title": "One video"]) == nil)
        #expect(Following.interpret(output: #"{"id": "x"}"#, errors: "") == .failure(Messages.notAChannel))
        #expect(Following.interpret(output: "", errors: "ERROR: HTTP Error 404: Not Found") == .failure(ErrorTranslator.friendly("ERROR: HTTP Error 404: Not Found")))
    }

    @Test func onlyVideosNotSeenAreNewAndTheListIsBounded() throws {
        let feed = try #require(Following.parse(sample))
        var channel = FollowStore.newChannel(link: "https://www.youtube.com/@some", feed: feed, now: Date(timeIntervalSince1970: 5))
        #expect(channel.seen == ["a1", "b2", "v1"] && channel.fresh(in: feed).isEmpty && channel.link.hasSuffix("/videos"))
        channel.seen = ["a1"]
        #expect(channel.fresh(in: feed).map(\.id) == ["b2", "v1"])
        channel.markSeen(["b2", "b2"])
        #expect(channel.seen == ["a1", "b2"])
        channel.markSeen((0..<700).map { "n\($0)" })
        #expect(channel.seen.count == Channel.seenLimit && channel.seen.last == "n699")
    }

    @Test func theCommandIgnoresConfigAndEndsWithTheLink() throws {
        let toolchain = YtdlpCommand.Toolchain(ytdlp: "/t/yt-dlp", deno: "/t/deno", environment: [:])
        let plan = try Following.plan(link: "https://www.youtube.com/@some/videos", cookiesFile: "/c.txt", toolchain: toolchain)
        #expect(plan.arguments.first == "--ignore-config" && plan.arguments.suffix(2) == ["--", "https://www.youtube.com/@some/videos"])
        #expect(plan.arguments.contains("--flat-playlist") && plan.arguments.contains("/c.txt") && plan.arguments.contains("--playlist-end"))
        #expect(throws: ProbeFailure.self) { try Following.plan(link: "file:///etc/passwd", cookiesFile: nil, toolchain: toolchain) }
    }

    @Test func channelsSurviveARestartAndABadFileIsSetAside() throws {
        let root = try scratch("follow")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FollowStore(file: root.appendingPathComponent("following.json"))
        #expect(store.load().isEmpty)
        let channel = Channel(name: "C", site: "YouTube", link: "https://www.youtube.com/@c/videos", seen: ["x"], lastChecked: Date(timeIntervalSince1970: 100))
        try store.save([channel])
        #expect(store.load() == [channel])
        try Data("nonsense".utf8).write(to: store.file)
        #expect(store.load().isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("following.unreadable.json").path))
    }
}

@Suite struct PresetStoreTests {
    @Test func presetsRoundTripAndAnUnreadableOneIsSkipped() throws {
        let root = try scratch("presets")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PresetStore(file: root.appendingPathComponent("presets.json"))
        var recipe = DownloadRecipe(); recipe.mode = .audio
        let preset = Preset(id: "u1", name: "Mine", group: .user, recipe: recipe)
        try store.save([preset])
        #expect(store.load() == [preset])
        let data = Data(#"{"version": 1, "presets": [{"id": "ok", "name": "Ok", "recipe": {}}, {"name": "No id"}, 5]}"#.utf8)
        #expect(PresetStore.decode(data)?.map(\.id) == ["ok"])
    }
}
