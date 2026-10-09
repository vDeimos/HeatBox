import Foundation
import Testing
@testable import Engine

private func catalog() -> FormatCatalog {
    guard case .video(let media) = Probe.interpret(phobosSample, link: "x") else { return FormatCatalog(formats: []) }
    return FormatCatalog(media)
}

@Suite struct FormatCatalogTests {
    @Test func aFormatIsReadFromTheToolsWords() throws {
        let format = try #require(MediaFormat([
            "format_id": "401", "ext": "mp4", "vcodec": "av01.0.13M.08", "acodec": "none", "width": 3840, "height": 2160,
            "fps": 60, "tbr": 8981.827, "filesize": 712_445_280, "filesize_approx": 712_445_254,
            "format_note": "2160p60", "resolution": "3840x2160", "protocol": "https", "dynamic_range": "SDR",
        ]))
        #expect(format.kind == .video)
        #expect(format.videoCodec == "av01.0.13M.08" && format.audioCodec == nil)
        #expect(format.shortSide == 2160)
        #expect(format.bytes == 712_445_280 && !format.bytesEstimated)
        #expect(FormatCatalog.row(format) == FormatCatalog.Row(
            id: "401", kind: "Video", ext: "mp4", resolution: "3840x2160", fps: "60", videoCodec: "av01.0.13M.08",
            audioCodec: "", bitrate: "8982k", size: "712 MB", note: "2160p60"))
    }

    @Test func anEstimatedSizeIsMarked() throws {
        let format = try #require(MediaFormat(["format_id": "hls", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.2",
                                               "tbr": 160, "filesize_approx": 4_277_720, "resolution": "audio only"]))
        #expect(format.kind == .audio)
        #expect(format.bytes == 4_277_720 && format.bytesEstimated)
        #expect(FormatCatalog.row(format).size == "~4.3 MB")
        #expect(FormatCatalog.row(format).kind == "Audio")
        #expect(FormatCatalog.row(format).fps == "")
    }

    @Test func storyboardsAndNamelessEntriesAreNotFormats() {
        #expect(MediaFormat(["format_id": "sb0", "ext": "mhtml", "vcodec": "none", "acodec": "none"]) == nil)
        #expect(MediaFormat(["format_id": "sb1", "ext": "jpg", "vcodec": "none", "acodec": "none", "format_note": "storyboard"]) == nil)
        #expect(MediaFormat(["ext": "mp4"]) == nil)
        #expect(MediaFormat(["format_id": ""]) == nil)
    }

    @Test func whatTheSiteDoesNotSayIsNotGuessedWrongly() throws {
        // Nothing known: a direct link to a file.
        let bare = try #require(MediaFormat(["format_id": "mp4", "ext": "mp4", "vcodec": NSNull(), "resolution": NSNull()]))
        #expect(bare.kind == .unknown)
        #expect(FormatCatalog.row(bare).kind == "Unknown")
        #expect(FormatCatalog.row(bare).size == "" && FormatCatalog.row(bare).bitrate == "")
        // A picture size and no word on the codecs: an ordinary file with picture and sound.
        let sized = try #require(MediaFormat(["format_id": "http-720", "ext": "mp4", "width": 1280, "height": 720]))
        #expect(sized.kind == .combined)
        #expect(sized.videoCodec == nil && sized.audioCodec == nil)
        // Known to have no picture, so it must be sound (YouTube's HLS audio is listed so).
        let soundOnly = try #require(MediaFormat(["format_id": "233", "ext": "mp4", "vcodec": "none", "resolution": "audio only"]))
        #expect(soundOnly.kind == .audio && soundOnly.audioCodec == nil)
        // A known lack of sound is respected.
        let silent = try #require(MediaFormat(["format_id": "v", "height": 720, "acodec": "none"]))
        #expect(silent.kind == .video)
        // A known codec with no size is still a video, but belongs to no tier.
        let unsized = try #require(MediaFormat(["format_id": "u", "vcodec": "avc1", "acodec": "mp4a"]))
        #expect(unsized.kind == .combined && unsized.shortSide == nil && unsized.isH264)
    }

    @Test func aSizeOfNothingIsNoSize() throws {
        let format = try #require(MediaFormat(["format_id": "x", "vcodec": "avc1", "filesize": 0, "filesize_approx": 0]))
        #expect(format.bytes == nil && !format.bytesEstimated)
    }

    @Test func theTableListsBestFirst() {
        let table = catalog()
        #expect(table.formats.map(\.id) == ["313", "137", "140"])
        #expect(table.rows().map(\.id) == ["313", "137", "140"])
        #expect(table.rows().map(\.kind) == ["Video", "Video", "Audio"])
        #expect(table.rows().map(\.size) == ["1.9 GB", "300 MB", "12 MB"])
    }

    @Test func theTableCanBeFiltered() throws {
        let combined = try #require(MediaFormat(["format_id": "18", "ext": "mp4", "vcodec": "avc1", "acodec": "mp4a", "width": 640, "height": 360]))
        let table = FormatCatalog(formats: catalog().formats.reversed() + [combined])
        #expect(table.formats(.all).map(\.id) == ["18", "313", "137", "140"])
        #expect(table.formats(.video).map(\.id) == ["313", "137"])
        #expect(table.formats(.audio).map(\.id) == ["140"])
        #expect(table.formats(.combined).map(\.id) == ["18"])
        #expect(table.rows(.audio).map(\.id) == ["140"])
    }

    @Test func pickedRowsBecomeAFormatChoice() throws {
        let combined = try #require(MediaFormat(["format_id": "18", "ext": "mp4", "vcodec": "avc1", "acodec": "mp4a", "width": 640, "height": 360]))
        let table = FormatCatalog(formats: [combined] + catalog().formats.reversed())
        #expect(table.selector(for: []) == nil)
        #expect(table.selector(for: ["nope"]) == nil)
        #expect(table.selector(for: ["137"]) == "137")
        #expect(table.selector(for: ["140"]) == "140")
        #expect(table.selector(for: ["137", "140"]) == "137+140", "video first, then audio")
        #expect(table.selector(for: ["313", "137", "140"]) == "313+140", "one video stream only: the better one")
        #expect(table.selector(for: ["18"]) == "18")
        #expect(table.selector(for: ["18", "140"]) == "18", "a version with its own sound needs no audio stream")
    }

    @Test func aFormatChoiceFitsARecipe() throws {
        var recipe = DownloadRecipe()
        recipe.customFormat = try #require(catalog().selector(for: ["137", "140"]))
        let plan = try YtdlpCommand.plan(.init(recipe: recipe, links: ["https://example.com/v"], folder: "/out"),
                                         toolchain: YtdlpCommand.Toolchain(ytdlp: "/tools/yt-dlp", environment: [:]))
        let index = try #require(plan.visibleArguments.firstIndex(of: "-f"))
        #expect(plan.visibleArguments[index + 1] == "137+140")
    }

    @Test func sizesReadTheSameOnEveryMachine() {
        #expect(ByteText.string(0) == "0 bytes")
        #expect(ByteText.string(999) == "999 bytes")
        #expect(ByteText.string(1_000) == "1 KB")
        #expect(ByteText.string(482_300) == "482 KB")
        #expect(ByteText.string(999_600) == "1 MB")
        #expect(ByteText.string(3_422_176) == "3.4 MB")
        #expect(ByteText.string(5_000_000) == "5 MB")
        #expect(ByteText.string(9_960_000) == "10 MB")
        #expect(ByteText.string(312_400_000) == "312 MB")
        #expect(ByteText.string(999_700_000) == "1 GB")
        #expect(ByteText.string(1_912_000_000) == "1.91 GB")
        #expect(ByteText.string(2_500_000_000) == "2.5 GB")
        #expect(ByteText.string(-5) == "0 bytes")
    }
}
