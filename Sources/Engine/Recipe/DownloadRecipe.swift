import Foundation

/// Part of a video, in seconds. A missing end means "to the end".
public struct Clip: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double?

    public init(start: Double, end: Double? = nil) {
        self.start = start
        self.end = end
    }
}

/// Everything a download can do, in one typed model (plan Section 3.4).
///
/// It is Studio's option set reorganised and pruned, plus Phobos's own
/// choices (exact cuts, even loudness, splitting by chapter). The defaults are
/// Phobos's: the container is left to the download tool, no cover art or
/// extras unless asked. `studioDefaults` is Studio's baseline, kept so its
/// built-in presets and, later, its saved settings map onto this model.
///
/// A recipe says *what* is wanted. Where it goes, which links, and the
/// scratch folder belong to the job (`YtdlpCommand.Request`).
public struct DownloadRecipe: Codable, Equatable, Sendable {
    // Format
    public var mode: DownloadMode = .video
    public var container: VideoContainer = .automatic
    public var maxResolution: MaxResolution = .best
    public var videoCodec: VideoCodecPreference = .any
    public var audioCodec: AudioCodecPreference = .any
    public var frameRateLimit: FrameRateLimit = .any
    public var preferCompatibleStreams = true
    public var preferFreeFormats = false
    public var forceRemux = true
    public var customFormat = ""
    public var customSort = ""

    // Audio extraction
    public var audioFormat: AudioFormat = .mp3
    public var audioQuality: AudioQuality = .q0

    // Audio filters. `evenLoudness` is Phobos's two-pass loudness step,
    // run on the finished file (`Loudness`): it adds nothing to the download
    // command. The rest ride along in the extract-audio step, except the
    // volume change, which the loudness step applies itself when it runs.
    public var evenLoudness = false
    public var gainDB: Double = 0
    public var sampleRate: SampleRate = .keep
    public var channels: ChannelLayout = .keep

    // Re-encode after download, planned by `FFmpegPlanner.encode`.
    // `replaceOriginal` moves the download to the Trash once the re-encoded
    // file has taken its place; without it both are saved.
    public var encodeEnabled = false
    public var encoder: VideoEncoder = .videoToolboxHEVC
    public var qualityFactor: Double = 23
    public var encoderSpeed: EncoderSpeed = .medium
    public var hardwareBitrateMbps: Double = 6
    public var scale: ScaleHeight = .keep
    public var encodeAudio = true
    public var encodeAudioBitrate: AudioBitrate = .b192
    public var replaceOriginal = false

    // Chapters and SponsorBlock
    public var chapterSource: ChapterSource = .youtube
    public var embedChapters = true
    public var splitChapters = false
    public var chaptersInFolder = true
    public var removeChaptersPattern = ""
    public var sponsorBlock: SponsorBlockMode = .off
    public var sponsorCategories: [SponsorCategory] = [.sponsor, .selfpromo, .interaction]
    /// Cut at the exact time instead of the nearest keyframe, for a clip and
    /// for removed segments. Slower, but picture and sound stay together.
    public var exactCut = true

    // Part of a video
    public var clip: Clip?

    // Subtitles
    public var writeSubtitles = false
    public var writeAutoSubtitles = false
    public var subtitleLanguages = "en.*"
    public var subtitleFormat: SubtitleFormat = .srt
    public var embedSubtitles = false
    /// With embedded subtitles, keep the loose subtitle files beside the video.
    public var keepSubtitleFiles = true
    /// Seconds to wait between subtitle requests; YouTube is strict about them.
    public var subtitleSleep = 0

    // Metadata and thumbnails
    public var embedMetadata = true
    public var embedThumbnail = false
    public var writeThumbnail = false
    public var thumbnailFormat: ThumbnailFormat = .original
    public var writeDescription = false
    public var writeInfoJSON = false
    public var writeComments = false

    // Music tags (see `MusicTags`)
    public var musicTags = true
    public var musicTagsOnVideo = false
    public var cleanTitles = true
    public var stripTitleNumbers = true
    public var splitArtistTitle = true
    /// Split "Artist - Song" only when the site files the video under Music or
    /// names an artist itself (Phobos). Off splits every title (Studio).
    public var splitOnlyMusic = true
    /// Guess a track number from the playlist position (Studio). Off uses only
    /// the number the site gives (Phobos).
    public var trackNumbersFromPlaylist = false
    /// Use the playlist or the title as the album when the site gives none (Studio).
    public var albumFallback = false
    public var squareCover = true
    public var tagChapterTracks = true
    public var genre = ""

