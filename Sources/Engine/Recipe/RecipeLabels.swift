import Foundation

// The words the Customize panel shows for each choice a recipe is made of.
// They live here, with the choices, so every screen and every Mac says the
// same thing (plan Rule 7).

extension VideoCodecPreference {
    public var label: String {
        switch self {
        case .any: return "Any"
        case .h264: return "H.264 (plays everywhere)"
        case .h265: return "H.265 (HEVC)"
        case .vp9: return "VP9"
        case .av1: return "AV1"
        }
    }
}

extension AudioCodecPreference {
    public var label: String {
        switch self {
        case .any: return "Any"
        case .aac: return "AAC"
        case .opus: return "Opus"
        }
    }
}

extension FrameRateLimit {
    public var label: String {
        switch self {
        case .any: return "Any"
        case .fps60: return "Up to 60"
        case .fps30: return "Up to 30"
        case .fps24: return "Up to 24"
        }
    }
}

extension AudioFormat {
    public var label: String {
        switch self {
        case .best: return "Keep the original"
        case .mp3: return "MP3"
        case .m4a: return "M4A (AAC)"
        case .aac: return "AAC"
        case .opus: return "Opus"
        case .vorbis: return "Ogg Vorbis"
        case .flac: return "FLAC (lossless)"
        case .alac: return "ALAC (Apple Lossless)"
        case .wav: return "WAV (uncompressed)"
        }
    }
}

extension AudioQuality {
    public var label: String {
        switch self {
        case .standard: return "Standard"
        case .q0: return "Best (variable)"
        case .q2: return "High (variable)"
        case .q5: return "Medium (variable)"
        case .k320: return "320 kbps"
        case .k256: return "256 kbps"
        case .k192: return "192 kbps"
        case .k160: return "160 kbps"
        case .k128: return "128 kbps"
        case .k96: return "96 kbps"
        case .k64: return "64 kbps"
        }
    }
}

extension SampleRate {
    public var label: String {
        switch self {
        case .keep: return "Keep"
        case .r22050: return "22.05 kHz"
        case .r44100: return "44.1 kHz"
        case .r48000: return "48 kHz"
        case .r96000: return "96 kHz"
        }
    }
}

extension ChannelLayout {
    public var label: String {
        switch self {
        case .keep: return "Keep"
        case .mono: return "Mono"
        case .stereo: return "Stereo"
        }
    }
}

extension VideoEncoder {
    public var label: String {
        switch self {
        case .x264: return "H.264 (software)"
        case .x265: return "H.265 (software)"
        case .videoToolboxH264: return "H.264 (this Mac's hardware)"
        case .videoToolboxHEVC: return "H.265 (this Mac's hardware)"
        case .vp9: return "VP9"
        case .av1: return "AV1"
        case .prores: return "ProRes (for editing, very large)"
        }
    }
}

extension EncoderSpeed {
    public var label: String {
        switch self {
        case .ultrafast: return "Fastest"
        case .superfast: return "Much faster"
        case .veryfast: return "Faster"
        case .faster: return "A little faster"
        case .fast: return "Fast"
        case .medium: return "Balanced"
        case .slow: return "Slow"
        case .slower: return "Slower"
        case .veryslow: return "Slowest, smallest file"
        }
    }
}

extension ScaleHeight {
    public var label: String {
        guard let height else { return "Keep the size" }
        return "\(height)p"
    }
}

extension AudioBitrate {
    public var label: String { String(rawValue.dropFirst()) + " kbps" }
}

extension ChapterSource {
    public var label: String {
        switch self {
        case .youtube: return "The video's own"
        case .comments: return "A list in the comments"
        case .commentsIfMissing: return "The comments, when the video has none"
        }
    }
}

extension SponsorBlockMode {
    public var label: String {
        switch self {
        case .off: return "Off"
        case .mark: return "Mark as chapters"
        case .remove: return "Cut out"
        }
    }
}

extension SponsorCategory {
    public var label: String {
        switch self {
        case .sponsor: return "Sponsors"
        case .intro: return "Intros"
        case .outro: return "End cards and credits"
        case .selfpromo: return "Self-promotion"
        case .preview: return "Previews and recaps"
        case .filler: return "Filler and tangents"
        case .interaction: return "Reminders to like and subscribe"
        case .musicOfftopic: return "Non-music parts of music videos"
        case .poiHighlight: return "Highlight (mark only)"
        case .chapter: return "Community chapters (mark only)"
        }
    }
}

extension SubtitleFormat {
    public var label: String {
        switch self {
        case .best: return "As the site has them"
        case .srt: return "SRT"
        case .vtt: return "VTT"
        case .ass: return "ASS"
        case .lrc: return "LRC (lyrics)"
        }
    }
}

extension ThumbnailFormat {
    public var label: String {
        switch self {
        case .original: return "As the site has it"
        case .jpg: return "JPEG"
        case .png: return "PNG"
        case .webp: return "WebP"
        }
    }
}

extension CookieBrowser {
    public var label: String {
        switch self {
        case .none: return "None"
        case .safari: return "Safari"
        case .chrome: return "Chrome"
        case .firefox: return "Firefox"
        case .brave: return "Brave"
        case .edge: return "Edge"
        case .chromium: return "Chromium"
        case .opera: return "Opera"
        case .vivaldi: return "Vivaldi"
        }
    }
}

extension FilenameTemplate {
    public var label: String {
        switch self {
        case .guided: return "The name style from Settings"
        case .titleOnly: return "Title"
        case .titleID: return "Title [id]"
        case .uploaderTitle: return "Uploader - Title"
        case .dateTitle: return "Date - Title"
        case .uploaderFolder: return "A folder per uploader"
        case .playlistFolder: return "A folder per playlist, numbered"
        case .artistTitle: return "Artist - Song"
        case .musicLibrary: return "Artist / Album / Song"
        case .custom: return "My own template"
        }
    }
}
