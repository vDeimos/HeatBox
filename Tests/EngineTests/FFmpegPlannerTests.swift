import Foundation
import Testing
@testable import Engine

// The FFmpeg planner: Phobos's conversion and loudness checks, ported, the
// re-encode with Studio's encoders, and golden fixtures beside the yt-dlp
// ones (`Fixtures/golden/ffmpeg`): what goes in, the exact arguments out.
//
// To record a new fixture or accept a deliberate change, run
//     UPDATE_GOLDEN=1 scripts/test.sh --filter FFmpegGoldenTests
// and read the diff before committing it.

private let film = FileFacts(duration: 600, bitRate: 8_160_000, videoCodec: "vp9", audioCodec: "opus",
                             width: 3840, height: 2160, size: 612_000_000)
private var compatible: FileFacts {
    var facts = film
    facts.videoCodec = "h264"
    facts.audioCodec = "aac"
    return facts
}
private let nothingExists: (String) -> Bool = { _ in false }

@Suite struct FileFactsTests {
    @Test func aFilesFactsAreRead() {
        let probe: [String: Any] = [
            "format": ["duration": "600.0", "bit_rate": "8160000"],
            "streams": [
                ["codec_type": "video", "codec_name": "vp9", "width": 3840, "height": 2160],
                ["codec_type": "audio", "codec_name": "opus", "sample_rate": "48000"],
            ],
        ]
        let facts = FileFacts.parse(probe: probe, size: 612_000_000)
        #expect(facts == FileFacts(duration: 600, bitRate: 8_160_000, videoCodec: "vp9", audioCodec: "opus",
                                   width: 3840, height: 2160, sampleRate: 48000, size: 612_000_000))
        #expect(facts.resolution == 2160)
    }

    @Test func aCoverPictureIsNotTheVideo() throws {
        let output = """
        {"format": {"duration": "240.5"}, "streams": [
          {"codec_type": "audio", "codec_name": "aac", "sample_rate": "44100"},
          {"codec_type": "video", "codec_name": "mjpeg", "width": 1280, "height": 1280, "disposition": {"attached_pic": 1}}]}
        """
        let facts = try #require(FileFacts.parse(output: output, size: 10))
        #expect(facts.videoCodec == nil && facts.hasCover && facts.audioCodec == "aac" && facts.sampleRate == 44100)
        #expect(FileFacts.parse(output: "not an answer", size: 0) == nil)
        #expect(FileFacts.parse(output: "{}", size: 0) == nil)
        #expect(FileFacts.inspectArguments("/m/a.m4a").last == "/m/a.m4a")
    }

    @Test func whichFilesAnIPhonePlaysAsTheyAre() {
        func facts(_ video: String?, _ audio: String?) -> FileFacts {
            FileFacts(duration: 60, bitRate: 1_000_000, videoCodec: video, audioCodec: audio, width: 1920, height: 1080, size: 1000)
        }
        #expect(PhoneReady.isReady(path: "/m/a.mp4", facts: facts("h264", "aac")))
        #expect(PhoneReady.isReady(path: "/m/a.MOV", facts: facts("hevc", "aac")))
        #expect(PhoneReady.isReady(path: "/m/a.mp4", facts: facts("h264", nil)))
        #expect(!PhoneReady.isReady(path: "/m/a.mp4", facts: facts("h264", "opus")))
        #expect(!PhoneReady.isReady(path: "/m/a.mp4", facts: facts("vp9", "aac")))
        #expect(!PhoneReady.isReady(path: "/m/a.mkv", facts: facts("h264", "aac")))
        #expect(PhoneReady.isReady(path: "/m/a.m4a", facts: facts(nil, "aac")))
        #expect(PhoneReady.isReady(path: "/m/a.mp3", facts: facts(nil, "mp3")))
        #expect(!PhoneReady.isReady(path: "/m/a.webm", facts: facts(nil, "opus")))
        #expect(!PhoneReady.isReady(path: "/m/a.mp4", facts: facts(nil, nil)))
        #expect(PhoneReady.conversion(for: facts("vp9", "opus")) == .playEverywhere)
        #expect(PhoneReady.conversion(for: facts(nil, "opus")) == .extractAudio)
    }
}

