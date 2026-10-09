import Foundation

/// What a job's link is.
public enum JobSource: String, Codable, Sendable {
    /// One video, already looked up.
    case video
    /// A playlist or a channel, already looked up.
    case playlist
    /// A link nobody has looked at yet (one of several pasted together). The
    /// job looks it up first and becomes a video or a playlist.
    case link
}

/// What a running job is doing.
public enum JobStage: Equatable, Sendable {
    case starting
    case downloading
    /// A named step the tool takes after downloading ("Merging streams").
    case processing(String)
    /// Moving the finished files into place.
    case finishing

    public var label: String {
        switch self {
        case .starting: return Messages.stageStarting
        case .downloading: return Messages.stageDownloading
        case .processing(let name): return name
        case .finishing: return Messages.stageFinishing
        }
    }
}

/// Where a job stands (plan Section 3.4).
public enum JobState: Equatable, Sendable {
    /// Ready, waiting for a free slot.
    case waiting
    case lookingUp
    case running(JobStage)
    /// Stopped on purpose, with what was downloaded so far kept.
    case paused
    /// Waiting for a time the person chose.
    case scheduled(Date)
    /// Waiting a little before trying again after a failure that may pass.
    case retrying(at: Date)
    case done
    case doneWithWarnings
    case failed
    case cancelled

    /// Not finished one way or another: these are the jobs written to disk.
    public var isUnfinished: Bool {
        switch self {
        case .waiting, .lookingUp, .running, .paused, .scheduled, .retrying: return true
        case .done, .doneWithWarnings, .failed, .cancelled: return false
        }
    }

    /// A tool is running for the job.
    public var isActive: Bool {
        switch self {
        case .lookingUp, .running: return true
        default: return false
        }
    }

    /// Running, or about to: what keeps the Mac awake and the app open.
    public var isBusy: Bool { self == .waiting || isActive }

    /// When a scheduled or retrying job is due.
    public var due: Date? {
        switch self {
        case .scheduled(let date), .retrying(let date): return date
        default: return nil
        }
    }
}

public struct JobProgress: Equatable, Sendable {
    /// 0 to 1 over the whole job, or nil when the tool cannot tell (a clip).
    public var fraction: Double?
    public var speed = ""
    public var timeLeft = ""
    /// The size of the file being downloaded, as the tool writes it.
    public var size = ""
    /// Which item of a playlist is being downloaded, from 1, and how many there are.
    public var item = 1
    public var itemCount = 1

    public init(fraction: Double? = 0) {
        self.fraction = fraction
    }
}

/// What a look-up found out about a job's link.
public struct JobResolution: Equatable, Sendable {
    public var source: JobSource
    public var link: String
    public var title: String
    public var site: String
    public var facts: VideoFacts?
    public var duration: String
    public var itemCount: Int?

    public init(source: JobSource, link: String, title: String, site: String, facts: VideoFacts? = nil,
                duration: String = "", itemCount: Int? = nil) {
        self.source = source
        self.link = link
        self.title = title
        self.site = site
        self.facts = facts
        self.duration = duration
        self.itemCount = itemCount
    }

    public init(_ media: MediaFacts) {
        self.init(source: .video, link: media.link, title: media.facts.title, site: media.site,
                  facts: media.facts, duration: media.duration)
    }

    public init(_ playlist: PlaylistFacts) {
        self.init(source: .playlist, link: playlist.link, title: playlist.title, site: playlist.site,
                  itemCount: playlist.count)
    }
}

/// What the Download screen hands the queue: a link, what is known about it,
/// and the recipe to download it with (a choice's preset, with any tweaks
/// such as a clip already made). Never raw arguments.
public struct JobRequest: Equatable, Sendable {
    public var resolution: JobResolution
    public var recipe: DownloadRecipe
    /// The name of the choice or preset, for the Queue screen.
    public var label: String
    /// A folder chosen for this download. Nil lets the folder rules decide.
    public var folder: String?
    /// Start at this time instead of now.
    public var startAfter: Date?
    /// The comment whose chapter list the person picked, for a recipe that
    /// takes chapters from the comments. Nil lets the best list win.
    public var chapterComment: String?

    public init(resolution: JobResolution, recipe: DownloadRecipe, label: String, folder: String? = nil, startAfter: Date? = nil,
                chapterComment: String? = nil) {
        self.resolution = resolution
        self.recipe = recipe
        self.label = label
        self.folder = folder
        self.startAfter = startAfter
        self.chapterComment = chapterComment
    }

    public static func video(_ media: MediaFacts, preset: Preset, recipe: DownloadRecipe? = nil,
                             folder: String? = nil, startAfter: Date? = nil) -> JobRequest {
        JobRequest(resolution: JobResolution(media), recipe: recipe ?? preset.recipe, label: preset.name, folder: folder, startAfter: startAfter)
    }

    public static func playlist(_ playlist: PlaylistFacts, preset: Preset, recipe: DownloadRecipe? = nil,
                                folder: String? = nil, startAfter: Date? = nil) -> JobRequest {
        JobRequest(resolution: JobResolution(playlist), recipe: recipe ?? preset.recipe, label: preset.name, folder: folder, startAfter: startAfter)
    }

    /// One job per link, each looked up when its turn comes. A link that
    /// names one video and a list is taken as the video.
    public static func links(_ links: [String], preset: Preset, recipe: DownloadRecipe? = nil,
                             folder: String? = nil, startAfter: Date? = nil) -> [JobRequest] {
        links.map { original in
            JobRequest(resolution: JobResolution(source: .link, link: Links.singleVideo(original), title: original, site: ""),
                       recipe: recipe ?? preset.recipe, label: preset.name, folder: folder, startAfter: startAfter)
        }
    }
}

/// One download, from the request to the finished files: a recipe, a source,
/// a destination and a state. The queue owns every job and publishes copies.
public struct Job: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var source: JobSource
    public var link: String
    public var recipe: DownloadRecipe
    public var label: String
    public var title: String
    public var site: String
    public var facts: VideoFacts?
    public var duration: String
    public var itemCount: Int?
    /// Where the files go. Nil until it has been decided (after a look-up).
    public var folder: String?
    /// The comment whose chapter list was picked (see `JobRequest`).
    public var chapterComment: String?
    public var state: JobState
    public var progress = JobProgress()
    /// One sentence about where the job stands: why it failed, where it was saved.
    public var message = ""
    public var warnings: [String] = []
    /// Finished files, at their final paths.
    public var files: [String] = []
    /// How many times it has been tried again after a failure that may pass.
    public var attempt = 0
    /// When the first attempt began.
    public var startedAt: Date?

    public init(id: UUID = UUID(), createdAt: Date, request: JobRequest, state: JobState = .waiting) {
        self.id = id
        self.createdAt = createdAt
        source = request.resolution.source
        link = request.resolution.link
        recipe = request.recipe
        label = request.label
        title = request.resolution.title
        site = request.resolution.site
        facts = request.resolution.facts
        duration = request.resolution.duration
        itemCount = request.resolution.itemCount
        folder = request.folder
        chapterComment = request.chapterComment
        self.state = state
    }

    public var isPlaylist: Bool { source == .playlist }

    /// Takes in what a look-up found.
    public mutating func apply(_ resolution: JobResolution) {
        source = resolution.source
        link = resolution.link
        title = resolution.title
        site = resolution.site
        facts = resolution.facts
        duration = resolution.duration
        itemCount = resolution.itemCount
    }
}
