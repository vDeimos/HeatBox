import Foundation
import Testing
@testable import Engine

// Ported from Phobos's self-check ("Building a download", subtitles, chapters,
// speed, audio and song tags, sponsors) and from Studio's command-builder
// rules. Phobos built its arguments from a request; here they come from a
// recipe, so each check builds the recipe that expresses the same wish.

private let link = "https://example.com/v"
private let toolchain = YtdlpCommand.Toolchain(ytdlp: "/t/yt-dlp", ffmpeg: "/t/ffmpeg", deno: "/t/deno", environment: ["PATH": "/t"])

private func plan(_ recipe: DownloadRecipe = DownloadRecipe(), links: [String] = [link], folder: String = "/m/Site",
                  edit: (inout YtdlpCommand.Request) -> Void = { _ in }) throws -> YtdlpCommand.Plan {
    var request = YtdlpCommand.Request(recipe: recipe, links: links, folder: folder)
    edit(&request)
    return try YtdlpCommand.plan(request, toolchain: toolchain)
}

private func arguments(_ recipe: DownloadRecipe = DownloadRecipe(), links: [String] = [link]) throws -> [String] {
    try plan(recipe, links: links).arguments
}

private func value(after flag: String, in args: [String]) -> String? {
    args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
}

private func values(after flag: String, in args: [String]) -> [String] {
    args.indices.filter { args[$0] == flag && $0 + 1 < args.count }.map { args[$0 + 1] }
}

@Suite struct YtdlpCommandTests {
    // MARK: Rule 4 and the shape of every command

    @Test func everyCommandIgnoresConfigAndEndsWithTheLinks() throws {
        let args = try arguments(PresetCatalog.best.recipe, links: [link, "https://example.com/w"])
        #expect(args.contains("--ignore-config"))
        #expect(Array(args.suffix(3)) == ["--", link, "https://example.com/w"])
        #expect(args.filter { $0 == "--" }.count == 1)
    }

    @Test func theLinkComesLast() throws {
        #expect(try arguments().last == link)
    }

    @Test func denoAndFfmpegComeFromTheToolchain() throws {
        let args = try arguments()
        #expect(value(after: "--js-runtimes", in: args) == "deno:/t/deno")
        #expect(value(after: "--ffmpeg-location", in: args) == "/t/ffmpeg")
        let bare = try YtdlpCommand.plan(.init(recipe: DownloadRecipe(), links: [link], folder: "/m"),
                                         toolchain: .init(ytdlp: "/t/yt-dlp", environment: [:])).arguments
        #expect(!bare.contains("--js-runtimes") && !bare.contains("--ffmpeg-location"))
    }

    @Test func theToolchainCarriesTheRegistrysPathsAndEnvironment() throws {
        let present: Set<String> = ["/opt/homebrew/bin/yt-dlp", "/opt/homebrew/bin/deno", "/custom/ffmpeg"]
        let registry = ToolRegistry(managedFolder: "/managed", overrides: [.ffmpeg: "/custom/ffmpeg"],
                                    isExecutable: { present.contains($0) })
        let command = try YtdlpCommand.plan(.init(recipe: DownloadRecipe(), links: [link], folder: "/m"), tools: registry)
        #expect(command.executable == "/opt/homebrew/bin/yt-dlp")
        #expect(command.environment == registry.environment())
        #expect(value(after: "--js-runtimes", in: command.arguments) == "deno:/opt/homebrew/bin/deno")
        #expect(value(after: "--ffmpeg-location", in: command.arguments) == "/custom/ffmpeg")
        let process = command.processRequest
        #expect(process.executable == command.executable && process.arguments == command.arguments)
        #expect(process.environment["PATH"]?.hasPrefix("/custom:") == true)
    }