@Suite struct ConvertPlanTests {
    @Test func toMP4ReencodesWhatQuickTimeCannotPlayAndNamesTheResultBesideTheOriginal() throws {
        let plan = try #require(FFmpegPlanner.convert(.playEverywhere, input: "/v/Film.webm", facts: film, exists: nothingExists))
        #expect(plan.arguments.contains("h264_videotoolbox") && plan.fallback?.contains("libx264") == true)
        #expect(plan.output == "/v/Film (MP4).mp4")
        #expect(plan.arguments.last == plan.output && plan.fallback?.last == plan.output)
        // The original is read, never written.
        #expect(!plan.arguments.dropFirst(plan.arguments.firstIndex(of: "-i")! + 2).contains("/v/Film.webm"))
    }

    @Test func compatibleVideoIsOnlyRepackaged() throws {
        let plan = try #require(FFmpegPlanner.convert(.playEverywhere, input: "/v/Film.mkv", facts: compatible, exists: nothingExists))
        #expect(plan.copiesOnly && plan.fallback == nil)
        #expect(plan.estimatedBytes == 612_000_000)
    }

    @Test func aNameThatIsTakenGetsANumber() throws {
        let plan = try #require(FFmpegPlanner.convert(.playEverywhere, input: "/v/Film.webm", facts: film) { $0 == "/v/Film (MP4).mp4" })
        #expect(plan.output == "/v/Film (MP4) (2).mp4")
    }

    @Test func shrinkingScalesDownAndItsEstimateAddsUp() throws {
        let plan = try #require(FFmpegPlanner.convert(.shrink(.medium), input: "/v/Film.webm", facts: film, exists: nothingExists))
        #expect(plan.arguments.contains("scale=-2:1080"))
        let expected = (8_160_000 * 0.85 * 0.35 + 128_000) * 600 / 8
        #expect(abs((plan.estimatedBytes ?? 0) - expected) < 1)
    }

    @Test func aFileThatIsAlreadyTinyIsNotMadeBigger() {
        var tiny = film
        tiny.bitRate = 200_000
        tiny.duration = 19
        tiny.size = 475_000
        #expect(FFmpegPlanner.convert(.shrink(.small), input: "/v/Tiny.webm", facts: tiny, exists: nothingExists) == nil)
    }

    @Test func theThreeSizesAreReallyDifferentAndSoftwareGoesFirst() throws {
        var bunny = film
        bunny.width = 854
        bunny.height = 480
        bunny.bitRate = 455_000
        bunny.duration = 634
        bunny.size = 36_100_000
        let plans = try ShrinkLevel.allCases.map {
            try #require(FFmpegPlanner.convert(.shrink($0), input: "/v/Bunny.webm", facts: bunny, exists: nothingExists))
        }
        let sizes = plans.map { $0.estimatedBytes ?? 0 }
        #expect(sizes[0] > sizes[1] && sizes[1] > sizes[2])
        #expect(sizes[2] < 0.5 * Double(bunny.size))
        #expect(plans[2].arguments.contains("libx264") && plans[2].fallback?.contains("h264_videotoolbox") == true)
    }

    @Test func anUprightVideoIsScaledByItsShorterSide() throws {
        var upright = film
        upright.width = 2160
        upright.height = 3840
        let plan = try #require(FFmpegPlanner.convert(.shrink(.small), input: "/v/Tall.webm", facts: upright, exists: nothingExists))
        #expect(plan.arguments.contains("scale=720:-2"))
    }

    @Test func audioIsCopiedWhenItAlreadyFitsAndASilentFileIsRefused() throws {
        let plan = try #require(FFmpegPlanner.convert(.extractAudio, input: "/v/Film.mkv", facts: compatible, exists: nothingExists))
        #expect(plan.copiesOnly && plan.output == "/v/Film (audio).m4a")
        var silent = compatible
        silent.audioCodec = nil
        #expect(FFmpegPlanner.convert(.extractAudio, input: "/v/Film.mkv", facts: silent, exists: nothingExists) == nil)
    }

