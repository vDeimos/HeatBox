import Foundation

/// A channel the person follows. Videos already seen are remembered, so
/// only later ones count as new.
public struct Channel: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var site: String
    /// The address of the channel's list of videos.
    public var link: String
    public var seen: [String]
    public var lastChecked: Date?
    /// The explained choice (a built-in preset id) used when new videos are downloaded.
    public var choiceID: String

    public init(id: UUID = UUID(), name: String, site: String, link: String, seen: [String] = [],
                lastChecked: Date? = nil, choiceID: String = PresetCatalog.compatibleID) {
        self.id = id
        self.name = name
        self.site = site
        self.link = link
        self.seen = seen
        self.lastChecked = lastChecked
        self.choiceID = choiceID
    }

    /// How many ids a channel remembers.
    public static let seenLimit = 600

    /// The entries of a feed this channel has not seen.
    public func fresh(in feed: Feed) -> [FeedEntry] {
        let known = Set(seen)
        return feed.entries.filter { !known.contains($0.id) }
    }

    /// Notes videos as seen, keeping the newest `seenLimit`.
    public mutating func markSeen(_ ids: [String]) {
        for id in ids where !seen.contains(id) { seen.append(id) }
        if seen.count > Self.seenLimit { seen = Array(seen.suffix(Self.seenLimit)) }
    }
}

public struct FeedEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let url: String
    public let duration: String
}

public struct Feed: Equatable, Sendable {
    public let title: String
    public let site: String
    public let entries: [FeedEntry]
}

public enum FeedOutcome: Equatable, Sendable {
    case feed(Feed)
    case failure(String)
}

/// Asking a channel what it has published lately. Planning, running and
/// reading are separate, as for a look-up. Nothing runs by itself: a check
/// happens only when the person presses Check now.
public enum Following {
    public static let defaultLimit = 30

    public static func plan(link: String, cookiesFile: String?, limit: Int = defaultLimit,
                            toolchain: YtdlpCommand.Toolchain) throws -> Probe.Plan {
        let target = link.trimmed
        guard Links.isWebLink(target) else { throw ProbeFailure.invalidLink(target) }
        var args = YtdlpCommand.baseArguments(toolchain)
        args += ["-J", "--flat-playlist", "--playlist-end", String(max(limit, 1)), "--no-warnings"]
        if let cookiesFile, !cookiesFile.isEmpty { args += ["--cookies", cookiesFile] }
        args += ["--", target]
        return Probe.Plan(executable: toolchain.ytdlp, environment: toolchain.environment, arguments: args)
    }

    public static func fetch(link: String, cookiesFile: String? = nil, limit: Int = defaultLimit, tools: ToolRegistry,
                             runner: ProcessRunner = ProcessRunner()) async -> FeedOutcome {
        guard let toolchain = YtdlpCommand.Toolchain(registry: tools) else { return .failure(Messages.noTool) }
        let plan: Probe.Plan
        do { plan = try Self.plan(link: link, cookiesFile: cookiesFile, limit: limit, toolchain: toolchain) } catch {
            return .failure((error as? ProbeFailure)?.message ?? Messages.unreadable)
        }
        guard let output = try? await runner.run(plan.processRequest) else { return .failure(Messages.noTool) }
        if Task.isCancelled || output.outcome.stopRequested { return .failure(Messages.lookupStopped) }
        return interpret(output: output.standardOutput, errors: output.standardError)
    }

    public static func interpret(output: String, errors: String) -> FeedOutcome {
        if let object = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any] {
            return parse(object).map(FeedOutcome.feed) ?? .failure(Messages.notAChannel)
        }
        let last = errors.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        let sentence = ErrorTranslator.friendly(last)
        return .failure(sentence.isEmpty ? Messages.unreadable : sentence)
    }

    /// Nil when the answer is not a list of videos at all, such as a single video.
    public static func parse(_ json: [String: Any]) -> Feed? {
        guard json["entries"] != nil else { return nil }
        let site = Naming.siteName(extractorKey: (json["extractor_key"] as? String) ?? "", domain: json["webpage_url_domain"] as? String)
        var title = (json["channel"] as? String) ?? (json["uploader"] as? String) ?? (json["title"] as? String) ?? Messages.followingChannelFallback
        for suffix in [" - Videos", " - Uploads"] where title.hasSuffix(suffix) { title = String(title.dropLast(suffix.count)) }
        var entries: [FeedEntry] = []
        collect(json["entries"], into: &entries)
        return Feed(title: Naming.clean(title, limit: 80), site: site, entries: entries)
    }

    private static func collect(_ value: Any?, into entries: inout [FeedEntry]) {
        for item in (value as? [Any]) ?? [] {
            guard let entry = item as? [String: Any] else { continue }
            // A tab inside a channel page: look through it too.
            if let nested = entry["entries"] { collect(nested, into: &entries); continue }
            guard let id = entry["id"] as? String, !id.isEmpty, !entries.contains(where: { $0.id == id }) else { continue }
            var url = (entry["url"] as? String) ?? (entry["webpage_url"] as? String) ?? ""
            if !Links.isWebLink(url) { url = "https://www.youtube.com/watch?v=\(id)" }
            let seconds = Probe.number(entry["duration"]) ?? 0
            entries.append(FeedEntry(id: id, title: (entry["title"] as? String) ?? Messages.untitled, url: url,
                                     duration: seconds > 0 ? TimeText.clock(seconds.rounded()) : ""))
        }
    }
}

/// The followed channels on disk (`following.json`, ADR-007).
public struct FollowStore: Sendable {
    public static let version = 1
    public let file: URL

    public init(file: URL) { self.file = file }
    public init(paths: AppPaths) { self.init(file: paths.followingFile) }

    private struct Envelope: Encodable { var version: Int; var channels: [Channel] }

    public func save(_ channels: [Channel]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Envelope(version: Self.version, channels: channels)).write(to: file, options: .atomic)
    }

    /// A missing file is no channels. A file that cannot be read is set aside, not written over.
    public func load() -> [Channel] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let entries = object["channels"] as? [Any] else {
            let aside = file.deletingLastPathComponent().appendingPathComponent("following.unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: file, to: aside)
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return entries.compactMap { entry in
            guard JSONSerialization.isValidJSONObject(entry), let data = try? JSONSerialization.data(withJSONObject: entry) else { return nil }
            return try? decoder.decode(Channel.self, from: data)
        }
    }

    /// What following a channel the first time does: everything published so
    /// far counts as seen, so only later videos are new.
    public static func newChannel(link: String, feed: Feed, now: Date) -> Channel {
        Channel(name: feed.title, site: feed.site, link: Links.channelVideosURL(link), seen: feed.entries.map(\.id), lastChecked: now)
    }
}
