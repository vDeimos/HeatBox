import Foundation
import Testing
@testable import Engine

// Phobos's loudness checks, ported, and the options the unified pass adds.

private let sampleOutput = """
[Parsed_loudnorm_0 @ 0x600003d58000]
{
\t"input_i" : "-38.26",
\t"input_tp" : "-34.04",
\t"input_lra" : "0.00",
\t"input_thresh" : "-48.26",
\t"output_i" : "-16.03",
\t"output_tp" : "-11.76",
\t"output_lra" : "0.00",
\t"output_thresh" : "-26.03",
\t"normalization_type" : "dynamic",
\t"target_offset" : "0.03"
}
"""
private let measured = Loudness.Measurement(integrated: -38.26, truePeak: -34.04, range: 0, threshold: -48.26, offset: 0.03)
private let song = FileFacts(duration: 240, audioCodec: "aac", sampleRate: 44100, hasCover: true)

@Suite struct LoudnessTests {
    private func audio(_ change: (inout DownloadRecipe) -> Void = { _ in }) -> DownloadRecipe {
        var recipe = PresetCatalog.audioOnly.recipe
        recipe.evenLoudness = true
        change(&recipe)
        return recipe
    }

    @Test func theMeasurementIsReadAndSilenceAndNonsenseAreNot() {
        #expect(Loudness.parse(sampleOutput) == measured)
        #expect(Loudness.parse(sampleOutput.replacingOccurrences(of: "-38.26", with: "-inf")) == nil)
        #expect(Loudness.parse("no figures here") == nil)
        #expect(Loudness.parse("") == nil)
    }

    @Test func theMeasuringPassAsksForFiguresAndWritesNothing() {
        let arguments = Loudness.measureArguments(input: "/m/a.m4a")
        #expect(arguments.contains("loudnorm=I=-16:TP=-1.5:LRA=11:print_format=json"))
        #expect(Array(arguments.suffix(3)) == ["-f", "null", "-"])
    }

    @Test func theSecondPassUsesTheMeasurementCopiesTheCoverAndKeepsTheTags() throws {
        let adjust = try #require(Loudness.normalizeArguments(input: "/m/a.m4a", output: "/w/a.m4a", measured: measured, facts: song, recipe: audio()))
        #expect(adjust.contains("loudnorm=I=-16:TP=-1.5:LRA=11:measured_I=-38.26:measured_TP=-34.04:measured_LRA=0.00:measured_thresh=-48.26:offset=0.03:linear=true"))
        #expect(adjust.contains("-c:v") && adjust.contains("copy") && adjust.contains("0:v?"))
        #expect(adjust.contains("-map_metadata") && adjust.last == "/w/a.m4a")
        // Phobos's own figures for an M4A: AAC at 192 kbps, the file's sample rate.
        #expect(adjust.contains("aac") && adjust.contains("192k") && adjust.contains("44100"))
    }

    @Test func withoutAMeasurementItStillAdjusts() {
        #expect(Loudness.filter(nil) == "loudnorm=I=-16:TP=-1.5:LRA=11")
    }

    @Test func aVolumeChangeComesAfterTheCorrection() {
        #expect(Loudness.filter(nil, gainDB: 3) == "loudnorm=I=-16:TP=-1.5:LRA=11,volume=3.0dB")
        #expect(Loudness.filter(measured, gainDB: -2.5).hasSuffix(":linear=true,volume=-2.5dB"))
    }

    @Test func theSoundIsWrittenBackInTheFormatTheFileHas() throws {
        func codec(_ ext: String, _ codec: String, _ quality: AudioQuality = .q0) -> [String]? { Loudness.encoder(ext: ext, codec: codec, quality: quality) }
        #expect(codec("m4a", "aac", .standard) == ["-c:a", "aac", "-b:a", "192k"])
        #expect(codec("m4a", "aac", .k320) == ["-c:a", "aac", "-b:a", "320k"])
        #expect(codec("m4a", "alac") == ["-c:a", "alac"])
        #expect(codec("mp3", "mp3") == ["-c:a", "libmp3lame", "-q:a", "0"])
        #expect(codec("mp3", "mp3", .k128) == ["-c:a", "libmp3lame", "-b:a", "128k"])
        #expect(codec("opus", "opus", .k64) == ["-c:a", "libopus", "-b:a", "64k"])
        #expect(codec("ogg", "vorbis", .q5) == ["-c:a", "libvorbis", "-b:a", "128k"])
        #expect(codec("flac", "flac") == ["-c:a", "flac"])
        #expect(codec("wav", "pcm_s24le") == ["-c:a", "pcm_s24le"])
        #expect(codec("wav", "adpcm_ms") == ["-c:a", "pcm_s16le"])
        #expect(codec("webm", "opus") == nil)
        // Every ending the step takes on has an encoder.
        for ext in Loudness.extensions { #expect(codec(ext, "aac") != nil, "\(ext)") }
    }

    @Test func sampleRateAndChannelsFollowTheRecipeThenTheFile() throws {
        func value(_ flag: String, _ arguments: [String]) -> String? { arguments.firstIndex(of: flag).map { arguments[$0 + 1] } }
        let kept = try #require(Loudness.normalizeArguments(input: "/m/a.flac", output: "/w/a.flac", measured: nil,
                                                            facts: FileFacts(audioCodec: "flac", sampleRate: 96000), recipe: audio()))
        #expect(value("-ar", kept) == "96000" && !kept.contains("-ac"))
        let chosen = try #require(Loudness.normalizeArguments(input: "/m/a.mp3", output: "/w/a.mp3", measured: nil, facts: song,
                                                              recipe: audio { $0.sampleRate = .r48000; $0.channels = .mono }))
        #expect(value("-ar", chosen) == "48000" && value("-ac", chosen) == "1")
        #expect(chosen.contains("-id3v2_version"))
        let unknown = try #require(Loudness.normalizeArguments(input: "/m/a.m4a", output: "/w/a.m4a", measured: nil,
                                                               facts: FileFacts(audioCodec: "aac"), recipe: audio()))
        #expect(value("-ar", unknown) == "44100")
        // Opus exists only at 48,000, whatever the recipe says.
        let opus = try #require(Loudness.normalizeArguments(input: "/m/a.opus", output: "/w/a.opus", measured: nil, facts: song,
                                                            recipe: audio { $0.sampleRate = .r44100 }, pictureBlock: "QUJD"))
        #expect(value("-ar", opus) == "48000")
        // Ogg cannot take a picture stream; the cover goes in as a tag.
        #expect(!opus.contains("0:v?") && value("-metadata:s:a:0", opus) == "METADATA_BLOCK_PICTURE=QUJD")
    }

    @Test func aFileThePassCannotWriteIsRefused() {
        #expect(Loudness.normalizeArguments(input: "/m/a.webm", output: "/w/a.webm", measured: nil, facts: song, recipe: audio()) == nil)
    }
}