    @Test func aClipIsCutAtTheExactTimesAndItsLengthDrivesTheProgressBar() throws {
        let plan = try #require(FFmpegPlanner.convert(.clip(start: 165, end: 400), input: "/v/Film.mkv", facts: compatible, exists: nothingExists))
        #expect(plan.arguments.contains("165.000") && plan.arguments.contains("400.000"))
        #expect(plan.outputDuration == 235)
        #expect(FFmpegPlanner.convert(.clip(start: 50, end: 10), input: "/v/Film.mkv", facts: compatible, exists: nothingExists) == nil)
    }

    @Test func progressSecondsAreRead() {
        #expect(FFmpegPlanner.progressSeconds(line: "out_time_us=12500000") == 12.5)
        #expect(FFmpegPlanner.progressSeconds(line: "out_time_ms=3000000") == 3)
        #expect(FFmpegPlanner.progressSeconds(line: "speed=2.1x") == nil)
        #expect(FFmpegPlanner.progressSeconds(line: "out_time_us=N/A") == nil)
    }
}

@Suite struct EncodePlanTests {
    private func recipe(_ change: (inout DownloadRecipe) -> Void) -> DownloadRecipe {
        var recipe = DownloadRecipe()
        recipe.encodeEnabled = true
        recipe.container = .mp4
        change(&recipe)
        return recipe
    }

    @Test func everyEncoderGivesACommandItsContainerCanHold() {
        for encoder in VideoEncoder.allCases {
            for container in encoder.compatibleContainers {
                let recipe = recipe { $0.encoder = encoder; $0.container = container }
                #expect(RecipeValidator.errors(in: recipe).isEmpty)
                let plan = FFmpegPlanner.encode(recipe: recipe, input: "/w/in.mkv", output: "/w/out.\(container.rawValue)", facts: film)
                #expect(plan.arguments.firstIndex(of: "-c:v:0").map { plan.arguments[$0 + 1] } == encoder.rawValue)
                #expect(plan.arguments.last == "/w/out.\(container.rawValue)")
                // The input is named once, as the input.
                #expect(plan.arguments.filter { $0 == "/w/in.mkv" }.count == 1)
                #expect(plan.outputDuration == 600 && !plan.copiesOnly)
            }
        }
    }

