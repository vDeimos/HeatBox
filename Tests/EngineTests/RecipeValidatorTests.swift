import Foundation
import Testing
@testable import Engine

private func errors(_ edit: (inout DownloadRecipe) -> Void) -> [RecipeIssue] {
    var recipe = DownloadRecipe()
    edit(&recipe)
    return RecipeValidator.errors(in: recipe)
}

private func warnings(_ edit: (inout DownloadRecipe) -> Void) -> [RecipeIssue] {
    var recipe = DownloadRecipe()
    edit(&recipe)
    return RecipeValidator.validate(recipe).filter { $0.severity == .warning }
}

@Suite struct RecipeValidatorTests {
    @Test func theDefaultRecipeIsValid() {
        #expect(RecipeValidator.validate(DownloadRecipe()).isEmpty)
    }

    @Test func anEncoderMustFitTheContainer() {
        let issues = errors { $0.encodeEnabled = true; $0.encoder = .vp9; $0.container = .mov }
        #expect(issues.map(\.field) == ["container"])
        #expect(issues[0].message.contains("libvpx-vp9") && issues[0].message.contains("WEBM"))
        #expect(errors { $0.encodeEnabled = true; $0.encoder = .x264; $0.container = .mp4 }.isEmpty)
        #expect(errors { $0.encodeEnabled = true; $0.encoder = .prores; $0.container = .mov }.isEmpty)
        #expect(!errors { $0.encodeEnabled = true; $0.encoder = .prores; $0.container = .mp4 }.isEmpty)
    }

    @Test func everyEncoderHasAContainerThatCanHoldIt() {
        for encoder in VideoEncoder.allCases {
            #expect(!encoder.compatibleContainers.isEmpty, "\(encoder)")
            #expect(!encoder.compatibleContainers.contains(.automatic), "\(encoder)")
        }
    }

    @Test func reEncodingNeedsAChosenContainer() {
        let issues = errors { $0.encodeEnabled = true }
        #expect(issues.map(\.field) == ["container"])
        #expect(issues[0].message.contains("Customize"))
    }

    @Test func reEncodingAnAudioDownloadIsOnlyAWarning() {
        #expect(errors { $0.mode = .audio; $0.encodeEnabled = true }.isEmpty)
        #expect(warnings { $0.mode = .audio; $0.encodeEnabled = true }.map(\.field) == ["encodeEnabled"])
    }

    @Test func qualityFactorsStayInTheEncodersRange() {
        #expect(!errors { $0.encodeEnabled = true; $0.container = .mp4; $0.encoder = .x264; $0.qualityFactor = 52 }.isEmpty)
        #expect(errors { $0.encodeEnabled = true; $0.container = .mkv; $0.encoder = .av1; $0.qualityFactor = 52 }.isEmpty)
        #expect(!errors { $0.encodeEnabled = true; $0.container = .mp4; $0.encoder = .videoToolboxHEVC; $0.hardwareBitrateMbps = 0 }.isEmpty)
    }

    @Test func numbersStayInRange() {
        #expect(!errors { $0.concurrentFragments = 0 }.isEmpty)
        #expect(!errors { $0.concurrentFragments = 99 }.isEmpty)
        #expect(!errors { $0.retries = -1 }.isEmpty)
        #expect(!errors { $0.gainDB = 80 }.isEmpty)
        #expect(!errors { $0.gainDB = .nan }.isEmpty)
        #expect(!errors { $0.sleepInterval = -1 }.isEmpty)
        #expect(errors { $0.sleepInterval = 2; $0.maxSleepInterval = 6 }.isEmpty)
    }

    @Test func aLongestPauseNeedsAShortestPauseBelowIt() {
        #expect(!errors { $0.sleepInterval = 5; $0.maxSleepInterval = 2 }.isEmpty)
        #expect(errors { $0.maxSleepInterval = 4 }.map(\.field) == ["maxSleepInterval"])
        #expect(errors { $0.sleepInterval = 1; $0.maxSleepInterval = 4 }.isEmpty)
    }

    @Test func clipsMustRunForwards() {
        #expect(errors { $0.clip = Clip(start: 165, end: 400) }.isEmpty)
        #expect(errors { $0.clip = Clip(start: 165) }.isEmpty)
        #expect(!errors { $0.clip = Clip(start: 50, end: 10) }.isEmpty)
        #expect(!errors { $0.clip = Clip(start: 10, end: 10) }.isEmpty)
        #expect(!errors { $0.clip = Clip(start: -1, end: 10) }.isEmpty)
        #expect(!errors { $0.clip = Clip(start: .infinity) }.isEmpty)
    }

    @Test func aClipCannotBeSplitIntoChapters() {
        let issues = errors { $0.clip = Clip(start: 1, end: 5); $0.splitChapters = true }
        #expect(issues.map(\.field) == ["splitChapters"])
    }

    @Test func playlistItemsUseTheToolsSyntax() {
        for good in ["1", "1-5", "1-5,8", "3:10", "::2", "2:10:2", "-3", "1, 3, 7-9", "5:"] {
            #expect(errors { $0.playlistItems = good }.isEmpty, "\(good)")
        }
        for bad in ["abc", "1,,2", "1-", "--exec", "1;2", ",1"] {
            #expect(!errors { $0.playlistItems = bad }.isEmpty, "\(bad)")
        }
    }

