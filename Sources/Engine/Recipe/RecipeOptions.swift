import Foundation

// The choices a download recipe is made of. Reorganised from YT-DLP Studio's
// option enums (plan Section 7): AVI and FLV are gone, the container can be
// left to the download tool, and labels are plain words. Raw values are what
// presets store on disk, so they never change once released.

public enum DownloadMode: String, Codable, CaseIterable, Sendable {
    case video, audio, videoOnly

    public var label: String {
        switch self {
        case .video: return "Video and audio"
        case .audio: return "Audio only"
        case .videoOnly: return "Video only"
        }
    }
}

public enum VideoContainer: String, Codable, CaseIterable, Sendable {
    /// Whatever the download tool ends up with. This is Phobos's "Best available".
    case automatic
    case mp4, mkv, webm, mov

    public var label: String {
        switch self {
        case .automatic: return "Let the download tool choose"
        case .mp4: return "MP4 (plays everywhere)"
        case .mkv: return "MKV (any codec, best for archiving)"
        case .webm: return "WebM (VP9 or AV1 with Opus)"
        case .mov: return "MOV (QuickTime, Final Cut)"
        }
    }

    /// A sort token that prefers streams that fit this container without re-encoding.
    var extSort: String? {
        switch self {
        case .mp4, .mov: return "ext:mp4:m4a"
        case .webm: return "ext:webm:webm"
        case .automatic, .mkv: return nil
        }
    }

    /// A remux rule that never asks FFmpeg for an impossible stream copy
    /// (checked by Studio: H.264 and AAC cannot go in WebM; VP9 and Opus cannot
    /// go in MOV). A source that cannot fit falls back to the closest container
    /// that can hold it.
    var remuxRule: String? {
        switch self {
        case .automatic: return nil
        case .mp4, .mkv: return rawValue
        case .webm: return "mp4>mkv/mkv>mkv/webm"
        case .mov: return "webm>mp4/mov"
        }
    }

    var supportsThumbnailEmbed: Bool { [.mp4, .mkv, .mov].contains(self) }
    var supportsSubtitleEmbed: Bool { [.mp4, .mkv, .webm].contains(self) }
}

public enum MaxResolution: String, Codable, CaseIterable, Sendable {
    case best, p4320, p2160, p1440, p1080, p720, p480, p360, p240, p144

    public var height: Int? {
        switch self {
        case .best: return nil
        case .p4320: return 4320
        case .p2160: return 2160
        case .p1440: return 1440
        case .p1080: return 1080
        case .p720: return 720
        case .p480: return 480
        case .p360: return 360
        case .p240: return 240
        case .p144: return 144
        }
    }

    public init?(height: Int) {
        guard let match = Self.allCases.first(where: { $0.height == height }) else { return nil }
        self = match
    }

    public var label: String {
        guard let height else { return "Best available" }
        return "\(height)p"
    }
}

public enum VideoCodecPreference: String, Codable, CaseIterable, Sendable {
    case any, h264, h265, vp9, av1

    var sortToken: String? {
        switch self {
        case .any: return nil
        case .h264: return "vcodec:h264"
        case .h265: return "vcodec:h265"
        case .vp9: return "vcodec:vp9"
        case .av1: return "vcodec:av01"
        }
    }
}

public enum AudioCodecPreference: String, Codable, CaseIterable, Sendable {
    case any, aac, opus

    var sortToken: String? {
        switch self {
        case .any: return nil
        case .aac: return "acodec:aac"
        case .opus: return "acodec:opus"
        }
    }
}

public enum FrameRateLimit: String, Codable, CaseIterable, Sendable {
    case any, fps60, fps30, fps24

    var sortToken: String? {
        switch self {
        case .any: return nil
        case .fps60: return "fps:60"
        case .fps30: return "fps:30"
        case .fps24: return "fps:24"
        }
    }
}

public enum AudioFormat: String, Codable, CaseIterable, Sendable {
    /// Keep the original codec.
    case best
    case mp3, m4a, aac, opus, vorbis, flac, alac, wav

    public var isLossless: Bool { [.flac, .alac, .wav].contains(self) }

    /// Ogg holds no picture stream, so splitting a file that already carries
    /// cover art would fail unless the picture is dropped while splitting.
    var isOggFamily: Bool { [.opus, .vorbis, .best].contains(self) }

    /// A source stream that already matches, so no lossy-to-lossy transcode is needed.
    var preferredSourceSort: String? {
        switch self {
        case .m4a, .aac: return "acodec:aac"
        case .opus: return "acodec:opus"
        default: return nil
        }
    }
}

public enum AudioQuality: String, Codable, CaseIterable, Sendable {
    /// Say nothing and let the download tool pick its own default.
    case standard
    case q0, q2, q5, k320, k256, k192, k160, k128, k96, k64

    var argument: String? {
        switch self {
        case .standard: return nil
        case .q0: return "0"
        case .q2: return "2"
        case .q5: return "5"
        case .k320: return "320K"
        case .k256: return "256K"
        case .k192: return "192K"
        case .k160: return "160K"
        case .k128: return "128K"
        case .k96: return "96K"
        case .k64: return "64K"
        }
    }
}

public enum SampleRate: String, Codable, CaseIterable, Sendable {
    case keep, r22050, r44100, r48000, r96000

