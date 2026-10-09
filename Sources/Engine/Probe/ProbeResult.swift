import Foundation

/// What a link turned out to be. One result serves both the guided choices
/// (`ChoiceBuilder`) and the full format table (`FormatCatalog`).
public enum ProbeResult: Equatable, Sendable {
    case video(MediaFacts)
    case playlist(PlaylistFacts)
    case failure(ProbeFailure)
}

/// One chapter of a video, as the site lists it.
public struct MediaChapter: Equatable, Codable, Sendable {
    public var start: Double
    public var end: Double?
    public var title: String

    public init(start: Double, end: Double? = nil, title: String) {
        self.start = start
        self.end = end
        self.title = title
    }
}

/// Everything the lookup learned about a single video or track.
public struct MediaFacts: Equatable, Sendable {
    /// What a file name is built from.
    public var facts: VideoFacts
    public var site: String
    /// The address to download from: the site's own address for the video
    /// when it gives one, otherwise the link that was looked up.
    public var link: String
    /// Zero when the site does not say.
    public var seconds: Double
    /// "12:34", or empty when the length is unknown.
    public var duration: String
    public var thumbnail: URL?
    public var chapters: [MediaChapter]
    /// Every version the site offers, in the tool's order (worst first), without storyboards.
    public var formats: [MediaFormat]

    public init(facts: VideoFacts, site: String, link: String, seconds: Double = 0, duration: String = "",
                thumbnail: URL? = nil, chapters: [MediaChapter] = [], formats: [MediaFormat] = []) {
        self.facts = facts
        self.site = site
        self.link = link
        self.seconds = seconds
        self.duration = duration
        self.thumbnail = thumbnail
        self.chapters = chapters
        self.formats = formats
    }
}

/// One item of a playlist, as far as a quick lookup tells.
public struct PlaylistEntry: Equatable, Sendable {
    public var id: String
    public var title: String
    public var link: String?
    public var seconds: Double?

    public init(id: String, title: String, link: String? = nil, seconds: Double? = nil) {
        self.id = id
        self.title = title
        self.link = link
        self.seconds = seconds
    }
}

public struct PlaylistFacts: Equatable, Sendable {
    public var title: String
    public var uploader: String
    public var site: String
    /// How many items the list has; never less than `entries.count`.
    public var count: Int
    public var link: String
    public var entries: [PlaylistEntry]

    public init(title: String, uploader: String, site: String, count: Int, link: String, entries: [PlaylistEntry] = []) {
        self.title = title
        self.uploader = uploader
        self.site = site
        self.count = count
        self.link = link
        self.entries = entries
    }
}

/// Why a lookup gave nothing to download. The kind lets the app act (offer
/// an update, a sign-in, the setup screen) without matching on sentences.
public struct ProbeFailure: Error, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case toolMissing
        case invalidLink
        /// A stream that is still running.
        case live
        /// A stream or premiere that has not started.
        case upcoming
        /// A page or list with no videos on it.
        case emptyPage
        /// The tool answered with something that could not be understood.
        case unreadable
        /// The lookup was cancelled.
        case stopped
        /// The tool refused; its error says why.
        case tool(ErrorKind)
    }

    public let kind: Kind
    /// One plain sentence with a next step.
    public let message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    public static let toolMissing = ProbeFailure(kind: .toolMissing, message: Messages.noTool)
    public static let live = ProbeFailure(kind: .live, message: Messages.live)
    public static let upcoming = ProbeFailure(kind: .upcoming, message: Messages.upcoming)
    public static let emptyPage = ProbeFailure(kind: .emptyPage, message: Messages.emptyPage)
    public static let unreadable = ProbeFailure(kind: .unreadable, message: Messages.unreadable)
    public static let stopped = ProbeFailure(kind: .stopped, message: Messages.lookupStopped)
    public static func invalidLink(_ link: String) -> ProbeFailure {
        ProbeFailure(kind: .invalidLink, message: Messages.commandInvalidLink(link))
    }
}
