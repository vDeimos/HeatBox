import Foundation

/// What happens when a download finishes.
public enum FinishAction: String, CaseIterable, Codable, Sendable {
    case notifyOnly, notifyAndOffer, playNow
}

/// Dark, light, or whatever the Mac is set to. The app turns it into colours.
public enum ThemeChoice: String, CaseIterable, Codable, Sendable {
    case dark, light, system
}

/// The stored names are Phobos's, so its saved settings can be imported
/// unchanged (Phase 7). Ember is HeatBox's own.
public enum AccentChoice: String, CaseIterable, Codable, Sendable {
    case ember, blue, peach, green, pink, mauve, teal
}

/// Everything the Settings window remembers. These are defaults (plan Rule
/// 6): a download starts from them, and what is changed for one download is
/// not written back.
public struct AppSettings: Codable, Equatable, Sendable {
    public var folders = FolderRules.standard()
    public var nameStyle = NameStyle.title
    /// How many downloads may run at once (1 to 4).
    public var maxConcurrent = 2
    public var autoRetry = true
    /// Kilobytes per second; 0 means no limit.
    public var speedLimitKB = 0
    public var finish = FinishAction.notifyAndOffer
    /// Include subtitles in videos that have them.
    public var subtitles = false
    /// Use the video's picture as the file's cover image.
    public var coverImage = false
    public var cutSponsors = false
    /// Even out the volume of audio downloads.
    public var evenLoudness = false
    /// Cut a clip at the exact times instead of the nearest keyframes.
    public var exactCut = true
    public var theme = ThemeChoice.system
    public var accent = AccentChoice.ember
    public var largeText = false
    /// The version picked last time, marked on the Download screen.
    public var lastChoiceID: String?
    /// Sites downloaded from so far, each of which can be given its own folder.
    public var knownSites: [String] = []
    /// Tool name (`Tool.rawValue`) -> the full path the person chose for it.
    public var toolPaths: [String: String] = [:]
    /// Search the Library by the words spoken in each video.
    public var spokenSearch = false
    /// Listen to videos that have no captions, on this Mac.
    public var transcribeLocally = true
    /// Hand the saved YouTube sign-in to the download tool.
    public var useSignIn = false
    /// The browser the sign-in is copied from.
    public var signInBrowser = CookieBrowser.firefox
    /// The first-launch tour has been shown.
    public var tourSeen = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case folders, nameStyle, maxConcurrent, autoRetry, speedLimitKB, finish, subtitles, coverImage
        case cutSponsors, evenLoudness, exactCut, theme, accent, largeText, lastChoiceID, knownSites, toolPaths
        case spokenSearch, transcribeLocally, useSignIn, signInBrowser, tourSeen
    }

    /// Settings saved by another version keep what still fits: a missing
    /// field, or one whose value no longer makes sense, takes its default
    /// without resetting the rest.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        let standard = AppSettings()
        // A saved file is an install that already exists, so folders it
        // does not name are the ones it has been using.
        folders = read(.folders, FolderRules.legacy())
        nameStyle = read(.nameStyle, standard.nameStyle)
        maxConcurrent = read(.maxConcurrent, standard.maxConcurrent)
        autoRetry = read(.autoRetry, standard.autoRetry)
        speedLimitKB = read(.speedLimitKB, standard.speedLimitKB)
        finish = read(.finish, standard.finish)
        subtitles = read(.subtitles, standard.subtitles)
        coverImage = read(.coverImage, standard.coverImage)
        cutSponsors = read(.cutSponsors, standard.cutSponsors)
        evenLoudness = read(.evenLoudness, standard.evenLoudness)
        exactCut = read(.exactCut, standard.exactCut)
        // As with the folders: a saved file without a theme had the earlier one.
        theme = read(.theme, .dark)
        // As with the folders: a saved file without an accent had the earlier one.
        accent = read(.accent, .blue)
        largeText = read(.largeText, standard.largeText)
        lastChoiceID = try? c.decodeIfPresent(String.self, forKey: .lastChoiceID)
        knownSites = read(.knownSites, standard.knownSites)
        toolPaths = read(.toolPaths, standard.toolPaths)
        spokenSearch = read(.spokenSearch, standard.spokenSearch)
        transcribeLocally = read(.transcribeLocally, standard.transcribeLocally)
        useSignIn = read(.useSignIn, standard.useSignIn)
        let browser = read(.signInBrowser, standard.signInBrowser)
        signInBrowser = SignIn.browsers.contains(browser) ? browser : standard.signInBrowser
        tourSeen = read(.tourSeen, standard.tourSeen)
    }

    /// What the spoken-word indexer is given. `languageCode` is the Mac's own language.
    public func spokenSettings(cookiesFile: String?, languageCode: String?) -> SpokenSettings {
        SpokenSettings(enabled: spokenSearch, listen: transcribeLocally, cookiesFile: cookiesFile,
                       languages: Captions.languages(for: languageCode))
    }

    // MARK: What the engine is given

    /// The paths chosen in Settings, for `ToolRegistry`.
    public var toolOverrides: [Tool: String] {
        var result: [Tool: String] = [:]
        for tool in Tool.allCases {
            if let path = toolPaths[tool.rawValue], !path.trimmed.isEmpty { result[tool] = path }
        }
        return result
    }

    public mutating func setOverride(_ path: String?, for tool: Tool) {
        let trimmed = path?.trimmed ?? ""
        toolPaths[tool.rawValue] = trimmed.isEmpty ? nil : trimmed
    }

    public func registry(paths: AppPaths) -> ToolRegistry {
        ToolRegistry(managedFolder: paths.bin.path, overrides: toolOverrides)
    }

    public func queueSettings(cookiesFile: String? = nil) -> QueueSettings {
        var settings = QueueSettings(folders: folders)
        let range = QueueSettings.concurrencyRange
        settings.maxConcurrent = min(max(maxConcurrent, range.lowerBound), range.upperBound)
        settings.autoRetry = autoRetry
        settings.speedLimitKB = max(speedLimitKB, 0)
        settings.nameStyle = nameStyle
        settings.cookiesFile = cookiesFile
        return settings
    }

    /// Notes a site that was downloaded from, so Settings can offer it a folder.
    /// Returns true when it was new.
    @discardableResult
    public mutating func remember(site: String) -> Bool {
        let name = site.trimmed
        guard !name.isEmpty, !knownSites.contains(name) else { return false }
        knownSites.append(name)
        knownSites.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return true
    }
}

