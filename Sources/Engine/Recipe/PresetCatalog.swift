import Foundation

/// The built-in presets: Phobos's explained choices as the guided group, and
/// Studio's nine as the advanced group (plan Section 3.4).
public enum PresetCatalog {
    /// The heights Phobos offers as "Up to N p" (a tier below 360 is not worth a choice).
    public static let resolutionTiers = [2160, 1440, 1080, 720, 480, 360]

    public static let bestID = "best"
    public static let compatibleID = "compatible"
    public static let audioID = "audio"

    public static func resolutionID(_ height: Int) -> String { "res\(height)" }

    // MARK: Guided (Phobos)

    public static var best: Preset {
        Preset(id: bestID, name: "Best available", group: .guided, recipe: DownloadRecipe())
    }

    /// Standard MP4 with H.264 and AAC, which QuickTime, iPhones and TVs open.
    public static var playsEverywhere: Preset {
        var recipe = DownloadRecipe()
        recipe.container = .mp4
        recipe.videoCodec = .h264
        recipe.audioCodec = .aac
        return Preset(id: compatibleID, name: "Plays everywhere", group: .guided, recipe: recipe)
    }

    /// The best version no taller than `height`.
    public static func upTo(height: Int) -> Preset? {
        guard let tier = MaxResolution(height: height) else { return nil }
        var recipe = DownloadRecipe()
        recipe.maxResolution = tier
        return Preset(id: resolutionID(height), name: "Up to \(height)p", group: .guided, recipe: recipe)
    }

    /// Just the sound, as M4A, with cover art and music tags.
    public static var audioOnly: Preset {
        var recipe = DownloadRecipe()
        recipe.mode = .audio
        recipe.audioFormat = .m4a
        recipe.audioQuality = .standard
        recipe.embedThumbnail = true
        return Preset(id: audioID, name: "Audio only", group: .guided, recipe: recipe)
    }

    public static var guided: [Preset] {
        [best, playsEverywhere] + resolutionTiers.compactMap(upTo(height:)) + [audioOnly]
    }

    // MARK: Advanced (Studio)

    public static var advanced: [Preset] {
        func make(_ id: String, _ name: String, _ edit: (inout DownloadRecipe) -> Void) -> Preset {
            var recipe = DownloadRecipe.studioDefaults
            edit(&recipe)
            return Preset(id: "studio.\(id)", name: name, group: .advanced, recipe: recipe)
        }
        return [
            make("best-mkv", "Best quality (MKV)") { r in
                r.container = .mkv
                r.preferCompatibleStreams = false
            },
            make("compatible-1080", "Compatible MP4 · H.264 · 1080p") { r in
                r.container = .mp4
                r.maxResolution = .p1080
                r.videoCodec = .h264
                r.audioCodec = .aac
            },
            make("mp3-320", "MP3 320 kbps") { r in
                r.mode = .audio
                r.audioFormat = .mp3
                r.audioQuality = .k320
            },
            make("flac", "Lossless FLAC") { r in
                r.mode = .audio
                r.audioFormat = .flac
            },
            make("podcast", "Podcast · Opus mono, normalized") { r in
                r.mode = .audio
                r.audioFormat = .opus
                r.audioQuality = .k64
                r.channels = .mono
                r.evenLoudness = true
            },
            make("album-split", "Album · split chapters to MP3") { r in
                r.mode = .audio
                r.audioFormat = .mp3
                r.audioQuality = .q0
                r.splitChapters = true
                r.chaptersInFolder = true
            },
            make("ad-free", "Ad-free · SponsorBlock cut") { r in
                r.sponsorBlock = .remove
                r.sponsorCategories = [.sponsor, .selfpromo, .interaction, .intro, .outro]
            },
            make("shrink-720", "Shrink for sharing · HEVC 720p") { r in
                r.maxResolution = .p1080
                r.encodeEnabled = true
                r.encoder = .videoToolboxHEVC
                r.hardwareBitrateMbps = 2.5
                r.scale = .h720
                r.encodeAudioBitrate = .b128
            },
            make("archive", "Archive everything") { r in
                r.container = .mkv
                r.preferCompatibleStreams = false
                r.writeSubtitles = true
                r.subtitleLanguages = "all,-live_chat"
                r.subtitleFormat = .best
                r.embedSubtitles = true
                r.writeInfoJSON = true
                r.writeDescription = true
                r.writeThumbnail = true
                r.useArchive = true
                r.filenameTemplate = .uploaderFolder
            },
        ]
    }

    public static var all: [Preset] { guided + advanced }

    public static func preset(id: String) -> Preset? { all.first { $0.id == id } }
}

extension DownloadRecipe {
    /// What Phobos adds for a playlist or a channel: every item, carry on past
    /// a failure, and a short pause between items so the site is not hammered.
    /// A recipe that names its own pause keeps it.
    public func forPlaylist() -> DownloadRecipe {
        var recipe = self
        recipe.playlistMode = .full
        recipe.continueOnErrors = true
        if recipe.sleepInterval == 0 && recipe.maxSleepInterval == 0 {
            recipe.sleepInterval = 1
            recipe.maxSleepInterval = 4
        }
        return recipe
    }

    /// What Phobos asks for subtitles: embedded in the video, the main
    /// language plus English, proper ones first and automatic captions where
    /// there are none, and no loose files left behind.
    public func withSubtitles(language: String = "en") -> DownloadRecipe {
        var recipe = self
        recipe.writeSubtitles = true
        recipe.writeAutoSubtitles = true
        recipe.embedSubtitles = true
        recipe.keepSubtitleFiles = false
        recipe.subtitleFormat = .best
        recipe.subtitleLanguages = language == "en" ? "en" : "\(language),en"
        recipe.subtitleSleep = 2
        return recipe
    }

    /// Phobos's "skip the sponsor segments": cut the sponsor category, exactly.
    public func cuttingSponsors() -> DownloadRecipe {
        var recipe = self
        recipe.sponsorBlock = .remove
        recipe.sponsorCategories = [.sponsor]
        recipe.exactCut = true
        return recipe
    }
}