    // Playlist
    public var playlistMode: PlaylistMode = .auto
    public var playlistItems = ""
    public var useArchive = false
    /// Carry on with the next item when one fails.
    public var continueOnErrors = false

    // Network
    public var rateLimit = ""
    public var concurrentFragments = 4
    public var retries = 10
    public var proxy = ""
    public var cookieBrowser: CookieBrowser = .none
    public var sleepInterval = 0
    public var maxSleepInterval = 0

    // Naming
    public var filenameTemplate: FilenameTemplate = .guided
    public var customTemplate = "%(title)s [%(id)s].%(ext)s"
    public var restrictFilenames = false
    public var noOverwrites = true
    public var noMtime = true
    public var keepIntermediateFiles = false

    // Advanced: tokenized and checked by `ExtraArgsPolicy`
    public var extraArguments = ""

    public init() {}

    /// Studio's own baseline, for its built-in presets and saved settings.
    public static var studioDefaults: DownloadRecipe {
        var recipe = DownloadRecipe()
        recipe.container = .mp4
        recipe.embedThumbnail = true
        recipe.albumFallback = true
        recipe.trackNumbersFromPlaylist = true
        recipe.splitOnlyMusic = false
        recipe.filenameTemplate = .titleOnly
        return recipe
    }

    // MARK: Derived

    /// Segments are cut out of a video (SponsorBlock or chapter removal).
    /// Without keyframes at the cuts, stream-copied video restarts at the
    /// previous keyframe and replays or freezes footage.
    public var cutsVideoSegments: Bool {
        mode != .audio && (sponsorBlock == .remove || !removeChaptersPattern.trimmed.isEmpty)
    }

    public var forcesKeyframes: Bool {
        exactCut && (clip != nil || cutsVideoSegments)
    }

    public var musicTagsActive: Bool {
        embedMetadata && musicTags && (mode == .audio || musicTagsOnVideo)
    }

    /// Chapter files are retagged one by one after splitting.
    public var retagsChapters: Bool {
        musicTagsActive && splitChapters && tagChapterTracks && mode == .audio
    }

    /// Cover art can only be embedded in some containers. With the container
    /// left automatic, a video that wants cover art is repackaged as MKV (Phobos).
    var remuxesToMKVForCover: Bool {
        mode != .audio && embedThumbnail && container == .automatic
    }

    var thumbnailEmbeddable: Bool {
        if mode == .audio { return ![.wav, .aac].contains(audioFormat) }
        return container.supportsThumbnailEmbed || remuxesToMKVForCover
    }

    var audioFiltersActive: Bool {
        gainDB != 0 || sampleRate != .keep || channels != .keep
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Reading saved recipes

extension DownloadRecipe {
    /// Reads a recipe saved by a different version of the app. Fields the
    /// file lacks keep their defaults, fields this version no longer knows are
    /// ignored, and a value that no longer fits (a removed enum case) is
    /// skipped, so one change never resets a whole preset.
    private static let optionalFields: Set<String> = ["clip"]

    public static func lenient(from saved: [String: Any]) -> DownloadRecipe {
        let encoder = JSONEncoder()
        guard let defaultsData = try? encoder.encode(DownloadRecipe()),
              var merged = (try? JSONSerialization.jsonObject(with: defaultsData)) as? [String: Any] else {
            return DownloadRecipe()
        }
        // Optional fields that are nil are left out of the encoding.
        let known = Set(merged.keys).union(optionalFields)
        for (key, value) in saved where known.contains(key) { merged[key] = value }
        if let data = try? JSONSerialization.data(withJSONObject: merged),
           let decoded = try? JSONDecoder().decode(DownloadRecipe.self, from: data) {
            return decoded
        }
        // Some value does not fit: keep every field that still decodes.
        var result = DownloadRecipe()
        for (key, value) in saved where known.contains(key) {
            guard let current = try? encoder.encode(result),
                  var trial = (try? JSONSerialization.jsonObject(with: current)) as? [String: Any] else { continue }
            trial[key] = value
            if let data = try? JSONSerialization.data(withJSONObject: trial),
               let decoded = try? JSONDecoder().decode(DownloadRecipe.self, from: data) {
                result = decoded
            }
        }
        return result
    }

    public static func lenient(from data: Data) -> DownloadRecipe? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return lenient(from: object)
    }

    /// This recipe with the given saved fields laid over it.
    public func overlaid(with fields: [String: Any]) -> DownloadRecipe {
        guard let data = try? JSONEncoder().encode(self),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return self }
        for (key, value) in fields { object[key] = value }
        return Self.lenient(from: object)
    }
}
