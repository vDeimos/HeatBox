import Foundation

/// Brings YT-DLP Studio's saved settings over (Phase 7). It is given what
/// Studio stored (its two JSON values and two tool paths) and returns new
/// values; it never touches Studio's data, which the app reads from a copy
/// held in memory.
public enum StudioImporter {
    /// What Studio stored. All of it optional: a Mac that never ran Studio has none.
    public struct Source: Equatable, Sendable {
        public var currentOptions: Data?
        public var userPresets: Data?
        public var ytdlpOverride: String?
        public var ffmpegOverride: String?

        public init(currentOptions: Data? = nil, userPresets: Data? = nil, ytdlpOverride: String? = nil, ffmpegOverride: String? = nil) {
            self.currentOptions = currentOptions
            self.userPresets = userPresets
            self.ytdlpOverride = ytdlpOverride
            self.ffmpegOverride = ffmpegOverride
        }

        public var isEmpty: Bool { self == Source() }
    }

    public struct Result: Equatable, Sendable {
        /// The saved options as a preset, if there were any.
        public var defaultsPreset: Preset?
        public var presets: [Preset] = []
        public var toolPaths: [Tool: String] = [:]
        /// One sentence per thing that could not come over as it was.
        public var notes: [String] = []
    }

    /// The name of the preset made from Studio's last-used options.
    public static let defaultsName = "Studio defaults"

    /// Studio's option names that are called something else here.
    private static let renamed: [String: String] = [
        "fpsLimit": "frameRateLimit", "normalizeAudio": "evenLoudness", "volumeDB": "gainDB", "crf": "qualityFactor",
        "preset": "encoderSpeed", "hwBitrateMbps": "hardwareBitrateMbps", "writeSubs": "writeSubtitles",
        "writeAutoSubs": "writeAutoSubtitles", "subLangs": "subtitleLanguages", "subFormat": "subtitleFormat",
        "embedSubs": "embedSubtitles", "sponsorBlockMode": "sponsorBlock", "removeChaptersRegex": "removeChaptersPattern",
        "preciseCuts": "exactCut", "trackNumbers": "trackNumbersFromPlaylist", "extraArgs": "extraArguments",
    ]

    /// Studio's option set as a recipe. Fields that no longer exist are left
    /// behind, and a note says so for the two that carry something a person wrote.
    public static func recipe(fromOptions saved: [String: Any], notes: inout [String], context: String) -> DownloadRecipe {
        var fields: [String: Any] = [:]
        for (key, value) in saved { fields[renamed[key] ?? key] = value }
        // The output folder is the job's, not the recipe's.
        fields["outputDirectory"] = nil
        if let ppa = saved["customPPA"] as? String, !ppa.trimmed.isEmpty {
            notes.append(Messages.importPostprocessorArgs(context))
        }
        if (saved["trimEnabled"] as? Bool) == true {
            let start = (saved["trimStart"] as? String).flatMap(TimeText.seconds(from:)) ?? 0
            let end = (saved["trimEnd"] as? String).flatMap(TimeText.seconds(from:))
            var clip: [String: Any] = ["start": start]
            if let end, end > start { clip["end"] = end }
            fields["clip"] = clip
        }
        if let container = saved["container"] as? String, ["avi", "flv"].contains(container) {
            notes.append(Messages.importLegacyContainer(context, container.uppercased()))
            fields["container"] = nil
        }
        var recipe = DownloadRecipe.studioDefaults.overlaid(with: fields)
        if !recipe.extraArguments.trimmed.isEmpty, !ExtraArgsPolicy.check(recipe.extraArguments).isAllowed {
            notes.append(Messages.importExtraArgumentsRefused(context))
            recipe.extraArguments = ""
        }
        return recipe
    }

    public static func importSettings(_ source: Source, isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> Result {
        var result = Result()
        if let data = source.currentOptions, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let recipe = recipe(fromOptions: object, notes: &result.notes, context: defaultsName)
            result.defaultsPreset = Preset(id: "imported.studio.defaults", name: defaultsName, group: .user, recipe: recipe)
        }
        if let data = source.userPresets, let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            for entry in list {
                guard let name = (entry["name"] as? String)?.trimmed, !name.isEmpty,
                      let options = entry["options"] as? [String: Any] else { continue }
                let key = (entry["id"] as? String) ?? name
                let recipe = recipe(fromOptions: options, notes: &result.notes, context: name)
                result.presets.append(Preset(id: "imported.studio.\(key.lowercased())", name: name, group: .user, recipe: recipe))
            }
        }
        for (tool, path) in [(Tool.ytdlp, source.ytdlpOverride), (Tool.ffmpeg, source.ffmpegOverride)] {
            let expanded = ((path ?? "") as NSString).expandingTildeInPath
            if !expanded.isEmpty, expanded.hasPrefix("/"), isExecutable(expanded) { result.toolPaths[tool] = expanded }
        }
        return result
    }
}