/// The settings on disk (`settings.json`). The file has a version
/// number, and a field that cannot be read takes its default.
public struct SettingsStore: Sendable {
    public static let version = 1

    public let file: URL
    /// Files whose presence means the app has been used here before.
    private let earlier: [URL]

    public init(file: URL) {
        self.file = file
        earlier = []
    }

    public init(paths: AppPaths) {
        file = paths.settingsFile
        earlier = [paths.libraryDatabase, paths.queueFile, paths.presetsFile, paths.followingFile, paths.importRecord]
    }

    private struct Envelope: Codable {
        var version: Int
        var settings: AppSettings
    }

    public static func encode(_ settings: AppSettings) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Envelope(version: version, settings: settings))
    }

    /// Nil when the data is not a settings file at all.
    public static func decode(_ data: Data) -> AppSettings? {
        (try? JSONDecoder().decode(Envelope.self, from: data))?.settings
    }

    public func save(_ settings: AppSettings) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Self.encode(settings).write(to: file, options: .atomic)
    }

    /// The saved settings. A missing file gives the defaults. A file that
    /// cannot be read is set aside as `settings.unreadable.json` instead of
    /// being written over, and the defaults are used.
    public func load() -> AppSettings {
        let aside = file.deletingLastPathComponent().appendingPathComponent("settings.unreadable.json")
        guard let data = try? Data(contentsOf: file) else {
            return defaults(usedBefore: (earlier + [aside]).contains { FileManager.default.fileExists(atPath: $0.path) })
        }
        guard let settings = Self.decode(data) else {
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: file, to: aside)
            return defaults(usedBefore: true)
        }
        return settings
    }

    /// An install from before the app was called HeatBox keeps the folders,
    /// the theme and the accent it had by default; only a new one gets
    /// HeatBox's.
    private func defaults(usedBefore: Bool) -> AppSettings {
        var settings = AppSettings()
        if usedBefore {
            settings.folders = .legacy()
            settings.theme = .dark
            settings.accent = .blue
        }
        return settings
    }

    /// Writes the settings in use when none are saved yet, so the defaults a
    /// new install started with stay its own once it has other files.
    public func keep(_ settings: AppSettings) {
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        try? save(settings)
    }
}
