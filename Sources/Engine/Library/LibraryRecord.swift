import Foundation

/// One downloaded file, as the Library remembers it.
public struct LibraryRecord: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    /// The site's own id for the video; empty when it has none.
    public var videoID: String
    public var title: String
    /// The channel or uploader; empty when the site names none.
    public var uploader: String
    /// "12:34"; empty when the length is unknown.
    public var duration: String
    public var site: String
    /// The name of the version that was chosen ("Plays everywhere").
    public var choice: String
    public var path: String
    /// The address it was downloaded from, for "Get it again".
    public var link: String
    public var added: Date
    public var watched: Bool
    /// True for a copy made from a download (a conversion, a re-encoded
    /// version kept beside the original), as opposed to a download.
    public var isCopy: Bool
    /// The file's size when it was last seen. A file that was moved is
    /// recognised by it.
    public var bytes: Int64?
    /// The picture's file name in the thumbnails folder.
    public var thumbnail: String?
    /// How the download tool names the video in a download archive ("youtube abc123").
    public var archiveID: String?
    /// The file was not where the record says when it was last looked for.
    public var missing: Bool

    public init(id: UUID = UUID(), videoID: String = "", title: String, uploader: String = "", duration: String = "",
                site: String = "", choice: String = "", path: String, link: String = "", added: Date,
                watched: Bool = false, isCopy: Bool = false, bytes: Int64? = nil, thumbnail: String? = nil,
                archiveID: String? = nil, missing: Bool = false) {
        self.id = id
        self.videoID = videoID
        self.title = title
        self.uploader = uploader
        self.duration = duration
        self.site = site
        self.choice = choice
        self.path = path
        self.link = link
        self.added = added
        self.watched = watched
        self.isCopy = isCopy
        self.bytes = bytes
        self.thumbnail = thumbnail
        self.archiveID = archiveID
        self.missing = missing
    }

    /// File endings that hold sound only.
    public static let audioExtensions: Set<String> = ["m4a", "mp3", "opus", "flac", "wav", "aac", "ogg", "oga", "alac", "aiff"]

    public var isAudio: Bool {
        Self.audioExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// The channel's name, or a stand-in when the site gave none.
    public var channel: String { uploader.isEmpty ? Messages.libraryUnknownChannel : uploader }

    public var folder: String { (path as NSString).deletingLastPathComponent }
}

/// What the Library screen asks for.
public struct LibraryQuery: Equatable, Sendable {
    public enum Sort: String, CaseIterable, Sendable {
        case newest, oldest, title, site

        public var label: String {
            switch self {
            case .newest: return Messages.librarySortNewest
            case .oldest: return Messages.librarySortOldest
            case .title: return Messages.librarySortTitle
            case .site: return Messages.librarySortSite
            }
        }
    }

    public enum Filter: String, CaseIterable, Sendable {
        case all, video, audio, unwatched

        public var label: String {
            switch self {
            case .all: return Messages.libraryFilterAll
            case .video: return Messages.libraryFilterVideo
            case .audio: return Messages.libraryFilterAudio
            case .unwatched: return Messages.libraryFilterUnwatched
            }
        }
    }

    /// Words to look for in the title, the site and the channel. Every word has to be there.
    public var text = ""
    public var sort = Sort.newest
    public var filter = Filter.all
    /// Group by channel instead of by site.
    public var byChannel = false

    public init(text: String = "", sort: Sort = .newest, filter: Filter = .all, byChannel: Bool = false) {
        self.text = text
        self.sort = sort
        self.filter = filter
        self.byChannel = byChannel
    }

    /// Text as it is compared: without case or accents, so "cafe" finds "Café".
    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    var words: [String] {
        Self.folded(text).split(whereSeparator: \.isWhitespace).map(String.init)
    }
}

/// Records under one heading on the Library screen.
public struct LibrarySection: Identifiable, Equatable, Sendable {
    public let name: String
    public let records: [LibraryRecord]
    public var id: String { name }

    /// Groups records, which are already in the order they should be shown,
    /// by site or by channel. Headings are in alphabetical order.
    public static func group(_ records: [LibraryRecord], byChannel: Bool) -> [LibrarySection] {
        var order: [String] = []
        var groups: [String: [LibraryRecord]] = [:]
        for record in records {
            let name = byChannel ? record.channel : (record.site.isEmpty ? Messages.libraryOtherSite : record.site)
            if groups[name] == nil { order.append(name) }
            groups[name, default: []].append(record)
        }
        return order.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { LibrarySection(name: $0, records: groups[$0] ?? []) }
    }
}

/// A file that was moved to the Trash, kept so the move can be undone.
public struct TrashedRecord: Equatable, Sendable {
    public let record: LibraryRecord
    /// Where the file is now. Nil when the system did not say, or there was no file left to move.
    public let trashedAt: URL?
}

public enum LibraryFailure: Error, Equatable, Sendable {
    /// The file could not be moved to the Trash.
    case cannotTrash
    /// The file cannot be put back by the app; the Trash's own Put Back can.
    case cannotPutBack

    public var message: String {
        switch self {
        case .cannotTrash: return Messages.libraryCannotTrash
        case .cannotPutBack: return Messages.libraryCannotPutBack
        }
    }
}