    @Test func speedLimitsLookLikeTheToolsOwn() {
        for good in ["500K", "2M", "1.5M", "100", "2g"] { #expect(errors { $0.rateLimit = good }.isEmpty, "\(good)") }
        for bad in ["fast", "5 MB", "-1", "M", "1e6"] { #expect(!errors { $0.rateLimit = bad }.isEmpty, "\(bad)") }
    }

    @Test func proxiesNeedAKnownScheme() {
        for good in ["http://127.0.0.1:8080", "https://proxy.example:3128", "socks5://localhost:1080", "SOCKS5H://h:1", "socks4a://h:2"] {
            #expect(errors { $0.proxy = good }.isEmpty, "\(good)")
        }
        for bad in ["127.0.0.1:8080", "ftp://x", "http://", "file:///etc/passwd"] {
            #expect(!errors { $0.proxy = bad }.isEmpty, "\(bad)")
        }
    }

    @Test func sponsorBlockNeedsCategoriesThatCanBeCut() {
        #expect(!errors { $0.sponsorBlock = .mark; $0.sponsorCategories = [] }.isEmpty)
        #expect(!errors { $0.sponsorBlock = .remove; $0.sponsorCategories = [.poiHighlight, .chapter] }.isEmpty)
        #expect(errors { $0.sponsorBlock = .mark; $0.sponsorCategories = [.poiHighlight] }.isEmpty)
        #expect(errors { $0.sponsorBlock = .off; $0.sponsorCategories = [] }.isEmpty)
    }

    @Test func subtitlesNeedALanguage() {
        #expect(!errors { $0.writeSubtitles = true; $0.subtitleLanguages = "  " }.isEmpty)
        #expect(errors { $0.subtitleLanguages = "" }.isEmpty)
    }

    @Test func subtitlesWarnWhereTheyCannotBeEmbedded() {
        #expect(warnings { $0.embedSubtitles = true; $0.container = .mov }.map(\.field) == ["embedSubtitles"])
        #expect(warnings { $0.embedSubtitles = true; $0.container = .mkv }.isEmpty)
    }

    @Test func coverArtWarnsWhereItCannotBeEmbedded() {
        #expect(warnings { $0.embedThumbnail = true; $0.container = .webm }.map(\.field) == ["embedThumbnail"])
        #expect(warnings { $0.embedThumbnail = true; $0.mode = .audio; $0.audioFormat = .wav }.map(\.field) == ["embedThumbnail"])
        #expect(warnings { $0.embedThumbnail = true; $0.mode = .audio; $0.audioFormat = .m4a }.isEmpty)
        // With the container left to the tool, a video is repackaged as MKV so the picture fits.
        #expect(warnings { $0.embedThumbnail = true }.isEmpty)
    }

    @Test func audioFiltersWarnWhenTheOriginalCodecIsKept() {
        #expect(warnings { $0.mode = .audio; $0.audioFormat = .best; $0.channels = .mono }.map(\.field) == ["audioFormat"])
        #expect(warnings { $0.mode = .audio; $0.audioFormat = .mp3; $0.channels = .mono }.isEmpty)
        // With the volume evened out the sound is written again, and the changes are made then.
        #expect(warnings { $0.mode = .audio; $0.audioFormat = .best; $0.channels = .mono; $0.evenLoudness = true }.isEmpty)
    }

    @Test func eveningOutTheVolumeOfAVideoIsOnlyAWarning() {
        #expect(warnings { $0.evenLoudness = true }.map(\.field) == ["evenLoudness"])
        #expect(errors { $0.evenLoudness = true }.isEmpty)
        #expect(warnings { $0.mode = .audio; $0.evenLoudness = true }.isEmpty)
    }

    @Test func aBrowserSignInIsAllowedWithAWarning() {
        #expect(errors { $0.cookieBrowser = .chrome }.isEmpty)
        #expect(warnings { $0.cookieBrowser = .chrome }.map(\.field) == ["cookieBrowser"])
    }

    @Test func customNamesNeedAnExtension() {
        #expect(!errors { $0.filenameTemplate = .custom; $0.customTemplate = "%(title)s" }.isEmpty)
        #expect(!errors { $0.filenameTemplate = .custom; $0.customTemplate = "  " }.isEmpty)
        #expect(errors { $0.filenameTemplate = .custom; $0.customTemplate = "%(title)s.%(ext)s" }.isEmpty)
        // A template that is not in use is not checked.
        #expect(errors { $0.customTemplate = "" }.isEmpty)
    }

    @Test func refusedExtraArgumentsAreErrorsWithAnExplanation() {
        let issues = errors { $0.extraArguments = "--exec 'rm x'" }
        #expect(issues.map(\.field) == ["extraArguments"])
        #expect(issues[0].message.contains("--exec") && issues[0].message.contains("Remove it"))
        #expect(!errors { $0.extraArguments = "--geo-bypass \"unclosed" }.isEmpty)
    }

    @Test func everyIssueIsOnePlainSentence() {
        var recipe = DownloadRecipe()
        recipe.encodeEnabled = true
        recipe.clip = Clip(start: 9, end: 1)
        recipe.rateLimit = "x"
        recipe.proxy = "x"
        recipe.playlistItems = "x"
        recipe.cookieBrowser = .safari
        recipe.extraArguments = "--exec x"
        for issue in RecipeValidator.validate(recipe) {
            #expect(issue.message.hasSuffix("."), "\(issue.message)")
            #expect(!issue.message.contains("\n"))
        }
    }
}
