import Foundation
import Testing
@testable import Engine

@Suite struct RecipeTests {
    @Test func defaultsArePhobosDefaults() {
        let recipe = DownloadRecipe()
        #expect(recipe.mode == .video)
        #expect(recipe.container == .automatic)
        #expect(recipe.embedThumbnail == false)
        #expect(recipe.filenameTemplate == .guided)
        #expect(recipe.exactCut)
        #expect(recipe.splitOnlyMusic)
        #expect(!recipe.trackNumbersFromPlaylist && !recipe.albumFallback)
        #expect(recipe.clip == nil)
    }

    @Test func studioDefaultsAreStudiosBaseline() {
        let recipe = DownloadRecipe.studioDefaults
        #expect(recipe.container == .mp4)
        #expect(recipe.embedThumbnail)
        #expect(recipe.filenameTemplate == .titleOnly)
        #expect(recipe.albumFallback && recipe.trackNumbersFromPlaylist && !recipe.splitOnlyMusic)
    }

    @Test func aRecipeSurvivesBeingSavedAndRead() throws {
        var recipe = DownloadRecipe()
        recipe.mode = .audio
        recipe.audioFormat = .opus
        recipe.clip = Clip(start: 3.5, end: 9)
        recipe.sponsorCategories = [.sponsor, .outro]
        recipe.gainDB = -2.5
        let data = try JSONEncoder().encode(recipe)
        #expect(try JSONDecoder().decode(DownloadRecipe.self, from: data) == recipe)
        #expect(DownloadRecipe.lenient(from: data) == recipe)
    }