    @Test func hardwareEncodersHaveASoftwareSecondAttemptAndSoftwareOnesHaveNone() {
        let hardware = FFmpegPlanner.encode(recipe: recipe { $0.encoder = .videoToolboxHEVC }, input: "/w/in.mkv", output: "/w/out.mp4", facts: film)
        #expect(hardware.fallback?.contains("libx265") == true && hardware.fallback?.contains("hvc1") == true)
        #expect(hardware.fallback?.contains("hevc_videotoolbox") == false)
        let h264 = FFmpegPlanner.encode(recipe: recipe { $0.encoder = .videoToolboxH264 }, input: "/w/in.mkv", output: "/w/out.mp4", facts: film)
        #expect(h264.fallback?.contains("libx264") == true)
        for encoder in [VideoEncoder.x264, .x265, .vp9, .av1, .prores] {
            let container = encoder.compatibleContainers[0]
            #expect(FFmpegPlanner.encode(recipe: recipe { $0.encoder = encoder; $0.container = container },
                                         input: "/w/in.mkv", output: "/w/out", facts: film).fallback == nil)
        }
    }

    @Test func aBitrateEncoderHasASizeEstimateAndAQualityOneHasNone() {
        let hardware = FFmpegPlanner.encode(recipe: recipe { $0.encoder = .videoToolboxH264; $0.hardwareBitrateMbps = 4; $0.encodeAudioBitrate = .b128 },
                                            input: "/w/in.mkv", output: "/w/out.mp4", facts: film)
        #expect(hardware.estimatedBytes == Double((4_000_000 + 128_000) * 600 / 8))
        #expect(FFmpegPlanner.encode(recipe: recipe { $0.encoder = .x264 }, input: "/w/in.mkv", output: "/w/out.mp4", facts: film).estimatedBytes == nil)
    }

    @Test func thePictureIsNeverScaledUp() {
        let plan = FFmpegPlanner.encode(recipe: recipe { $0.encoder = .x264; $0.scale = .h720 }, input: "/w/in.mkv", output: "/w/out.mp4", facts: film)
        #expect(plan.arguments.contains("scale=-2:'min(720,ih)'"))
    }

    @Test func aCoverPictureIsCarriedOverWhereTheFileTypeHoldsOne() {
        var withCover = film
        withCover.hasCover = true
        func arguments(_ container: VideoContainer, _ encoder: VideoEncoder, _ facts: FileFacts?) -> [String] {
            FFmpegPlanner.encode(recipe: recipe { $0.encoder = encoder; $0.container = container; $0.scale = .h720 },
                                 input: "/w/in.mp4", output: "/w/out", facts: facts).arguments
        }
        let kept = arguments(.mp4, .x265, withCover)
        #expect(kept.contains("0:v:disp:attached_pic?") && kept.contains("attached_pic"))
        // The encoder, its tag and the scaling are for the picture alone; the cover is copied.
        #expect(kept.contains("-c:v:0") && kept.contains("-tag:v:0") && kept.contains("-filter:v:0"))
        #expect(kept.firstIndex(of: "-c:v:1").map { kept[$0 + 1] } == "copy")
        #expect(kept.contains("0:V:0") && !kept.contains("-vf"))
        #expect(!arguments(.mp4, .x265, film).contains("0:v:disp:attached_pic?"))
        #expect(!arguments(.mp4, .x265, nil).contains("0:v:disp:attached_pic?"))
        #expect(!arguments(.webm, .vp9, withCover).contains("0:v:disp:attached_pic?"))
    }

    @Test func soundIsCopiedOnlyWhenAskedAndWhenItFits() {
        func audio(_ facts: FileFacts?, _ change: @escaping (inout DownloadRecipe) -> Void) -> String? {
            let arguments = FFmpegPlanner.encode(recipe: recipe { $0.encoder = .x264; change(&$0) }, input: "/w/in.mkv", output: "/w/out", facts: facts).arguments
            return arguments.firstIndex(of: "-c:a").map { arguments[$0 + 1] }
        }
        #expect(audio(compatible) { _ in } == "aac")
        #expect(audio(compatible) { $0.encodeAudio = false } == "copy")
        #expect(audio(film) { $0.encodeAudio = false; $0.container = .mov } == "aac")
        #expect(audio(compatible) { $0.encodeAudio = false; $0.container = .webm; $0.encoder = .vp9 } == "libopus")
        #expect(audio(film) { $0.encodeAudio = false; $0.container = .mkv } == "copy")
        #expect(audio(compatible) { $0.encodeAudio = false; $0.gainDB = 2 } == "aac")
        #expect(audio(nil) { $0.encodeAudio = false } == "aac")
    }
}

// MARK: - Golden fixtures

enum FFmpegFixtures {
    static let directory = GoldenFixtures.directory.appendingPathComponent("ffmpeg", isDirectory: true)

