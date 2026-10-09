import Foundation
import Testing
@testable import Engine

// Phase 8: presets of the person's own, sharing them, the recipe Customize
// edits, and the command preview.

private let rules = FolderRules(mainFolder: "/Users/sam/Movies", audioFolder: "/Users/sam/Music/App")
private let toolchain = YtdlpCommand.Toolchain(ytdlp: "/tools/yt-dlp", ffmpeg: "/tools/ffmpeg", deno: "/tools/deno", environment: [:])
private let archive = "/support/download-archive.txt"

private func media(seconds: Double = 600, chapters: Int = 0) -> MediaFacts {
    let formats = [
        MediaFormat(id: "140", ext: "m4a", audioCodec: "mp4a.40.2", hasVideo: false, hasAudio: true, bytes: 9_000_000),
        MediaFormat(id: "136", ext: "mp4", width: 1280, height: 720, videoCodec: "avc1.64001f", hasVideo: true, hasAudio: false, bytes: 90_000_000),
        MediaFormat(id: "137", ext: "mp4", width: 1920, height: 1080, videoCodec: "avc1.640028", hasVideo: true, hasAudio: false, bytes: 200_000_000),
    ]
    return MediaFacts(facts: VideoFacts(id: "abc", title: "A talk", uploader: "Someone"), site: "YouTube",
                      link: "https://www.youtube.com/watch?v=abc", seconds: seconds, duration: TimeText.clock(seconds),
                      chapters: (0..<chapters).map { MediaChapter(start: Double($0) * 60, title: "Part \($0 + 1)") },
                      formats: formats)
}

private let list = PlaylistFacts(title: "Lectures", uploader: "Someone", site: "YouTube", count: 12,
                                 link: "https://www.youtube.com/playlist?list=PL1")

private func preset(named name: String) -> Preset {
    PresetCatalog.advanced.first { $0.name.hasPrefix(name) }!
}

// MARK: - The shelf

@Suite struct PresetShelfTests {
    @Test func savingAddsAPresetAndSavingUnderTheSameNameReplacesIt() throws {
        var shelf = PresetShelf()
        var recipe = DownloadRecipe()
        recipe.container = .mkv
        let firstSaved = shelf.save(name: "  Lectures ", recipe: recipe)
        let first = try #require(firstSaved)
        #expect(first.name == "Lectures" && first.group == .user && first.recipe.container == .mkv)
        #expect(shelf.presets == [first])

        recipe.container = .mp4
        let againSaved = shelf.save(name: "lectures", recipe: recipe)
        let again = try #require(againSaved)
        #expect(shelf.presets.count == 1)
        #expect(again.id == first.id && again.recipe.container == .mp4)
        #expect(shelf.preset(id: first.id) == again)
        let blank = shelf.save(name: "   ", recipe: recipe)
        #expect(blank == nil)
    }

    @Test func aPresetNeverKeepsAClip() throws {
        var shelf = PresetShelf()
        var recipe = DownloadRecipe()
        recipe.clip = Clip(start: 10, end: 20)
        recipe.customFormat = "137+140"
        let savedSaved = shelf.save(name: "Part", recipe: recipe)
        let saved = try #require(savedSaved)
        #expect(saved.recipe.clip == nil)
        #expect(saved.recipe.customFormat == "137+140")
    }

    @Test func renamingRefusesAnEmptyOrTakenName() throws {
        var shelf = PresetShelf()
        let oneSaved = shelf.save(name: "One", recipe: DownloadRecipe())
        let one = try #require(oneSaved)
        let twoSaved = shelf.save(name: "Two", recipe: DownloadRecipe())
        let two = try #require(twoSaved)
        let clash = shelf.rename(id: two.id, to: "one")
        let empty = shelf.rename(id: two.id, to: " ")
        let nobody = shelf.rename(id: "nobody", to: "Three")
        #expect(!clash && !empty && !nobody)
        let renamed = shelf.rename(id: two.id, to: "Three")
        // Its own name in other letters is a rename, not a clash.
        let recased = shelf.rename(id: one.id, to: "ONE")
        #expect(renamed && recased)
        #expect(shelf.presets.map(\.name) == ["ONE", "Three"])
        shelf.remove(id: one.id)
        #expect(shelf.presets.map(\.name) == ["Three"])
    }

