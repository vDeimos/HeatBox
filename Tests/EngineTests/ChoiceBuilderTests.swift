import Foundation
import Testing
@testable import Engine

private func video(_ id: String, _ width: Int, _ height: Int, codec: String? = "vp09.00.40.08", audio: Bool = false, bytes: Int64? = nil) -> MediaFormat {
    MediaFormat(id: id, ext: "mp4", width: width, height: height, videoCodec: codec, audioCodec: audio ? "mp4a.40.2" : nil,
                hasVideo: true, hasAudio: audio, bytes: bytes)
}

private func audio(_ id: String, bytes: Int64? = nil) -> MediaFormat {
    MediaFormat(id: id, ext: "m4a", audioCodec: "mp4a.40.2", hasVideo: false, hasAudio: true, bytes: bytes)
}

private let toolchain = YtdlpCommand.Toolchain(ytdlp: "/tools/yt-dlp", environment: [:])

@Suite struct ChoiceBuilderTests {
    @Test func resolutionsAreSortedIntoTiers() {
        #expect(ChoiceBuilder.bucket(2160) == 2160)
        #expect(ChoiceBuilder.bucket(4320) == 2160, "anything larger than 4K counts as the top tier")
        #expect(ChoiceBuilder.bucket(1080) == 1080)
        #expect(ChoiceBuilder.bucket(1072) == 1080, "a little under a tier still counts as that tier")
        #expect(ChoiceBuilder.bucket(972) == 1080)
        #expect(ChoiceBuilder.bucket(971) == 720)
        #expect(ChoiceBuilder.bucket(804) == 720)
        #expect(ChoiceBuilder.bucket(360) == 360)
        #expect(ChoiceBuilder.bucket(100) == 144)
    }

    @Test func sizesAreSaidPlainly() {
        #expect(ChoiceBuilder.sizeText(nil) == "size unknown")
        #expect(ChoiceBuilder.sizeText(0) == "size unknown")
        #expect(ChoiceBuilder.sizeText(312_000_000) == "about 312 MB")
        #expect(ChoiceBuilder.sizeText(1_912_000_000) == "about 1.91 GB")
    }

    @Test func theUsualYouTubeVideoGetsPhobossChoices() {
        let formats = [audio("140", bytes: 12_000_000),
                       video("137", 1920, 1080, codec: "avc1.640028", bytes: 300_000_000),
                       video("313", 3840, 2160, bytes: 1_900_000_000)]
        let choices = ChoiceBuilder.choices(from: formats)
        #expect(choices.map(\.id) == ["best", "compatible", "res1080", "audio"])
        #expect(choices.map(\.title) == ["Best available", "Plays everywhere", "1080p", "Audio only"])
        #expect(choices.map(\.badge) == ["2160p", "MP4 · up to 1080p", "smaller than best", "M4A"])
        // A video stream is joined with the audio stream, so its size includes it.
        #expect(choices.map(\.bytes) == [1_912_000_000, 312_000_000, 312_000_000, 12_000_000])
        #expect(choices.map(\.size) == ["about 1.91 GB", "about 312 MB", "about 312 MB", "about 12 MB"])
        #expect(choices[2].explanation == Messages.choiceTierNotes[1080])
        #expect(choices.map(\.audioOnly) == [false, false, false, true])
    }

    @Test func everyChoiceIsABuiltInPreset() throws {
        let formats = [audio("a"), video("v1", 640, 360), video("v2", 854, 480), video("v3", 1280, 720, codec: "avc1.4d401f"),
                       video("v4", 1920, 1080), video("v5", 2560, 1440), video("v6", 3840, 2160)]
        let choices = ChoiceBuilder.choices(from: formats)
        #expect(choices.map(\.id) == ["best", "compatible", "res1440", "res1080", "res720", "res480", "res360", "audio"])
        for choice in choices + ChoiceBuilder.generic {
            let preset = try #require(PresetCatalog.preset(id: choice.id), "\(choice.id) is not in the catalog")
            #expect(choice.preset == preset)
            #expect(choice.recipe == preset.recipe)
            #expect(preset.group == .guided)
            #expect(RecipeValidator.validate(choice.recipe).filter { $0.severity == .error }.isEmpty)
            // And the choice turns into a command without further work.
            _ = try YtdlpCommand.plan(.init(recipe: choice.recipe, links: ["https://example.com/v"], folder: "/out"), toolchain: toolchain)
        }
    }