    var hertz: Int? {
        switch self {
        case .keep: return nil
        case .r22050: return 22050
        case .r44100: return 44100
        case .r48000: return 48000
        case .r96000: return 96000
        }
    }
}

public enum ChannelLayout: String, Codable, CaseIterable, Sendable {
    case keep, mono, stereo

    var count: Int? {
        switch self {
        case .keep: return nil
        case .mono: return 1
        case .stereo: return 2
        }
    }
}

// MARK: Re-encode (planned by `FFmpegPlanner.encode`; validated by `RecipeValidator`)

public enum VideoEncoder: String, Codable, CaseIterable, Sendable {
    case x264 = "libx264"
    case x265 = "libx265"
    case videoToolboxH264 = "h264_videotoolbox"
    case videoToolboxHEVC = "hevc_videotoolbox"
    case vp9 = "libvpx-vp9"
    case av1 = "libsvtav1"
    case prores = "prores_ks"

    public var usesQualityFactor: Bool { [.x264, .x265, .vp9, .av1].contains(self) }
    public var usesBitrate: Bool { [.videoToolboxH264, .videoToolboxHEVC].contains(self) }
    public var maxQualityFactor: Double { (self == .x264 || self == .x265) ? 51 : 63 }

    public var compatibleContainers: [VideoContainer] {
        switch self {
        case .x264, .videoToolboxH264: return [.mp4, .mkv, .mov]
        case .x265, .videoToolboxHEVC: return [.mp4, .mkv, .mov]
        case .vp9: return [.webm, .mkv, .mp4]
        case .av1: return [.mkv, .mp4, .webm]
        case .prores: return [.mov, .mkv]
        }
    }
}

public enum EncoderSpeed: String, Codable, CaseIterable, Sendable {
    case ultrafast, superfast, veryfast, faster, fast, medium, slow, slower, veryslow
}

public enum ScaleHeight: String, Codable, CaseIterable, Sendable {
    case keep, h2160, h1440, h1080, h720, h480, h360

    public var height: Int? {
        switch self {
        case .keep: return nil
        case .h2160: return 2160
        case .h1440: return 1440
        case .h1080: return 1080
        case .h720: return 720
        case .h480: return 480
        case .h360: return 360
        }
    }
}

public enum AudioBitrate: String, Codable, CaseIterable, Sendable {
    case b96, b128, b160, b192, b256, b320

    public var argument: String { String(rawValue.dropFirst()) + "k" }
}

// MARK: Chapters, SponsorBlock, subtitles, thumbnails

public enum ChapterSource: String, Codable, CaseIterable, Sendable {
    case youtube, comments, commentsIfMissing
}

public enum SponsorBlockMode: String, Codable, CaseIterable, Sendable {
    case off, mark, remove
}

public enum SponsorCategory: String, Codable, CaseIterable, Sendable {
    case sponsor, intro, outro, selfpromo, preview, filler, interaction
    case musicOfftopic = "music_offtopic"
    case poiHighlight = "poi_highlight"
    case chapter

    /// Highlights and community chapters can be marked but never cut out.
    public var removable: Bool { self != .poiHighlight && self != .chapter }
}

public enum SubtitleFormat: String, Codable, CaseIterable, Sendable {
    case best, srt, vtt, ass, lrc
}

public enum ThumbnailFormat: String, Codable, CaseIterable, Sendable {
    case original, jpg, png, webp
}

// MARK: Playlist, network, naming

public enum PlaylistMode: String, Codable, CaseIterable, Sendable {
    case auto, single, full
}

public enum CookieBrowser: String, Codable, CaseIterable, Sendable {
    case none, safari, chrome, firefox, brave, edge, chromium, opera, vivaldi
}

public enum FilenameTemplate: String, Codable, CaseIterable, Sendable {
    /// Phobos's names: the title plus the video's id, so two videos with the
    /// same title can never overwrite each other. Playlist video gets a list number.
    case guided
    case titleOnly, titleID, uploaderTitle, dateTitle, uploaderFolder, playlistFolder
    case artistTitle, musicLibrary
    case custom

    /// The template for a plain, single-video download.
    var template: String {
        switch self {
        case .guided: return "%(title).150B [%(id)s].%(ext)s"
        case .titleOnly: return "%(title)s.%(ext)s"
        case .titleID: return "%(title)s [%(id)s].%(ext)s"
        case .uploaderTitle: return "%(uploader)s - %(title)s.%(ext)s"
        case .dateTitle: return "%(upload_date>%Y-%m-%d)s - %(title)s.%(ext)s"
        case .uploaderFolder: return "%(uploader)s/%(title)s.%(ext)s"
        case .playlistFolder: return "%(playlist_title|Singles)s/%(playlist_index&{} - |)s%(title)s.%(ext)s"
        // meta_* fields are filled in by the music-tag rules; the fallbacks keep these working without them.
        case .artistTitle: return "%(meta_artist,artist,uploader)s - %(meta_title,track,title)s.%(ext)s"
        case .musicLibrary:
            return "%(meta_album_artist,album_artist,artist,uploader)s/%(meta_album,album,playlist_title,title)s/%(track_number,playlist_index&{:02d} |)s%(meta_title,track,title)s.%(ext)s"
        case .custom: return ""
        }
    }
}