    @Test func anImportNeverReplacesAnything() throws {
        var shelf = PresetShelf()
        let mineSaved = shelf.save(name: "Podcast", recipe: DownloadRecipe())
        let mine = try #require(mineSaved)
        var other = DownloadRecipe()
        other.mode = .audio
        let added = shelf.add(imported: [Preset(id: mine.id, name: "Podcast", recipe: other), Preset(name: "Podcast", recipe: other)])
        #expect(added.map(\.name) == ["Podcast 2", "Podcast 3"])
        #expect(Set(shelf.presets.map(\.id)).count == 3)
        #expect(shelf.preset(id: mine.id)?.recipe == DownloadRecipe())
    }

    @Test func builtInPresetsPutOnTheShelfBecomeThePersonsOwn() {
        let shelf = PresetShelf([PresetCatalog.best])
        #expect(shelf.presets.first?.group == .user)
    }

    @Test func theShelfSurvivesTheStore() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PresetStore(file: folder.appendingPathComponent("presets.json"))
        var shelf = PresetShelf()
        shelf.save(name: "Mine", recipe: preset(named: "Podcast").recipe)
        try store.save(shelf.presets)
        #expect(PresetShelf(store.load()) == shelf)
    }
}

// MARK: - Sharing

@Suite struct PresetExchangeTests {
    @Test func presetsRoundTripThroughAFile() throws {
        var mine = preset(named: "Archive").recipe
        mine.extraArguments = "--no-check-certificates --geo-bypass-country \"US\""
        mine.playlistItems = "1-5,8"
        let exported = [Preset(name: "Everything", recipe: mine), Preset(name: "Podcast", recipe: preset(named: "Podcast").recipe)]
        let data = try PresetExchange.export(exported)
        let read = try #require(PresetExchange.read(data))
        #expect(read.refused.isEmpty && read.notes.isEmpty)
        #expect(read.presets.map(\.name) == ["Everything", "Podcast"])
        #expect(read.presets.map(\.recipe) == exported.map(\.recipe))
        #expect(read.presets.allSatisfy { $0.group == .user })
        // Ids stay at home: a shared preset gets new ones.
        #expect(Set(read.presets.map(\.id)).isDisjoint(with: exported.map(\.id)))
        #expect(read.summary == "2 presets were imported.")

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["format"] as? String == "studio-x-phobos.presets")
        #expect(object["version"] as? Int == 1)
    }

    @Test func anImportedPresetThatCouldRunAProgramIsRefused() throws {
        // The plan's check: a preset containing --exec is refused. So is an
        // abbreviation of it, and an option that loads other settings.
        for extras in ["--exec 'rm -rf ~'", "--exe echo", "--config-locations /tmp/x", "-a links.txt", "--no-mtime --"] {
            let file = """
            {"format": "studio-x-phobos.presets", "version": 1, "presets": [
              {"name": "Looks harmless", "recipe": {"mode": "audio", "extraArguments": "\(extras.replacingOccurrences(of: "\"", with: "\\\""))"}},
              {"name": "Fine", "recipe": {"mode": "audio", "extraArguments": "--no-part"}}
            ]}
            """
            let read = try #require(PresetExchange.read(Data(file.utf8)))
            #expect(read.presets.map(\.name) == ["Fine"], "\(extras)")
            #expect(read.refused.count == 1)
            #expect(read.refused.first?.hasPrefix("\"Looks harmless\" was not imported: the extra option") == true, "\(read.refused)")
            #expect(read.summary.hasPrefix("1 preset was imported. \"Looks harmless\" was not imported"))
        }
        // An unfinished quote is refused too: what it means cannot be known.
        let open = #"{"presets": [{"name": "Open", "recipe": {"extraArguments": "--proxy 'x"}}]}"#
        let read = try #require(PresetExchange.read(Data(open.utf8)))
        #expect(read.presets.isEmpty && read.refused.count == 1)
        #expect(!read.summary.contains("no presets"))
    }

    @Test func aFileThatIsNotPresetsIsRefusedWhole() {
        #expect(PresetExchange.read(Data("not json".utf8)) == nil)
        #expect(PresetExchange.read(Data(#"{"version": 1}"#.utf8)) == nil)
        #expect(PresetExchange.read(Data(#"[1, 2]"#.utf8)) == nil)
        let empty = PresetExchange.read(Data(#"{"presets": [{"name": "", "recipe": {}}, {"name": "No recipe"}, 7]}"#.utf8))
        #expect(empty?.presets.isEmpty == true)
        #expect(empty?.summary == Messages.presetsImported(0))
    }

    @Test func aPresetFromAnotherVersionKeepsWhatStillFits() throws {
        let file = #"{"presets": [{"name": "Old", "id": "x", "group": "guided", "recipe": {"mode": "audio", "container": "avi", "audioFormat": "flac", "somethingNew": 3, "clip": {"start": 5}}}]}"#
        let read = try #require(PresetExchange.read(Data(file.utf8)))
        let recipe = try #require(read.presets.first?.recipe)
        #expect(recipe.mode == .audio && recipe.audioFormat == .flac)
        #expect(recipe.container == .automatic)
        #expect(recipe.clip == nil)
        #expect(read.presets.first?.group == .user)
    }

    @Test func aPresetThatCannotRunAsItIsComesOverWithANote() throws {
        let file = #"{"presets": [{"name": "Odd", "recipe": {"playlistItems": "first three"}}]}"#
        let read = try #require(PresetExchange.read(Data(file.utf8)))
        #expect(read.presets.count == 1 && read.refused.isEmpty)
        #expect(read.notes == ["\"Odd\" was imported but can't run as it is: playlist items must look like 1-5, 8 or 3:10, with commas between parts."])
    }

    @Test func anExportIsNamedAfterWhatItHolds() {
        #expect(PresetExchange.suggestedFileName(for: [Preset(name: "Talks: 720p/small", recipe: DownloadRecipe())]) == "Talks- 720p-small.json")
        #expect(PresetExchange.suggestedFileName(for: PresetCatalog.advanced) == "HeatBox presets.json")
    }
}

// MARK: - A recipe of the person's own on the Download screen

@Suite struct CustomDraftTests {
    private let everything = DownloadDefaults(subtitles: true, coverImage: true, cutSponsors: true, exactCut: false, evenLoudness: true)

    @Test func aPresetIsUsedExactlyAsItStands() throws {
        var draft = DownloadDraft(target: .video(media()))
        draft.pick(PresetCatalog.bestID)
        let podcast = preset(named: "Podcast")
        draft.apply(podcast)
        #expect(draft.choice == nil && draft.selectedID == nil)
        #expect(draft.isPicked && draft.pickedName == podcast.name)
        // Settings' defaults are not laid over a preset.
        #expect(draft.recipe(defaults: everything) == podcast.recipe)
        let request = try #require(draft.requests(defaults: everything).first)
        #expect(request.recipe == podcast.recipe && request.label == podcast.name)
        #expect(request.resolution == JobResolution(media()))
        #expect(draft.folder(rules: rules) == "/Users/sam/Music/App")
        #expect(draft.summary(rules: rules, home: "/Users/sam") == "\(podcast.name) · Music › App")
        #expect(draft.isReady(defaults: everything))
        #expect(!draft.showsGuidedSwitches)
    }

    @Test func customizingStartsFromThePickedChoiceWithSettingsDefaultsInIt() throws {
        var draft = DownloadDraft(target: .video(media()))
        draft.pick(PresetCatalog.resolutionID(720))
        let guided = try #require(draft.recipe(defaults: everything))
        draft.customize(defaults: everything)
        let custom = try #require(draft.custom)
        #expect(custom.name == "Up to 720p, customized")
        #expect(custom.presetID == PresetCatalog.resolutionID(720))
        #expect(custom.recipe == guided)
        #expect(custom.recipe.writeSubtitles && custom.recipe.embedThumbnail && custom.recipe.sponsorBlock == .remove)
        // From here the recipe is the truth: changing Settings no longer changes it.
        #expect(draft.recipe(defaults: DownloadDefaults()) == guided)
        // Customizing again keeps what was changed.
        draft.edit { $0.container = .mkv }
        draft.customize(defaults: DownloadDefaults())
        #expect(draft.custom?.recipe.container == .mkv)
    }

    @Test func customizingWithNothingPickedStartsFromTheFirstChoice() throws {
        var draft = DownloadDraft(target: .playlist(list))
        draft.customize(defaults: DownloadDefaults())
        #expect(draft.custom?.presetID == draft.choices.first?.id)
        #expect(draft.custom?.recipe == draft.choices.first?.recipe)
        #expect(draft.isPicked)
    }

    @Test func pickingAChoiceAgainGoesBackToTheGuidedFlow() throws {
        var draft = DownloadDraft(target: .video(media()))
        draft.pick(PresetCatalog.audioID)
        draft.customize(defaults: DownloadDefaults())
        draft.edit { $0.audioFormat = .flac }
        draft.dropCustom()
        #expect(draft.custom == nil && draft.selectedID == PresetCatalog.audioID)
        #expect(draft.recipe(defaults: DownloadDefaults()) == PresetCatalog.audioOnly.recipe)

        draft.apply(preset(named: "Lossless"))
        draft.pick(PresetCatalog.bestID)
        #expect(draft.custom == nil)
        #expect(draft.recipe(defaults: DownloadDefaults()) == PresetCatalog.best.recipe)
        // Going back from a preset that was no choice leaves nothing picked.
        draft.apply(preset(named: "Lossless"))
        draft.dropCustom()
        #expect(!draft.isPicked)
    }

    @Test func editingWithoutARecipeOfOnesOwnDoesNothing() {
        var draft = DownloadDraft(target: .video(media()))
        draft.pick(PresetCatalog.bestID)
        let before = draft
        draft.edit { $0.container = .mkv }
        #expect(draft == before)
    }

    @Test func anErrorInTheRecipeStopsTheDownloadAndAWarningDoesNot() {
        var draft = DownloadDraft(target: .playlist(list))
        #expect(!draft.isReady(defaults: DownloadDefaults()))
        draft.customize(defaults: DownloadDefaults())
        #expect(draft.isReady(defaults: DownloadDefaults()))
        draft.edit { $0.playlistItems = "first three" }
        #expect(draft.issues(defaults: DownloadDefaults()).map(\.field) == ["playlistItems"])
        #expect(!draft.isReady(defaults: DownloadDefaults()))
        draft.edit { $0.playlistItems = "1-3"; $0.cookieBrowser = .safari }
        #expect(draft.issues(defaults: DownloadDefaults()).map(\.severity) == [.warning])
        #expect(draft.isReady(defaults: DownloadDefaults()))
        // The range reaches the queue with the recipe.
        #expect(draft.requests(defaults: DownloadDefaults()).first?.recipe.playlistItems == "1-3")
    }

    @Test func thereIsOneClipAndItIsTheClipBars() throws {
        var draft = DownloadDraft(target: .video(media(chapters: 4)))
        var album = preset(named: "Album").recipe
        album.clip = Clip(start: 30, end: 90)
        draft.apply(Preset(name: "Album, trimmed", recipe: album))
        // A clip saved in a preset moves to the bar; the recipe itself holds none.
        #expect(draft.custom?.recipe.clip == nil)
        #expect(draft.clipOn && draft.clipStart == 30 && draft.clipEnd == 90)
        let recipe = try #require(draft.recipe(defaults: DownloadDefaults()))
        #expect(recipe.clip == Clip(start: 30, end: 90))
        // A clip cannot also be split into chapters: the clip wins, and the screen can say so.
        #expect(album.splitChapters && !recipe.splitChapters && draft.clipOverridesChapters)
        #expect(RecipeValidator.errors(in: recipe).isEmpty)
        #expect(draft.summary(rules: rules, home: "/Users/sam").contains("0:30 to 1:30"))

        draft.clipOn = false
        let whole = try #require(draft.recipe(defaults: DownloadDefaults()))
        #expect(whole.clip == nil && whole.splitChapters && !draft.clipOverridesChapters)

        // A saved clip longer than the video is kept inside it.
        var short = DownloadDraft(target: .video(media(seconds: 60)))
        short.apply(Preset(name: "Late", recipe: album))
        #expect(short.clipStart == 30 && short.clipEnd == 60)
        #expect(short.recipe(defaults: DownloadDefaults())?.clip == Clip(start: 30, end: nil))
    }

    @Test func aListKeepsThePartOfEachVideoInItsRecipe() throws {
        var draft = DownloadDraft(target: .playlist(list))
        var recipe = DownloadRecipe()
        recipe.clip = Clip(start: 0, end: 45)
        draft.apply(Preset(name: "Openings", recipe: recipe))
        #expect(!draft.clipOn)
        #expect(draft.recipe(defaults: DownloadDefaults())?.clip == Clip(start: 0, end: 45))
        draft.edit { $0.clip = nil }
        #expect(draft.recipe(defaults: DownloadDefaults())?.clip == nil)
    }

    @Test func customizingKeepsTheClipOnTheBarAndTheWayItIsCut() throws {
        var draft = DownloadDraft(target: .video(media()))
        draft.pick(PresetCatalog.bestID)
        draft.clipOn = true
        draft.clipStart = 10
        draft.clipEnd = 20
        draft.customize(defaults: DownloadDefaults(exactCut: false))
        #expect(draft.custom?.recipe.clip == nil)
        #expect(draft.custom?.recipe.exactCut == false)
        #expect(draft.recipe(defaults: DownloadDefaults())?.clip == Clip(start: 10, end: 20))
        // Segments that are cut out are always cut exactly.
        var sponsors = DownloadDraft(target: .video(media()))
        sponsors.pick(PresetCatalog.bestID)
        sponsors.customize(defaults: DownloadDefaults(cutSponsors: true, exactCut: false))
        #expect(sponsors.custom?.recipe.exactCut == true)
    }

    @Test func rowsPickedInAllFormatsBecomeTheFormatChoice() throws {
        var draft = DownloadDraft(target: .video(media()))
        draft.pick(PresetCatalog.compatibleID)
        draft.useFormats(["137", "140"], defaults: DownloadDefaults())
        let custom = try #require(draft.custom)
        #expect(custom.recipe.customFormat == "137+140")
        #expect(custom.recipe.container == .mp4)
        #expect(custom.name == "Plays everywhere, customized")
        // Nothing picked, or a list: nothing changes.
        var untouched = DownloadDraft(target: .video(media()))
        untouched.useFormats([], defaults: DownloadDefaults())
        #expect(untouched.custom == nil)
        var listDraft = DownloadDraft(target: .playlist(list))
        listDraft.useFormats(["137"], defaults: DownloadDefaults())
        #expect(listDraft.custom == nil)
    }

    @Test func thePickedCommentTravelsWithTheRequestOnlyWhileChaptersComeFromComments() throws {
        var draft = DownloadDraft(target: .video(media()))
        draft.customize(defaults: DownloadDefaults())
        draft.edit { $0.chapterSource = .comments }
        draft.chapterComment = "c9"
        #expect(draft.requests(defaults: DownloadDefaults()).first?.chapterComment == "c9")
        draft.edit { $0.chapterSource = .youtube }
        #expect(draft.chapterComment == nil)
        #expect(draft.requests(defaults: DownloadDefaults()).first?.chapterComment == nil)
        // Another preset or choice starts without one.
        draft.edit { $0.chapterSource = .commentsIfMissing }
        draft.chapterComment = "c9"
        draft.apply(preset(named: "Podcast"))
        #expect(draft.chapterComment == nil)
    }

    @Test func someoneWhoNeverOpensCustomizeGetsExactlyWhatTheyGotBefore() throws {
        // The guided flow, request for request, as Phase 5 built it.
        for defaults in [DownloadDefaults(), DownloadDefaults(subtitles: true, coverImage: true, cutSponsors: true, exactCut: false, evenLoudness: true)] {
            for choice in ChoiceBuilder.choices(for: media(chapters: 3)) {
                var draft = DownloadDraft(target: .video(media(chapters: 3)))
                draft.pick(choice.id)
                draft.splitChapters = true
                var expected = choice.recipe
                let video = expected.mode != .audio
                if video && defaults.subtitles { expected = expected.withSubtitles() }
                if video && defaults.coverImage { expected.embedThumbnail = true }
                if !video && defaults.evenLoudness { expected.evenLoudness = true }
                expected.splitChapters = true
                if defaults.cutSponsors { expected = expected.cuttingSponsors() }
                #expect(draft.requests(defaults: defaults) == [.video(media(chapters: 3), preset: choice.preset, recipe: expected)])
                #expect(draft.custom == nil && draft.showsGuidedSwitches)
            }
        }
        var playlist = DownloadDraft(target: .playlist(list))
        playlist.pick(PresetCatalog.audioID)
        #expect(playlist.requests(defaults: DownloadDefaults()) == [.playlist(list, preset: PresetCatalog.audioOnly)])
        var links = DownloadDraft(target: .links(["https://a.example/1", "https://b.example/2"]))
        links.pick(PresetCatalog.bestID)
        #expect(links.requests(defaults: DownloadDefaults()) == JobRequest.links(["https://a.example/1", "https://b.example/2"], preset: PresetCatalog.best))
    }
}

// MARK: - The command preview

@Suite struct CommandPreviewTests {
    private func preview(_ draft: DownloadDraft, defaults: DownloadDefaults = DownloadDefaults(), speed: Int = 0,
                         toolchain chosen: YtdlpCommand.Toolchain? = toolchain) -> CommandPreview {
        draft.preview(defaults: defaults, rules: rules, speedLimitKB: speed, archiveFile: archive, toolchain: chosen)
    }

    /// The visible arguments a job built from the draft's first request runs with, in a working folder.
    private func running(_ draft: DownloadDraft, defaults: DownloadDefaults = DownloadDefaults(), speed: Int = 0) throws -> [String] {
        let request = try #require(draft.requests(defaults: defaults).first)
        let job = Job(createdAt: Date(timeIntervalSince1970: 0), request: request)
        let own = job.recipe.useArchive ? archive : (job.isPlaylist ? "/work/archive.txt" : nil)
        var command = job.commandRequest(folder: "/work/files", archiveFile: own, cookiesFile: nil, speedLimitKB: speed)
        command.workspace = "/work/partial"
        command.outputListFile = "/work/files.txt"
        return try YtdlpCommand.plan(command, toolchain: toolchain).visibleArguments
    }

    @Test func nothingPickedOrNoToolIsOneSentence() {
        let draft = DownloadDraft(target: .video(media()))
        #expect(preview(draft) == CommandPreview(problem: Messages.previewNeedsChoice))
        var picked = draft
        picked.pick(PresetCatalog.bestID)
        #expect(preview(picked, toolchain: nil) == CommandPreview(problem: Messages.noTool))
    }

    @Test func thePreviewIsWhatRunsExceptForTheFolder() throws {
        var guided = DownloadDraft(target: .video(media()))
        guided.pick(PresetCatalog.compatibleID)
        guided.clipOn = true
        guided.clipStart = 5
        guided.clipEnd = 65
        var customized = DownloadDraft(target: .video(media()))
        customized.apply(preset(named: "Archive"))
        customized.edit { $0.extraArguments = "--geo-bypass-country 'US'"; $0.rateLimit = "2M" }
        var shrink = DownloadDraft(target: .video(media()))
        shrink.apply(preset(named: "Shrink"))

        for (draft, speed) in [(guided, 0), (guided, 500), (customized, 500), (shrink, 0)] {
            let shown = preview(draft, speed: speed)
            var expected = try running(draft, speed: speed)
            let folder = try #require(expected.firstIndex(of: "/work/files"))
            #expect(expected[folder - 1] == "-P")
            expected[folder] = try #require(draft.folder(rules: rules))
            #expect(shown.command == (["yt-dlp"] + expected.map(DisplayCommand.shellQuote)).joined(separator: " "))
            #expect(shown.problem == nil)
            #expect(shown.notes.first == Messages.previewDestination)
            // Nothing of the app's bookkeeping is in it.
            #expect(!shown.command.contains("/work") && !shown.command.contains("[[PROG]]") && !shown.command.contains("temp:"))
        }
        let command = preview(guided, speed: 500).command
        #expect(command.hasPrefix("yt-dlp --ignore-config --js-runtimes deno:/tools/deno --ffmpeg-location /tools/ffmpeg "))
        #expect(command.contains("--download-sections '*0:05-1:05' --force-keyframes-at-cuts"))
        #expect(command.contains("--no-playlist") && command.contains("--limit-rate 500K"))
        #expect(command.contains("-P /Users/sam/Movies/YouTube"))
        #expect(command.hasSuffix("-- 'https://www.youtube.com/watch?v=abc'"))
        // The recipe's own speed limit wins over the one from Settings.
        #expect(preview(customized, speed: 500).command.contains("--limit-rate 2M"))
        #expect(preview(customized, speed: 500).command.contains("--geo-bypass-country US"))
        // A recipe that keeps its own list of what is downloaded names the real one.
        #expect(preview(customized).command.contains("--download-archive \(archive)"))
    }

    @Test func aPlaylistShowsItsMannersAndLeavesThePrivateListOut() throws {
        var draft = DownloadDraft(target: .playlist(list))
        draft.pick(PresetCatalog.bestID)
        draft.customize(defaults: DownloadDefaults())
        draft.edit { $0.playlistItems = "2-4" }
        let shown = preview(draft)
        #expect(shown.command.contains("--yes-playlist --ignore-errors -I 2-4"))
        #expect(shown.command.contains("--sleep-interval 1 --max-sleep-interval 4"))
        #expect(shown.command.contains("-P /Users/sam/Movies/YouTube/Lectures"))
        #expect(!shown.command.contains("--download-archive"))
        #expect(shown.notes == [Messages.previewDestination, Messages.previewPrivateArchive])
        // Apart from the folder, the job adds only its private list.
        var expected = try running(draft)
        let own = try #require(expected.firstIndex(of: "--download-archive"))
        expected.removeSubrange(own...(own + 1))
        expected[try #require(expected.firstIndex(of: "/work/files"))] = "/Users/sam/Movies/YouTube/Lectures"
        #expect(shown.command == (["yt-dlp"] + expected.map(DisplayCommand.shellQuote)).joined(separator: " "))

        draft.edit { $0.useArchive = true }
        let kept = preview(draft)
        #expect(kept.command.contains("--download-archive \(archive)"))
        #expect(kept.notes == [Messages.previewDestination])
    }

    @Test func severalLinksAreOneCommandInTheMainFolder() {
        var draft = DownloadDraft(target: .links(["https://a.example/1", "https://www.youtube.com/watch?v=abc&list=PL1"]))
        draft.pick(PresetCatalog.audioID)
        let shown = preview(draft)
        #expect(shown.command.contains("-P /Users/sam/Movies "))
        #expect(shown.command.hasSuffix("-- https://a.example/1 'https://www.youtube.com/watch?v=abc'"))
        #expect(shown.notes == [Messages.previewDestination, Messages.previewEachSite])
    }

    @Test func whatTheCommandCannotDoAloneIsSaid() {
        var draft = DownloadDraft(target: .video(media()))
        draft.customize(defaults: DownloadDefaults())
        draft.edit { $0.chapterSource = .comments; $0.cookieBrowser = .firefox }
        let shown = preview(draft)
        #expect(shown.notes == [Messages.previewDestination, Messages.commentChapters])
        #expect(shown.warnings == [Messages.recipeCookiesBrowser])
        #expect(shown.command.contains("--cookies-from-browser firefox"))
    }

    @Test func aRecipeThatCannotRunShowsItsSentenceInsteadOfACommand() {
        var draft = DownloadDraft(target: .video(media()))
        draft.customize(defaults: DownloadDefaults())
        draft.edit { $0.extraArguments = "--exec 'open -a Calculator'" }
        let shown = preview(draft)
        #expect(shown.command.isEmpty)
        #expect(shown.problem == Messages.recipeExtraArguments(.refused(option: "--exec", reason: .notAllowed)))
        #expect(!draft.isReady(defaults: DownloadDefaults()))
    }
}

// MARK: - Words and the picker's look-up

@Suite struct CustomizeWordingTests {
    @Test func everyChoiceHasItsOwnWords() {
        func check<Value: CaseIterable>(_ type: Value.Type, _ label: (Value) -> String) {
            let labels = Value.allCases.map(label)
            #expect(labels.allSatisfy { !$0.isEmpty }, "\(type)")
            #expect(Set(labels).count == labels.count, "\(type)")
        }
        check(DownloadMode.self, \.label)
        check(VideoContainer.self, \.label)
        check(MaxResolution.self, \.label)
        check(VideoCodecPreference.self, \.label)
        check(AudioCodecPreference.self, \.label)
        check(FrameRateLimit.self, \.label)
        check(AudioFormat.self, \.label)
        check(AudioQuality.self, \.label)
        check(SampleRate.self, \.label)
        check(ChannelLayout.self, \.label)
        check(VideoEncoder.self, \.label)
        check(EncoderSpeed.self, \.label)
        check(ScaleHeight.self, \.label)
        check(AudioBitrate.self, \.label)
        check(ChapterSource.self, \.label)
        check(SponsorBlockMode.self, \.label)
        check(SponsorCategory.self, \.label)
        check(SubtitleFormat.self, \.label)
        check(ThumbnailFormat.self, \.label)
        check(CookieBrowser.self, \.label)
        check(FilenameTemplate.self, \.label)
        #expect(AudioBitrate.b192.label == "192 kbps")
        #expect(ScaleHeight.h720.label == "720p")
    }
}

@Suite struct CommentPickerLookupTests {
    /// A stand-in for the download tool: a script that prints what a test
    /// asks for. Product code never runs a shell; this is only a fake tool.
    private func fakeTool(_ body: String) throws -> (toolchain: YtdlpCommand.Toolchain, folder: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("picker-tests-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tool = folder.appendingPathComponent("yt-dlp")
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return (YtdlpCommand.Toolchain(ytdlp: tool.path, environment: ["PATH": "/usr/bin:/bin"]), folder)
    }

    private func answering(_ json: String) -> String {
        "cat <<'JSON'\n\(json)\nJSON"
    }

    @Test func theListsInTheCommentsAreFoundBestFirst() async throws {
        let details = #"{"id": "talk", "duration": 600.0, "comments": [{"id": "a", "author": "Brief", "like_count": 50, "text": "0:00 One\n4:00 Two\n8:00 Three"}, {"id": "b", "author": "Chatty", "text": "Loved it at 3:10, honestly"}, {"id": "c", "author": "Thorough", "like_count": 2, "text": "0:00 A\n1:00 B\n2:00 C\n3:00 D"}]}"#
        let fake = try fakeTool(answering(details))
        defer { try? FileManager.default.removeItem(at: fake.folder) }
        let found = await CommentChapters.find(link: "https://www.youtube.com/watch?v=talk", toolchain: fake.toolchain)
        #expect(found.problem == nil)
        #expect(found.candidates.map(\.id) == ["c", "a"])
        #expect(found.candidates.first?.chapters.map(\.title) == ["A", "B", "C", "D"])
        #expect(Messages.commentPickerLine(chapters: 3, likes: 50) == "3 chapters · 50 likes")
        #expect(Messages.commentPickerLine(chapters: 4, likes: 0) == "4 chapters")
    }

    @Test func noListAndNoAnswerAreEachOneSentence() async throws {
        let none = try fakeTool(answering(#"{"id": "talk", "duration": 600.0, "comments": [{"id": "b", "text": "Nice"}]}"#))
        defer { try? FileManager.default.removeItem(at: none.folder) }
        #expect(await CommentChapters.find(link: "https://example.com/v", toolchain: none.toolchain)
            == CommentChapters.Found(problem: Messages.commentPickerNone))

        let broken = try fakeTool("echo 'ERROR: Unable to download webpage' >&2; exit 1")
        defer { try? FileManager.default.removeItem(at: broken.folder) }
        #expect(await CommentChapters.find(link: "https://example.com/v", toolchain: broken.toolchain)
            == CommentChapters.Found(problem: Messages.commentPickerUnreadable))

        // Only a web link is ever handed to the tool.
        #expect(await CommentChapters.find(link: "file:///etc/passwd", toolchain: none.toolchain).candidates.isEmpty)
        #expect(await CommentChapters.find(link: "file:///etc/passwd", toolchain: none.toolchain).problem
            == Messages.commandInvalidLink("file:///etc/passwd"))
    }
}
