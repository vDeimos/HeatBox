import Foundation

/// The one-time move from the older apps (Phase 7). It reads what Phobos and
/// YT-DLP Studio stored, never writes to either, and adds what it found to
/// this app's own stores. It can be run again safely: a download already in
/// the Library, a channel already followed and a preset already saved are
/// not added twice, and the person's own changes to them are kept.
public enum Migration {
    public struct Summary: Codable, Equatable, Sendable {
        public var records = 0
        public var channels = 0
        public var presets = 0
        public var settings = false
        public var transcripts = false
        public var notes: [String] = []
        public var isEmpty: Bool { records == 0 && channels == 0 && presets == 0 && !settings && !transcripts }
        public var sentence: String {
            Messages.importSummary(records: records, channels: channels, presets: presets, settings: settings)
        }
    }

    /// Reads a stored value of another app. `domain` is the app's preferences domain.
    public typealias DefaultsReader = @Sendable (_ domain: String, _ key: String) -> Data?

    public static let phobosDomains = ["local.phobos.Phobos", "local.deimos.phobos"]
    public static let studioDomain = "com.local.ytdlpstudio"

    /// Reading another app's preferences: only ever a read.
    public static let systemDefaults: DefaultsReader = { domain, key in
        UserDefaults(suiteName: domain)?.data(forKey: key)
    }

    public static func phobosSupportFolder(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Phobos", isDirectory: true)
    }

    public static func studioSource(defaults: DefaultsReader = systemDefaults) -> StudioImporter.Source {
        return StudioImporter.Source(currentOptions: defaults(studioDomain, "currentOptions.v1"),
                                     userPresets: defaults(studioDomain, "userPresets.v1"),
                                     ytdlpOverride: UserDefaults(suiteName: studioDomain)?.string(forKey: "ytdlpOverride"),
                                     ffmpegOverride: UserDefaults(suiteName: studioDomain)?.string(forKey: "ffmpegOverride"))
    }

    /// Looks for the older apps' data and brings it over, once. Returns nil
    /// when it has already run or there was nothing to bring.
    @discardableResult
    public static func runOnce(paths: AppPaths, library: LibraryRepository, phobosFolder: URL = phobosSupportFolder(),
                               defaults: DefaultsReader = systemDefaults, studio: StudioImporter.Source? = nil,
                               isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) async -> Summary? {
        if FileManager.default.fileExists(atPath: paths.importRecord.path) { return nil }
        var preferences: Data?
        for domain in phobosDomains where preferences == nil { preferences = defaults(domain, "settings.v2") }
        let phobos = PhobosImporter.read(supportFolder: phobosFolder, preferences: preferences)
        let studioSource = studio ?? studioSource(defaults: defaults)
        let studioResult = StudioImporter.importSettings(studioSource, isExecutable: isExecutable)
        var summary = await apply(phobos: phobos, studio: studioResult, paths: paths, library: library)
        summary.notes = phobos.notes + studioResult.notes
        guard !summary.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(summary) {
            try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? data.write(to: paths.importRecord, options: .atomic)
        }
        return summary
    }

    /// What was brought over the last time, for the app to say so.
    public static func lastSummary(paths: AppPaths) -> Summary? {
        (try? Data(contentsOf: paths.importRecord)).flatMap { try? JSONDecoder().decode(Summary.self, from: $0) }
    }

    public static func apply(phobos: PhobosImporter.Result, studio: StudioImporter.Result, paths: AppPaths,
                             library: LibraryRepository) async -> Summary {
        var summary = Summary()
        let fm = FileManager.default

        // Downloads. A record already here (same id) is left as it is.
        var fresh: [LibraryRecord] = []
        for var record in phobos.records where await library.record(record.id) == nil {
            if let picture = phobos.pictures[record.id] { record.thumbnail = library.storeThumbnail(from: picture, moving: false) }
            fresh.append(record)
        }
        await library.add(fresh)
        summary.records = fresh.count

        // Channels, by address.
        if !phobos.channels.isEmpty {
            let store = FollowStore(paths: paths)
            var channels = store.load()
            let known = Set(channels.map(\.link))
            let added = phobos.channels.filter { !known.contains($0.link) }
            channels += added
            if !added.isEmpty, (try? store.save(channels)) != nil { summary.channels = added.count }
        }

        // Presets, by id.
        let incoming = (studio.defaultsPreset.map { [$0] } ?? []) + studio.presets
        if !incoming.isEmpty {
            let store = PresetStore(paths: paths)
            var presets = store.load()
            let known = Set(presets.map(\.id))
            let added = incoming.filter { !known.contains($0.id) }
            presets += added
            if !added.isEmpty, (try? store.save(presets)) != nil { summary.presets = added.count }
        }

        // Settings: only when the person has not set any here yet.
        if !fm.fileExists(atPath: paths.settingsFile.path) {
            var settings = phobos.settings ?? AppSettings()
            for (tool, path) in studio.toolPaths { settings.setOverride(path, for: tool) }
            if phobos.settings != nil || !studio.toolPaths.isEmpty, (try? SettingsStore(paths: paths).save(settings)) != nil {
                summary.settings = true
            }
        }

        // Spoken-word index: kept for the search that arrives in Phase 9. The ids match, because records keep Phobos's.
        if let source = phobos.transcriptDatabase, !fm.fileExists(atPath: paths.transcriptsDatabase.path) {
            try? fm.createDirectory(at: paths.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if (try? fm.copyItem(at: source, to: paths.transcriptsDatabase)) != nil { summary.transcripts = true }
        }
        return summary
    }
}