    @Test func aMissingDownloaderIsRefusedWithTheSetupSentence() {
        let registry = ToolRegistry(managedFolder: "/managed", isExecutable: { _ in false })
        #expect(throws: YtdlpCommand.Failure.toolMissing) {
            try YtdlpCommand.plan(.init(recipe: DownloadRecipe(), links: [link], folder: "/m"), tools: registry)
        }
        #expect(YtdlpCommand.Failure.toolMissing.message == Messages.noTool)
    }

    @Test func onlyWebLinksAreAccepted() {
        for bad in ["file:///etc/passwd", "ftp://example.com/v", "not a link", "javascript:alert(1)", "-o /etc/x", "https://", ""] {
            #expect(throws: YtdlpCommand.Failure.invalidLink(bad)) { try arguments(links: [link, bad]) }
        }
        #expect(throws: YtdlpCommand.Failure.noLinks) { try arguments(links: []) }
        #expect(YtdlpCommand.Failure.invalidLink("x").message.contains("http"))
    }

    @Test func aLinkThatLooksLikeAnOptionStaysAfterTheDoubleDash() throws {
        // Not a web link, so refused; and a valid link never sits where an option could be.
        let args = try arguments()
        #expect(args.firstIndex(of: "--")! < args.firstIndex(of: link)!)
    }

    @Test func aRecipeWithErrorsIsRefusedWithItsFirstSentence() {
        var recipe = DownloadRecipe()
        recipe.rateLimit = "fast"
        do {
            _ = try arguments(recipe)
            Issue.record("should have been refused")
        } catch let failure as YtdlpCommand.Failure {
            #expect(failure.message == Messages.recipeRateLimit)
            if case .invalidRecipe(let issues) = failure { #expect(issues.map(\.field) == ["rateLimit"]) }
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func warningsComeWithThePlanAndDoNotStopIt() throws {
        var recipe = DownloadRecipe()
        recipe.cookieBrowser = .safari
        #expect(try plan(recipe).warnings.map(\.field) == ["cookieBrowser"])
        // A saved sign-in wins, so the browser is not read and nothing needs warning about.
        let withFile = try plan(recipe) { $0.cookiesFile = "/c/cookies.txt" }
        #expect(withFile.warnings.isEmpty)
        #expect(!withFile.arguments.contains("--cookies-from-browser"))
        #expect(value(after: "--cookies", in: withFile.arguments) == "/c/cookies.txt")
    }

    // MARK: Internal arguments

    @Test func theAppsBookkeepingIsInternalAndAbsentFromThePreview() throws {
        let command = try plan(PresetCatalog.audioOnly.recipe) {
            $0.workspace = "/w/job1"
            $0.outputListFile = "/w/job1/paths.txt"
            $0.chaptersFile = "/w/job1/chapters.json"
        }
        let internals = command.internalArguments
        #expect(internals.contains("--progress-template"))
        #expect(value(after: "--progress-template", in: internals) == YtdlpCommand.progressTemplate)
        #expect(values(after: "--print-to-file", in: internals) == ["after_move:%(.{filepath,chapters})j", "after_move:filepath"])
        // The chapter list is written first, so it is there when the finished file is noticed.
        #expect(!internals.contains("--load-info-json"))
        #expect(internals.contains("temp:/w/job1"))
        #expect(!command.displayCommand.contains("progress") && !command.displayCommand.contains("print-to-file"))
        #expect(!command.displayCommand.contains("temp:"))
        // The folder the user sees is still the destination.
        #expect(command.displayCommand.contains("/m/Site"))
    }

    @Test func withoutPlumbingOnlyTheProgressArgumentsAreInternal() throws {
        let internals = try plan().internalArguments
        #expect(internals == ["--newline", "--no-colors", "--progress", "--progress-template", YtdlpCommand.progressTemplate])
    }

    @Test func theProgressTemplateStartsWithItsPrefixAndEndsWithTheTitle() {
        #expect(YtdlpCommand.progressTemplate.hasPrefix("download:" + YtdlpCommand.progressPrefix))
        #expect(YtdlpCommand.progressTemplate.hasSuffix("%(info.title)s"))
    }

    // MARK: Phobos's checks

    @Test func oneVideoOnly() throws {
        var recipe = DownloadRecipe()
        recipe.playlistMode = .single
        #expect(try arguments(recipe).contains("--no-playlist"))
        #expect(!(try arguments()).contains("--no-playlist"))
    }

    @Test func theChosenVersionIsPassedOn() throws {
        let args = try arguments(PresetCatalog.upTo(height: 1080)!.recipe)
        #expect(value(after: "-S", in: args) == "res:1080")
    }

    @Test func bestAvailableAddsNoFormatOrSort() throws {
        let args = try arguments(PresetCatalog.best.recipe)
        #expect(!args.contains("-S") && !args.contains("-f") && !args.contains("--merge-output-format") && !args.contains("--remux-video"))
    }

    @Test func playsEverywhereIsH264AacInMp4() throws {
        let args = try arguments(PresetCatalog.playsEverywhere.recipe)
        let sort = try #require(value(after: "-S", in: args))
        #expect(sort.hasPrefix("vcodec:h264") && sort.contains("acodec:aac") && sort.contains("ext:mp4:m4a"))
        #expect(value(after: "--merge-output-format", in: args) == "mp4")
    }

    @Test func theClipIsRequested() throws {
        var recipe = DownloadRecipe()
        recipe.clip = Clip(start: 3, end: 8)
        let args = try arguments(recipe)
        #expect(value(after: "--download-sections", in: args) == "*0:03-0:08")
        #expect(args.contains("--force-keyframes-at-cuts"))
    }

    @Test func aFastClipLeavesOutTheExactCut() throws {
        var recipe = DownloadRecipe()
        recipe.clip = Clip(start: 165, end: 400)
        recipe.exactCut = false
        let args = try arguments(recipe)
        #expect(value(after: "--download-sections", in: args) == "*2:45-6:40")
        #expect(!args.contains("--force-keyframes-at-cuts"))
    }

    @Test func anOpenEndedClipRunsToTheEnd() throws {
        var recipe = DownloadRecipe()
        recipe.clip = Clip(start: 60)
        #expect(value(after: "--download-sections", in: try arguments(recipe)) == "*1:00-inf")
    }

    @Test func subtitlesAreEmbeddedProperOnesFirstWithNoLooseFiles() throws {
        let args = try arguments(DownloadRecipe().withSubtitles())
        #expect(args.contains("--write-subs") && args.contains("--write-auto-subs") && args.contains("--embed-subs"))
        #expect(value(after: "--compat-options", in: args) == "no-keep-subs")
        #expect(value(after: "--sub-langs", in: args) == "en")
        #expect(!args.contains("en.*"))
        #expect(value(after: "--sleep-subtitles", in: args) == "2")
    }

    @Test func subtitlesInAnotherLanguageAlsoAskForEnglish() throws {
        #expect(value(after: "--sub-langs", in: try arguments(DownloadRecipe().withSubtitles(language: "de"))) == "de,en")
    }

    @Test func subtitlesAreNotEmbeddedInAudio() throws {
        var recipe = PresetCatalog.audioOnly.recipe.withSubtitles()
        recipe.mode = .audio
        let args = try arguments(recipe)
        #expect(!args.contains("--embed-subs") && !args.contains("--compat-options"))
    }

    @Test func subtitlesKeepTheirFilesWhenAsked() throws {
        var recipe = DownloadRecipe()
        recipe.writeSubtitles = true
        recipe.subtitleFormat = .ass
        let args = try arguments(recipe)
        #expect(!args.contains("--compat-options"))
        #expect(value(after: "--sub-format", in: args) == "ass/best" && value(after: "--convert-subs", in: args) == "ass")
    }

    @Test func eachChapterIsSavedAsItsOwnFile() throws {
        var recipe = DownloadRecipe()
        recipe.splitChapters = true
        let args = try arguments(recipe)
        #expect(args.contains("--split-chapters"))
        #expect(values(after: "-o", in: args).contains { $0.hasPrefix("chapter:") })
    }

    @Test func speedLimitsReachTheTool() throws {
        var recipe = DownloadRecipe()
        recipe.rateLimit = "2M"
        #expect(value(after: "--limit-rate", in: try arguments(recipe)) == "2M")
        #expect(!(try arguments()).contains("--limit-rate"))
    }

    @Test func sponsorsAreCutExactlySoSoundStaysInStep() throws {
        let args = try arguments(DownloadRecipe().cuttingSponsors())
        #expect(value(after: "--sponsorblock-remove", in: args) == "sponsor")
        #expect(args.contains("--force-keyframes-at-cuts"))
        #expect(args.filter { $0 == "--force-keyframes-at-cuts" }.count == 1)
    }

    @Test func sponsorCutsOnAudioNeedNoKeyframes() throws {
        let args = try arguments(PresetCatalog.audioOnly.recipe.cuttingSponsors())
        #expect(args.contains("--sponsorblock-remove") && !args.contains("--force-keyframes-at-cuts"))
    }

    @Test func aClipPlusACutAsksForKeyframesOnce() throws {
        var recipe = DownloadRecipe().cuttingSponsors()
        recipe.clip = Clip(start: 3, end: 8)
        #expect(try arguments(recipe).filter { $0 == "--force-keyframes-at-cuts" }.count == 1)
    }

    @Test func aVideoPlaylistKeepsItsListNumbers() throws {
        let args = try arguments(PresetCatalog.upTo(height: 1080)!.recipe.forPlaylist())
        #expect(values(after: "-o", in: args).contains { $0.contains("%(playlist_index)03d") })
        #expect(args.contains("--yes-playlist") && args.contains("--ignore-errors"))
        #expect(value(after: "--sleep-interval", in: args) == "1" && value(after: "--max-sleep-interval", in: args) == "4")
    }

    @Test func anAudioPlaylistCarriesNoListNumber() throws {
        let args = try arguments(PresetCatalog.audioOnly.recipe.forPlaylist())
        #expect(!values(after: "-o", in: args).contains { $0.contains("%(playlist_index)03d") })
        #expect(values(after: "-o", in: args).contains { $0.contains("[%(id)s]") })
    }

    @Test func guidedNamesCarryTheVideosId() throws {
        #expect(value(after: "-o", in: try arguments()) == "%(title).150B [%(id)s].%(ext)s")
    }

    // MARK: Audio

    @Test func audioIsExtractedInTheChosenFormat() throws {
        let args = try arguments(PresetCatalog.audioOnly.recipe)
        #expect(value(after: "-f", in: args) == "ba/b")
        #expect(args.contains("-x") && value(after: "--audio-format", in: args) == "m4a")
        #expect(!args.contains("--audio-quality"))
        #expect(args.contains("--embed-thumbnail"))
    }

    @Test func lossyAudioTakesAQualityAndLosslessDoesNot() throws {
        var recipe = DownloadRecipe()
        recipe.mode = .audio
        recipe.audioFormat = .mp3
        recipe.audioQuality = .k320
        #expect(value(after: "--audio-quality", in: try arguments(recipe)) == "320K")
        recipe.audioFormat = .flac
        #expect(!(try arguments(recipe)).contains("--audio-quality"))
        recipe.audioFormat = .best
        #expect(!(try arguments(recipe)).contains("--audio-quality"))
    }

    @Test func aSourceThatAlreadyMatchesIsPreferred() throws {
        var recipe = DownloadRecipe()
        recipe.mode = .audio
        recipe.audioFormat = .opus
        #expect(value(after: "-S", in: try arguments(recipe)) == "acodec:opus")
        recipe.audioFormat = .mp3
        #expect(!(try arguments(recipe)).contains("-S"))
    }

    @Test func audioFiltersRideAlongInTheExtractStep() throws {
        var recipe = DownloadRecipe()
        recipe.mode = .audio
        recipe.gainDB = -3.5
        recipe.sampleRate = .r48000
        recipe.channels = .mono
        let args = try arguments(recipe)
        #expect(values(after: "--postprocessor-args", in: args).contains("ExtractAudio+ffmpeg_o:-af volume=-3.5dB -ar 48000 -ac 1"))
    }

    @Test func evenLoudnessIsAStageNotACommandArgument() throws {
        var recipe = PresetCatalog.audioOnly.recipe
        let before = try arguments(recipe)
        recipe.evenLoudness = true
        #expect(try arguments(recipe) == before)
    }

    @Test func aVolumeChangeIsLeftToTheLoudnessStepWhenThereIsOne() throws {
        var recipe = PresetCatalog.audioOnly.recipe
        recipe.audioFormat = .mp3
        recipe.gainDB = 4
        recipe.channels = .mono
        #expect(values(after: "--postprocessor-args", in: try arguments(recipe)).contains("ExtractAudio+ffmpeg_o:-af volume=4.0dB -ac 1"))
        // Evening out would undo the change, so that step applies it afterwards instead.
        recipe.evenLoudness = true
        #expect(values(after: "--postprocessor-args", in: try arguments(recipe)).contains("ExtractAudio+ffmpeg_o:-ac 1"))
        // A video is not evened out, so nothing changes there.
        recipe.mode = .video
        #expect(YtdlpCommand.audioFilterArguments(recipe) == ["-af", "volume=4.0dB", "-ac", "1"])
    }

    @Test func preparedDetailsAreLoadedByTheAppsBookkeepingAndThePreviewKeepsTheLink() throws {
        var recipe = DownloadRecipe()
        recipe.chapterSource = .comments
        let command = try plan(recipe) { $0.infoFile = "/w/job1/details.info.json" }
        #expect(Array(command.internalArguments.suffix(3)) == ["--no-clean-info-json", "--load-info-json", "/w/job1/details.info.json"])
        #expect(!command.displayCommand.contains("load-info-json"))
        #expect(command.visibleArguments.suffix(2).first == "--")
        #expect(command.notes == [Messages.commentChapters])
    }

    @Test func aGenreIsWrittenOnlyWhenMusicTagsAreOn() throws {
        var recipe = PresetCatalog.audioOnly.recipe
        recipe.genre = "Ambient"
        #expect(values(after: "--postprocessor-args", in: try arguments(recipe)).contains { $0.hasPrefix("Metadata+ffmpeg_o:") && $0.contains("genre=Ambient") })
        recipe.musicTags = false
        #expect(!values(after: "--postprocessor-args", in: try arguments(recipe)).contains { $0.contains("genre=") })
    }

    @Test func oggSplittingDropsThePictureWhileSplitting() throws {
        var recipe = PresetCatalog.audioOnly.recipe
        recipe.audioFormat = .opus
        recipe.splitChapters = true
        #expect(values(after: "--postprocessor-args", in: try arguments(recipe)).contains("SplitChapters+ffmpeg_o:-map -0:v?"))
        recipe.audioFormat = .mp3
        #expect(!values(after: "--postprocessor-args", in: try arguments(recipe)).contains { $0.hasPrefix("SplitChapters") })
    }

    @Test func squareCoversAreCroppedForMusicOnly() throws {
        let audio = try arguments(PresetCatalog.audioOnly.recipe)
        #expect(value(after: "--convert-thumbnails", in: audio) == "jpg>png/jpg")
        #expect(values(after: "--postprocessor-args", in: audio).contains { $0.hasPrefix("ThumbnailsConvertor+ffmpeg_o:") && $0.contains("min(iw,ih)") })
        var video = DownloadRecipe()
        video.container = .mp4
        video.embedThumbnail = true
        #expect(!(try arguments(video)).contains("--convert-thumbnails"))
    }

    @Test func videoCarriesNoMusicTagsAndNoCoverUnlessAsked() throws {
        let args = try arguments(PresetCatalog.upTo(height: 1080)!.recipe)
        #expect(!args.contains("--embed-thumbnail"))
        #expect(!args.contains { $0.contains("meta_artist") })
        #expect(args.contains("--embed-metadata"))
    }

    // MARK: Containers (Studio's verified rules)

    @Test func eachContainerGetsARemuxRuleThatNeverAsksForAnImpossibleCopy() throws {
        func remux(_ container: VideoContainer) throws -> String? {
            var recipe = DownloadRecipe()
            recipe.container = container
            return value(after: "--remux-video", in: try arguments(recipe))
        }
        #expect(try remux(.mp4) == "mp4")
        #expect(try remux(.mkv) == "mkv")
        #expect(try remux(.webm) == "mp4>mkv/mkv>mkv/webm")
        #expect(try remux(.mov) == "webm>mp4/mov")
        #expect(try remux(.automatic) == nil)
    }

    @Test func coverArtOnAnAutomaticContainerRepackagesAsMkv() throws {
        var recipe = DownloadRecipe()
        recipe.embedThumbnail = true
        let args = try arguments(recipe)
        #expect(value(after: "--remux-video", in: args) == "mkv" && args.contains("--embed-thumbnail"))
        recipe.container = .webm
        let webm = try arguments(recipe)
        #expect(!webm.contains("--embed-thumbnail"))
    }

    @Test func videoOnlyFallsBackToTheCombinedStream() throws {
        var recipe = DownloadRecipe()
        recipe.mode = .videoOnly
        recipe.audioCodec = .aac
        let args = try arguments(recipe)
        #expect(value(after: "-f", in: args) == "bv/bv*")
        #expect(!args.contains("--merge-output-format"))
        #expect(!(value(after: "-S", in: args) ?? "").contains("acodec"))
    }

    @Test func yourOwnFormatAndSortWin() throws {
        var recipe = DownloadRecipe()
        recipe.customFormat = " b "
        recipe.customSort = "res,+size"
        recipe.maxResolution = .p480
        let args = try arguments(recipe)
        #expect(value(after: "-f", in: args) == "b" && value(after: "-S", in: args) == "res,+size")
    }

    @Test func theSortPutsResolutionFrameRateAndCodecsInOrder() throws {
        var recipe = DownloadRecipe()
        recipe.container = .mp4
        recipe.maxResolution = .p1440
        recipe.frameRateLimit = .fps30
        recipe.videoCodec = .av1
        recipe.audioCodec = .opus
        #expect(value(after: "-S", in: try arguments(recipe)) == "res:1440,fps:30,vcodec:av01,acodec:opus,ext:mp4:m4a")
        recipe.preferCompatibleStreams = false
        #expect(value(after: "-S", in: try arguments(recipe)) == "res:1440,fps:30,vcodec:av01,acodec:opus")
    }

    // MARK: Network, naming, playlist

    @Test func defaultsAreNotRepeatedButChangesAre() throws {
        let defaults = try arguments()
        #expect(value(after: "-N", in: defaults) == "4" && !defaults.contains("-R"))
        var recipe = DownloadRecipe()
        recipe.concurrentFragments = 1
        recipe.retries = 3
        recipe.proxy = " socks5://127.0.0.1:1080 "
        let args = try arguments(recipe)
        #expect(!args.contains("-N") && value(after: "-R", in: args) == "3" && value(after: "--proxy", in: args) == "socks5://127.0.0.1:1080")
    }

    @Test func aProxyIsAnOptionBecauseTheEnvironmentCarriesNone() throws {
        #expect(!toolchain.environment.keys.contains { $0.lowercased().contains("proxy") })
        var recipe = DownloadRecipe()
        recipe.proxy = "http://proxy.example:3128"
        #expect(value(after: "--proxy", in: try arguments(recipe)) == "http://proxy.example:3128")
    }

    @Test func theDestinationAndNamingFlags() throws {
        let args = try arguments(DownloadRecipe(), links: [link])
        #expect(value(after: "-P", in: args) == "/m/Site")
        #expect(args.contains("--no-overwrites") && args.contains("--no-mtime") && !args.contains("--restrict-filenames"))
        var recipe = DownloadRecipe()
        recipe.noOverwrites = false
        recipe.restrictFilenames = true
        let changed = try arguments(recipe)
        #expect(!changed.contains("--no-overwrites") && changed.contains("--restrict-filenames"))
    }

    @Test func aCustomTemplateIsUsedAsTyped() throws {
        var recipe = DownloadRecipe()
        recipe.filenameTemplate = .custom
        recipe.customTemplate = "  %(uploader)s - %(title)s.%(ext)s "
        #expect(value(after: "-o", in: try arguments(recipe)) == "%(uploader)s - %(title)s.%(ext)s")
    }

    @Test func everyReadyMadeNameEndsInAnExtension() {
        for template in FilenameTemplate.allCases where template != .custom {
            #expect(template.template.hasSuffix(".%(ext)s"), "\(template)")
        }
    }

    @Test func theArchiveIsTheJobsFile() throws {
        var recipe = DownloadRecipe()
        recipe.useArchive = true
        #expect(throws: YtdlpCommand.Failure.archiveNeeded) { try arguments(recipe) }
        let args = try plan(recipe) { $0.archiveFile = "/m/archive.txt" }.arguments
        #expect(value(after: "--download-archive", in: args) == "/m/archive.txt")
        #expect(YtdlpCommand.Failure.archiveNeeded.message == Messages.recipeArchiveNeeded)
        // The archive is not mentioned when the recipe does not ask for it.
        #expect(!(try plan(DownloadRecipe()) { $0.archiveFile = "/m/archive.txt" }.arguments).contains("--download-archive"))
    }

    @Test func playlistItemsAreTrimmedAndPassedOn() throws {
        var recipe = DownloadRecipe()
        recipe.playlistItems = " 1-5,8 "
        #expect(value(after: "-I", in: try arguments(recipe)) == "1-5,8")
    }

    @Test func extraArgumentsComeBeforeTheLinksAndAreChecked() throws {
        var recipe = DownloadRecipe()
        recipe.extraArguments = "--match-filter \"duration < 3600\" --geo-bypass"
        let args = try arguments(recipe)
        let dashes = try #require(args.firstIndex(of: "--"))
        #expect(Array(args[(dashes - 3)..<dashes]) == ["--match-filter", "duration < 3600", "--geo-bypass"])
        recipe.extraArguments = "--exec 'touch /tmp/x'"
        #expect(throws: YtdlpCommand.Failure.self) { try arguments(recipe) }
    }

    @Test func linksCannotBeSmuggledInThroughTheExtraArguments() {
        var recipe = DownloadRecipe()
        recipe.extraArguments = "-- https://evil.example/x"
        #expect(throws: YtdlpCommand.Failure.self) { try arguments(recipe) }
    }

    @Test func commentChaptersLeaveANoteInsteadOfPretending() throws {
        var recipe = DownloadRecipe()
        #expect(try plan(recipe).notes.isEmpty)
        recipe.chapterSource = .commentsIfMissing
        #expect(try plan(recipe).notes == [Messages.commentChapters])
    }

    // MARK: Display

    @Test func shellQuotingProtectsWhatAShellWouldChange() {
        #expect(DisplayCommand.shellQuote("plain-arg") == "plain-arg")
        #expect(DisplayCommand.shellQuote("it's %(title)s") == #"'it'\''s %(title)s'"#)
        #expect(DisplayCommand.shellQuote("") == "''")
        #expect(DisplayCommand.shellQuote("a b") == "'a b'")
        #expect(DisplayCommand.shellQuote("$(rm -rf ~)") == "'$(rm -rf ~)'")
        #expect(DisplayCommand.shellQuote("https://example.com/watch?v=abc") == "'https://example.com/watch?v=abc'")
    }

    @Test func theDisplayedCommandNamesTheProgramNotItsPath() throws {
        let display = try plan().displayCommand
        #expect(display.hasPrefix("yt-dlp --ignore-config "))
        #expect(!display.contains("/t/yt-dlp"))
    }
}