    @Test func aRecipeSavedByAnOlderVersionKeepsNewDefaults() throws {
        let saved = Data(#"{"mode":"audio","audioFormat":"flac"}"#.utf8)
        let recipe = try #require(DownloadRecipe.lenient(from: saved))
        #expect(recipe.mode == .audio)
        #expect(recipe.audioFormat == .flac)
        #expect(recipe.concurrentFragments == 4)
        #expect(recipe.exactCut)
    }

    @Test func unknownFieldsAreIgnored() throws {
        let saved = Data(#"{"mode":"audio","aFieldFromTheFuture":[1,2,3]}"#.utf8)
        #expect(try #require(DownloadRecipe.lenient(from: saved)).mode == .audio)
    }

    @Test func aValueThatNoLongerFitsDoesNotResetTheRest() throws {
        // "avi" was a Studio container and is not one here.
        let saved = Data(#"{"container":"avi","mode":"audio","retries":3,"clip":{"start":1,"end":2}}"#.utf8)
        let recipe = try #require(DownloadRecipe.lenient(from: saved))
        #expect(recipe.container == .automatic)
        #expect(recipe.mode == .audio)
        #expect(recipe.retries == 3)
        #expect(recipe.clip == Clip(start: 1, end: 2))
    }

    @Test func overlayingFieldsKeepsTheRest() {
        let base = PresetCatalog.audioOnly.recipe
        let changed = base.overlaid(with: ["audioFormat": "mp3", "clip": ["start": 4.0]])
        #expect(changed.audioFormat == .mp3)
        #expect(changed.clip == Clip(start: 4))
        #expect(changed.mode == .audio && changed.embedThumbnail)
    }

    @Test func derivedFlagsFollowTheSettings() {
        var recipe = DownloadRecipe()
        #expect(!recipe.forcesKeyframes)
        recipe.clip = Clip(start: 1, end: 5)
        #expect(recipe.forcesKeyframes)
        recipe.exactCut = false
        #expect(!recipe.forcesKeyframes)
        recipe.exactCut = true
        recipe.clip = nil
        recipe.sponsorBlock = .remove
        #expect(recipe.cutsVideoSegments && recipe.forcesKeyframes)
        recipe.mode = .audio
        #expect(!recipe.cutsVideoSegments && !recipe.forcesKeyframes)
        #expect(recipe.musicTagsActive)
        recipe.embedMetadata = false
        #expect(!recipe.musicTagsActive)
    }

    @Test func chapterFilesAreRetaggedOnlyForSplitMusic() {
        var recipe = PresetCatalog.audioOnly.recipe
        #expect(!recipe.retagsChapters)
        recipe.splitChapters = true
        #expect(recipe.retagsChapters)
        recipe.mode = .video
        #expect(!recipe.retagsChapters)
    }

    @Test func playlistHelperAddsWhatPhobosAdds() {
        let recipe = PresetCatalog.best.recipe.forPlaylist()
        #expect(recipe.playlistMode == .full && recipe.continueOnErrors)
        #expect(recipe.sleepInterval == 1 && recipe.maxSleepInterval == 4)
    }

    @Test func aPlaylistKeepsAPauseTheRecipeNamesItself() {
        var own = PresetCatalog.best.recipe
        own.sleepInterval = 10
        own.maxSleepInterval = 30
        let recipe = own.forPlaylist()
        #expect(recipe.sleepInterval == 10 && recipe.maxSleepInterval == 30)
        #expect(recipe.playlistMode == .full && recipe.continueOnErrors)
    }

    @Test func subtitleHelperAsksForTheMainLanguagePlusEnglish() {
        #expect(DownloadRecipe().withSubtitles().subtitleLanguages == "en")
        let german = DownloadRecipe().withSubtitles(language: "de")
        #expect(german.subtitleLanguages == "de,en")
        #expect(german.embedSubtitles && !german.keepSubtitleFiles && german.subtitleSleep == 2)
    }

    @Test func sponsorHelperCutsOnlySponsors() {
        let recipe = DownloadRecipe().cuttingSponsors()
        #expect(recipe.sponsorBlock == .remove && recipe.sponsorCategories == [.sponsor] && recipe.exactCut)
    }

    @Test func timesAreWrittenTheWayPhobosWritesThem() {
        #expect(TimeText.clock(165) == "2:45")
        #expect(TimeText.clock(3725) == "1:02:05")
        #expect(TimeText.clock(0) == "0:00")
        #expect(TimeText.clock(165.5) == "2:45.5")
        #expect(TimeText.clock(3.25) == "0:03.25")
    }

    @Test func timesAreReadFromTextOrRefused() {
        #expect(TimeText.seconds(from: "2:45") == 165)
        #expect(TimeText.seconds(from: "1:02:05") == 3725)
        #expect(TimeText.seconds(from: "90") == 90)
        #expect(TimeText.seconds(from: " 1:30.5 ") == 90.5)
        #expect(TimeText.seconds(from: "abc") == nil)
        #expect(TimeText.seconds(from: "1:2:3:4") == nil)
        #expect(TimeText.seconds(from: "-5") == nil)
    }
}

@Suite struct PresetTests {
    @Test func guidedPresetsAreThePhobosChoices() {
        #expect(PresetCatalog.guided.map(\.id) == ["best", "compatible", "res2160", "res1440", "res1080", "res720", "res480", "res360", "audio"])
        #expect(PresetCatalog.guided.allSatisfy { $0.group == .guided && $0.isBuiltIn })
    }

    @Test func theAdvancedGroupIsStudiosNine() {
        #expect(PresetCatalog.advanced.count == 9)
        #expect(PresetCatalog.advanced.allSatisfy { $0.group == .advanced && $0.id.hasPrefix("studio.") })
    }

    @Test func idsAreUniqueAndFindable() {
        let ids = PresetCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for preset in PresetCatalog.all { #expect(PresetCatalog.preset(id: preset.id) == preset) }
        #expect(PresetCatalog.preset(id: "nope") == nil)
    }

    @Test func everyBuiltInPresetIsValidAndRunnable() {
        for preset in PresetCatalog.all {
            #expect(RecipeValidator.errors(in: preset.recipe).isEmpty, "\(preset.id)")
        }
    }

    @Test func resolutionPresetsOnlyExistForKnownTiers() {
        #expect(PresetCatalog.upTo(height: 1080)?.recipe.maxResolution == .p1080)
        #expect(PresetCatalog.upTo(height: 1000) == nil)
        #expect(PresetCatalog.resolutionID(720) == "res720")
    }

    @Test func aPresetRoundTripsThroughJSON() throws {
        let preset = Preset(name: "My music", recipe: PresetCatalog.audioOnly.recipe)
        #expect(!preset.isBuiltIn)
        let data = try JSONEncoder().encode(preset)
        #expect(try JSONDecoder().decode(Preset.self, from: data) == preset)
    }

    @Test func aPresetFromAnotherVersionKeepsWhatStillFits() throws {
        let saved = Data(#"{"id":"u1","name":"Old","group":"nonsense","recipe":{"container":"flv","mode":"audio","retries":2}}"#.utf8)
        let preset = try JSONDecoder().decode(Preset.self, from: saved)
        #expect(preset.group == .user)
        #expect(preset.recipe.mode == .audio && preset.recipe.retries == 2 && preset.recipe.container == .automatic)
    }

    @Test func aPresetWithoutARecipeIsRefused() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(Preset.self, from: Data(#"{"id":"u","name":"x","recipe":[]}"#.utf8))
        }
    }

    @Test func importedPresetsStillGoThroughTheValidator() throws {
        // A shared preset that tries to run a program is not runnable (plan Phase 8 relies on this).
        let saved = Data(#"{"id":"u","name":"Evil","recipe":{"extraArguments":"--exec 'touch /tmp/x'"}}"#.utf8)
        let preset = try JSONDecoder().decode(Preset.self, from: saved)
        #expect(!RecipeValidator.errors(in: preset.recipe).isEmpty)
    }
}
