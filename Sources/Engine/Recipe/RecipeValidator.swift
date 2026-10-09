import Foundation

public struct RecipeIssue: Equatable, Sendable {
    public enum Severity: Sendable { case error, warning }

    public let severity: Severity
    /// The recipe field the issue is about, for the UI to point at.
    public let field: String
    /// One plain sentence with a next step (plan Rule 7).
    public let message: String
}

/// Decides whether a recipe can be run, and warns about choices that will
/// not do what they appear to. An error stops the download; a warning does not.
public enum RecipeValidator {
    public static func validate(_ recipe: DownloadRecipe) -> [RecipeIssue] {
        var issues: [RecipeIssue] = []
        func error(_ field: String, _ message: String) { issues.append(RecipeIssue(severity: .error, field: field, message: message)) }
        func warning(_ field: String, _ message: String) { issues.append(RecipeIssue(severity: .warning, field: field, message: message)) }
        func check(_ field: String, _ name: String, _ value: Double, _ low: Double, _ high: Double) {
            if !(value >= low && value <= high) { error(field, Messages.recipeNumberOutOfRange(name, from: low, to: high)) }
        }

        // Re-encode: the container has to be able to hold what the encoder makes.
        if recipe.encodeEnabled {
            if recipe.mode == .audio {
                warning("encodeEnabled", Messages.recipeEncodeIgnoredForAudio)
            } else if recipe.container == .automatic {
                error("container", Messages.recipeEncodeNeedsContainer)
            } else if !recipe.encoder.compatibleContainers.contains(recipe.container) {
                let suggested = recipe.encoder.compatibleContainers.first?.rawValue.uppercased() ?? "MKV"
                error("container", Messages.recipeEncoderContainer(encoder: recipe.encoder.rawValue,
                                                                   container: recipe.container.rawValue.uppercased(),
                                                                   suggested: suggested))
            }
            if recipe.encoder.usesQualityFactor {
                check("qualityFactor", "Quality factor", recipe.qualityFactor, 0, recipe.encoder.maxQualityFactor)
            }
            if recipe.encoder.usesBitrate { check("hardwareBitrateMbps", "Bitrate", recipe.hardwareBitrateMbps, 0.1, 100) }
        }

        // Ranges
        check("gainDB", "Volume change", recipe.gainDB, -40, 40)
        check("concurrentFragments", "Parallel pieces", Double(recipe.concurrentFragments), 1, 16)
        check("retries", "Retries", Double(recipe.retries), 0, 100)
        check("sleepInterval", "Pause between downloads", Double(recipe.sleepInterval), 0, 3600)
        check("maxSleepInterval", "Longest pause between downloads", Double(recipe.maxSleepInterval), 0, 3600)
        check("subtitleSleep", "Pause between subtitle requests", Double(recipe.subtitleSleep), 0, 600)
        if recipe.maxSleepInterval != 0 && (recipe.sleepInterval == 0 || recipe.maxSleepInterval < recipe.sleepInterval) {
            // The tool wants a shortest pause before it accepts a longest one.
            error("maxSleepInterval", Messages.recipeNumberOutOfRange("Longest pause between downloads", from: Double(max(recipe.sleepInterval, 1)), to: 3600))
        }

        // Part of a video
        if let clip = recipe.clip {
            let validStart = clip.start.isFinite && clip.start >= 0
            let validEnd = clip.end.map { $0.isFinite && $0 > clip.start } ?? true
            if !validStart || !validEnd { error("clip", Messages.recipeClipOrder) }
            if recipe.splitChapters { error("splitChapters", Messages.recipeClipWithChapters) }
        }

        // Playlist and network
        let items = recipe.playlistItems.trimmed
        if !items.isEmpty && !isPlaylistItemSpec(items) { error("playlistItems", Messages.recipePlaylistItems) }
        let rate = recipe.rateLimit.trimmed
        if !rate.isEmpty && rate.range(of: #"^\d+(\.\d+)?[KkMmGg]?$"#, options: .regularExpression) == nil {
            error("rateLimit", Messages.recipeRateLimit)
        }
        let proxy = recipe.proxy.trimmed
        if !proxy.isEmpty && proxy.range(of: #"^(?i)(https?|socks4a?|socks5h?)://\S+$"#, options: .regularExpression) == nil {
            error("proxy", Messages.recipeProxy)
        }
        if recipe.cookieBrowser != .none { warning("cookieBrowser", Messages.recipeCookiesBrowser) }

        // Chapters, SponsorBlock, subtitles
        if recipe.sponsorBlock != .off {
            if recipe.sponsorCategories.isEmpty {
                error("sponsorCategories", Messages.recipeSponsorCategories)
            } else if recipe.sponsorBlock == .remove && !recipe.sponsorCategories.contains(where: \.removable) {
                error("sponsorCategories", Messages.recipeSponsorNotRemovable)
            }
        }
        if (recipe.writeSubtitles || recipe.writeAutoSubtitles || recipe.embedSubtitles)
            && recipe.subtitleLanguages.trimmed.isEmpty {
            error("subtitleLanguages", Messages.recipeSubtitleLanguages)
        }
        if recipe.embedSubtitles && recipe.mode != .audio && recipe.container != .automatic
            && !recipe.container.supportsSubtitleEmbed {
            warning("embedSubtitles", Messages.recipeSubtitleContainer)
        }

        // Audio and thumbnails
        if recipe.evenLoudness && recipe.mode != .audio { warning("evenLoudness", Messages.recipeLoudnessAudioOnly) }
        // With the volume evened out the sound is written again anyway, and the changes are made then.
        if recipe.mode == .audio && recipe.audioFormat == .best && recipe.audioFiltersActive && !recipe.evenLoudness {
            warning("audioFormat", Messages.recipeAudioFiltersIgnored)
        }
        if recipe.embedThumbnail && !recipe.thumbnailEmbeddable {
            warning("embedThumbnail", Messages.recipeThumbnailContainer)
        }

        // Naming
        if recipe.filenameTemplate == .custom {
            let template = recipe.customTemplate.trimmed
            if template.isEmpty {
                error("customTemplate", Messages.recipeTemplateEmpty)
            } else if !template.contains("%(ext)s") {
                error("customTemplate", Messages.recipeTemplateExtension)
            } else if escapesFolder(template) {
                error("customTemplate", Messages.recipeTemplateEscapes)
            }
        }

        // Extra arguments
        // One sentence is enough: the first refused word stops the recipe, and the rest follow from it.
        for problem in ExtraArgsPolicy.check(recipe.extraArguments).problems.prefix(1) {
            error("extraArguments", Messages.recipeExtraArguments(problem))
        }
        return issues
    }

    public static func errors(in recipe: DownloadRecipe) -> [RecipeIssue] {
        validate(recipe).filter { $0.severity == .error }
    }

    /// True when a file name template could point outside the download folder:
    /// an absolute path, a `..` step, or a `~` or `$` that yt-dlp expands to a
    /// home folder or an environment variable.
    static func escapesFolder(_ template: String) -> Bool {
        if template.hasPrefix("/") || template.contains("$") || template.contains("~") { return true }
        return template.split(separator: "/").contains("..")
    }

    /// yt-dlp's `--playlist-items` syntax: numbers, `start:stop:step` ranges
    /// and `start-stop` ranges, separated by commas.
    static func isPlaylistItemSpec(_ text: String) -> Bool {
        let part = #"-?\d*(?::-?\d*(?::-?\d+)?)?|\d+-\d+"#
        let pattern = "^(?:\(part))(?:\\s*,\\s*(?:\(part)))*$"
        guard text.range(of: pattern, options: .regularExpression) != nil else { return false }
        // An empty piece between commas matches `part`, so reject those here.
        return !text.components(separatedBy: ",").contains { $0.trimmed.isEmpty }
    }
}
