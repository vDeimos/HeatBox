import Foundation

/// One unfinished job as it is written to disk.
public struct SavedJob: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case waiting, running, paused, scheduled, retrying
    }

    public var id: UUID
    public var createdAt: Date
    public var source: JobSource
    public var link: String
    public var recipe: DownloadRecipe
    public var label: String
    public var title: String
    public var site: String
    public var facts: VideoFacts?
    public var duration: String
    public var itemCount: Int?
    public var folder: String?
    public var chapterComment: String?
    public var state: State
    /// When a scheduled or retrying job is due.
    public var startAfter: Date?
    public var attempt: Int
    public var startedAt: Date?
    public var files: [String]

    public init(_ job: Job) {
        id = job.id
        createdAt = job.createdAt
        source = job.source
        link = job.link
        recipe = job.recipe
        label = job.label
        title = job.title
        site = job.site
        facts = job.facts
        duration = job.duration
        itemCount = job.itemCount
        folder = job.folder
        chapterComment = job.chapterComment
        switch job.state {
        case .scheduled: state = .scheduled
        case .retrying: state = .retrying
        case .paused: state = .paused
        case .lookingUp, .running: state = .running
        default: state = .waiting
        }
        startAfter = job.state.due
        attempt = job.attempt
        startedAt = job.startedAt
        files = job.files
    }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, source, link, recipe, label, title, site, facts, duration, itemCount, folder, chapterComment
        case state, startAfter, attempt, startedAt, files
    }

    /// A job saved by another version keeps what still fits: only the id and
    /// the link are needed, and the recipe is read leniently (see `DownloadRecipe.lenient`).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        link = try c.decode(String.self, forKey: .link)
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date(timeIntervalSince1970: 0)
        source = (try? c.decode(JobSource.self, forKey: .source)) ?? .link
        if case .object(let fields)? = try? c.decode(JSONValue.self, forKey: .recipe) {
            recipe = DownloadRecipe.lenient(from: fields.mapValues(\.foundationValue))
        } else {
            recipe = DownloadRecipe()
        }
        label = (try? c.decode(String.self, forKey: .label)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? link
        site = (try? c.decode(String.self, forKey: .site)) ?? ""
        facts = try? c.decode(VideoFacts.self, forKey: .facts)
        duration = (try? c.decode(String.self, forKey: .duration)) ?? ""
        itemCount = try? c.decode(Int.self, forKey: .itemCount)
        folder = try? c.decode(String.self, forKey: .folder)
        chapterComment = try? c.decode(String.self, forKey: .chapterComment)
        state = (try? c.decode(State.self, forKey: .state)) ?? .paused
        startAfter = try? c.decode(Date.self, forKey: .startAfter)
        attempt = (try? c.decode(Int.self, forKey: .attempt)) ?? 0
        startedAt = try? c.decode(Date.self, forKey: .startedAt)
        files = (try? c.decode([String].self, forKey: .files)) ?? []
    }

    /// The job as it comes back after a restart. Nothing starts by itself:
    /// only a download the person scheduled for a time that has not come yet
    /// stays scheduled. Everything else comes back paused and waits for Resume.
    public func restored(now: Date) -> Job {
        let resolution = JobResolution(source: source, link: link, title: title, site: site, facts: facts,
                                       duration: duration, itemCount: itemCount)
        var job = Job(id: id, createdAt: createdAt,
                      request: JobRequest(resolution: resolution, recipe: recipe, label: label, folder: folder,
                                          chapterComment: chapterComment))
        job.attempt = attempt
        job.startedAt = startedAt
        job.files = files
        if state == .scheduled, let when = startAfter {
            if when > now {
                job.state = .scheduled(when)
            } else {
                job.state = .paused
                job.message = Messages.missedSchedule
            }
        } else {
            job.state = .paused
            job.message = Messages.pausedBecauseClosed
        }
        return job
    }
}

/// The unfinished jobs on disk (`queue.json`), so the queue survives
/// a restart. The file has a version number; an entry that cannot be read is
/// skipped without losing the others.
public struct QueueStore: Sendable {
    public static let version = 1

    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    public init(paths: AppPaths) {
        self.init(file: paths.queueFile)
    }

    private struct Envelope: Encodable {
        var version: Int
        var jobs: [SavedJob]
    }

    public static func encode(_ jobs: [SavedJob]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Envelope(version: version, jobs: jobs))
    }

    /// Nil when the data is not a queue file at all.
    public static func decode(_ data: Data) -> [SavedJob]? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = object["jobs"] as? [Any] else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return entries.compactMap { entry in
            guard JSONSerialization.isValidJSONObject(entry), let data = try? JSONSerialization.data(withJSONObject: entry) else { return nil }
            return try? decoder.decode(SavedJob.self, from: data)
        }
    }

    public func save(_ jobs: [SavedJob]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Self.encode(jobs).write(to: file, options: .atomic)
    }

    /// The saved jobs, oldest first. A missing file is an empty queue. A file
    /// that cannot be read is set aside as `queue.unreadable.json` instead of
    /// being written over, and the queue starts empty.
    public func load() -> [SavedJob] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        guard let jobs = Self.decode(data) else {
            let aside = file.deletingLastPathComponent().appendingPathComponent("queue.unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: file, to: aside)
            return []
        }
        return jobs.sorted { $0.createdAt < $1.createdAt }
    }
}