    static func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") }.sorted()
    }

    static func load(_ name: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(name))) as? [String: Any])
    }

    static func facts(_ value: Any?) -> FileFacts? {
        guard let object = value as? [String: Any] else { return nil }
        func number(_ key: String) -> Double { (object[key] as? NSNumber)?.doubleValue ?? 0 }
        return FileFacts(duration: number("duration"), bitRate: number("bitRate"), videoCodec: object["videoCodec"] as? String,
                         audioCodec: object["audioCodec"] as? String, width: Int(number("width")), height: Int(number("height")),
                         sampleRate: Int(number("sampleRate")), hasCover: object["hasCover"] as? Bool ?? false, size: Int64(number("size")))
    }

    static func recipe(_ fixture: [String: Any]) throws -> DownloadRecipe {
        var recipe = DownloadRecipe()
        if let id = fixture["preset"] as? String { recipe = try #require(PresetCatalog.preset(id: id), "unknown preset \(id)").recipe }
        if let overrides = fixture["recipe"] as? [String: Any] { recipe = recipe.overlaid(with: overrides) }
        return recipe
    }

    static func convertKind(_ text: String) throws -> ConvertKind {
        let parts = text.split(separator: ":").map(String.init)
        switch parts[0] {
        case "playEverywhere": return .playEverywhere
        case "extractAudio": return .extractAudio
        case "shrink": return .shrink(try #require(ShrinkLevel(rawValue: parts[1])))
        case "clip":
            let times = parts[1].split(separator: "-").compactMap { Double($0) }
            return .clip(start: times[0], end: times[1])
        default:
            throw CocoaError(.coderInvalidValue)
        }
    }

    static func describe(_ plan: FFmpegPlanner.Plan) -> [String: Any] {
        var result: [String: Any] = ["arguments": plan.arguments, "output": plan.output, "copiesOnly": plan.copiesOnly,
                                     "outputDuration": plan.outputDuration]
        if let fallback = plan.fallback { result["fallback"] = fallback }
        if let estimate = plan.estimatedBytes { result["estimatedBytes"] = estimate.rounded() }
        return result
    }

    /// What the engine plans for a fixture.
    static func outcome(of fixture: [String: Any]) throws -> [String: Any] {
        let input = fixture["input"] as? String ?? ""
        let output = fixture["output"] as? String ?? ""
        switch try #require(fixture["kind"] as? String) {
        case "encode":
            return describe(FFmpegPlanner.encode(recipe: try recipe(fixture), input: input, output: output, facts: facts(fixture["facts"])))
        case "convert":
            let kind = try convertKind(try #require(fixture["convert"] as? String))
            guard let plan = FFmpegPlanner.convert(kind, input: input, facts: try #require(facts(fixture["facts"])), exists: { _ in false }) else {
                return ["refused": true]
            }
            return describe(plan)
        case "loudness":
            var measured: Loudness.Measurement?
            if let m = fixture["measured"] as? [String: NSNumber] {
                measured = Loudness.Measurement(integrated: m["integrated"]!.doubleValue, truePeak: m["truePeak"]!.doubleValue,
                                                range: m["range"]!.doubleValue, threshold: m["threshold"]!.doubleValue, offset: m["offset"]!.doubleValue)
            }
            let arguments = Loudness.normalizeArguments(input: input, output: output, measured: measured, facts: try #require(facts(fixture["facts"])),
                                                        recipe: try recipe(fixture), pictureBlock: fixture["pictureBlock"] as? String)
            guard let arguments else { return ["refused": true] }
            return ["measure": Loudness.measureArguments(input: input), "arguments": arguments]
        case "retag":
            let track = try #require(fixture["track"] as? [String: Any])
            let cover = (fixture["cover"] as? [String: String]).map { ChapterTagger.Cover(path: $0["path"]!, mime: $0["mime"]!) }
            return ["arguments": ChapterTagger.retagArguments(
                track: ChapterTagger.Track(path: track["path"] as! String, title: track["title"] as! String, artist: track["artist"] as? String),
                index: fixture["index"] as! Int, total: fixture["total"] as! Int, cover: cover,
                pictureBlock: fixture["pictureBlock"] as? String, output: output)]
        default:
            throw CocoaError(.coderInvalidValue)
        }
    }
}

@Suite struct FFmpegGoldenTests {
    @Test func everyFixtureProducesItsRecordedCommand() throws {
        let names = try FFmpegFixtures.names()
        #expect(names.count >= 30)
        for name in names {
            var fixture = try FFmpegFixtures.load(name)
            let actual = try FFmpegFixtures.outcome(of: fixture)
            if GoldenFixtures.updating {
                fixture["expect"] = actual
                let data = try JSONSerialization.data(withJSONObject: fixture, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                try (data + Data("\n".utf8)).write(to: FFmpegFixtures.directory.appendingPathComponent(name))
                continue
            }
            let expected = try #require(fixture["expect"] as? [String: Any], "\(name) has no recorded result; run with UPDATE_GOLDEN=1")
            #expect(NSDictionary(dictionary: actual).isEqual(to: expected), "\(name): got \(actual)")
        }
    }

    @Test func noPlanWritesOverItsInputAndEveryPlanEndsWithItsOutput() throws {
        for name in try FFmpegFixtures.names() {
            let fixture = try FFmpegFixtures.load(name)
            let outcome = try FFmpegFixtures.outcome(of: fixture)
            guard let arguments = outcome["arguments"] as? [String], let input = fixture["input"] as? String ?? (fixture["track"] as? [String: Any])?["path"] as? String else { continue }
            #expect(arguments.last != input, "\(name)")
            #expect(arguments.filter { $0 == input }.count == 1, "\(name)")
            #expect(arguments.contains("-nostdin"), "\(name)")
            if let fallback = outcome["fallback"] as? [String] { #expect(fallback.last == arguments.last, "\(name)") }
        }
    }
}