    @Test func aChoiceAsksTheToolForWhatItSays() throws {
        let choices = ChoiceBuilder.choices(from: [audio("a"), video("v1", 1280, 720, codec: "avc1"), video("v2", 1920, 1080)])
        func arguments(_ id: String) throws -> [String] {
            let choice = try #require(choices.first { $0.id == id })
            return try YtdlpCommand.plan(.init(recipe: choice.recipe, links: ["https://example.com/v"], folder: "/out"), toolchain: toolchain).visibleArguments
        }
        #expect(try arguments("res720").contains("res:720"))
        #expect(try arguments("compatible").contains("mp4"))
        let audioArguments = try arguments("audio")
        #expect(audioArguments.contains("-x") && audioArguments.contains("m4a"))
    }

    @Test func theTopTierIsBestAndSmallTiersAreNotOffered() {
        let choices = ChoiceBuilder.choices(from: [video("a", 256, 144), video("b", 426, 240), video("c", 640, 360), video("d", 1280, 720)])
        #expect(choices.map(\.id) == ["best", "res360"], "720p is the best; 240p and 144p are not worth a choice; no sound, so no audio")
        #expect(choices[0].badge == "720p")
    }

    @Test func anUprightVideoIsNamedByItsShortSide() {
        let choices = ChoiceBuilder.choices(from: [video("a", 1080, 1920, codec: "avc1", audio: true), video("b", 720, 1280, codec: "avc1", audio: true)])
        #expect(choices.map(\.id) == ["best", "compatible", "res720", "audio"])
        #expect(choices[0].badge == "1080p")
        #expect(choices[1].badge == "MP4 · up to 1080p")
    }

    @Test func aStreamWithItsOwnSoundIsNotCountedTwice() {
        let choices = ChoiceBuilder.choices(from: [audio("a", bytes: 5_000_000), video("b", 1280, 720, codec: "avc1", audio: true, bytes: 50_000_000)])
        #expect(choices.first?.bytes == 50_000_000)
    }

    @Test func theLargestVersionInATierGivesItsSize() {
        let choices = ChoiceBuilder.choices(from: [video("a", 1920, 1080, bytes: 100), video("b", 1920, 1080, bytes: 900),
                                                   video("c", 1920, 1080, codec: "avc1", bytes: 400), video("d", 1920, 1080, codec: "avc1", bytes: 300)])
        #expect(choices.first { $0.id == "best" }?.bytes == 900)
        #expect(choices.first { $0.id == "compatible" }?.bytes == 400)
    }

    @Test func aSiteWithOneVersionOffersTheOriginalFile() {
        // A direct link to a file: nothing is known about the picture or the sound.
        let unknown = MediaFormat(id: "mp4", ext: "mp4", hasVideo: false, hasAudio: false)
        let choices = ChoiceBuilder.choices(from: [unknown])
        #expect(choices.map(\.id) == ["best"])
        #expect(choices[0].title == "Original file")
        #expect(choices[0].badge == "as offered")
        #expect(choices[0].size == "size unknown")
        #expect(ChoiceBuilder.choices(from: []).map(\.title) == ["Original file"])
    }

    @Test func anAudioOnlySiteOffersTheOriginalAndAudio() {
        let choices = ChoiceBuilder.choices(from: [audio("mp3", bytes: 3_400_000), audio("aac", bytes: 4_300_000)])
        #expect(choices.map(\.id) == ["best", "audio"])
        #expect(choices.map(\.title) == ["Original file", "Audio only"])
        #expect(choices[1].size == "about 4.3 MB")
    }

    @Test func choicesForAnyVideoAreTheSameSixPhobosOffers() {
        let generic = ChoiceBuilder.generic
        #expect(generic.map(\.id) == ["best", "compatible", "res1080", "res720", "res480", "audio"])
        #expect(generic.map(\.title) == ["Best available", "Plays everywhere", "Up to 1080p", "Up to 720p", "Up to 480p", "Audio only"])
        #expect(generic.map(\.badge) == ["highest each video has", "MP4", "Full HD", "HD", "small", "M4A"])
        #expect(generic.allSatisfy { $0.size == "varies" && $0.bytes == nil })
        #expect(generic.allSatisfy { !$0.explanation.isEmpty })
    }

    @Test func aChoiceSurvivesBeingSaved() throws {
        let choice = try #require(ChoiceBuilder.choices(from: [audio("a", bytes: 1_000_000), video("v", 1920, 1080, bytes: 9_000_000)]).first)
        let restored = try JSONDecoder().decode(Choice.self, from: JSONEncoder().encode(choice))
        #expect(restored == choice)
    }

    @Test func noChoiceMentionsAnArgument() {
        for choice in ChoiceBuilder.generic {
            #expect(!choice.explanation.contains("--") && !choice.badge.contains("--"))
        }
    }
}
