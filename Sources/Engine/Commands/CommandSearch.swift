import Foundation

/// One thing the command bar can do.
public struct CommandEntry: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    /// A second line: where it goes, or which site a video is from.
    public let detail: String
    /// "Go to", "Play", "Action": shown at the right of the row.
    public let group: String
    /// An SF Symbol's name for the row.
    public let symbol: String
    /// Other words that should find it, such as "preferences" for Settings.
    public let keywords: [String]

    public init(id: String, title: String, detail: String = "", group: String = "", symbol: String = "", keywords: [String] = []) {
        self.id = id
        self.title = title
        self.detail = detail
        self.group = group
        self.symbol = symbol
        self.keywords = keywords
    }
}

/// Ranking for the command bar (Phobos): given what was typed and a list of
/// things the bar can do, decides which match and in what order.
public enum CommandSearch {
    private static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the letters of `small` appear in `big` in order, such as "chn" in "check channels".
    private static func isSubsequence(_ small: String, of big: String) -> Bool {
        var rest = small[...]
        for character in big {
            guard let first = rest.first else { break }
            if character == first { rest = rest.dropFirst() }
        }
        return rest.isEmpty
    }

    /// Higher is a better match; nil means no match at all.
    public static func score(_ entry: CommandEntry, query: String) -> Int? {
        let q = normalize(query)
        guard !q.isEmpty else { return 0 }
        let title = normalize(entry.title)
        let keywords = entry.keywords.map(normalize)
        let detail = normalize(entry.detail)

        if title == q { return 1000 }
        if title.hasPrefix(q) { return 900 }
        if title.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return 800 }
        if keywords.contains(q) { return 700 }
        if keywords.contains(where: { $0.hasPrefix(q) }) { return 650 }
        if title.contains(q) { return 600 }
        if keywords.contains(where: { $0.contains(q) }) { return 400 }
        if detail.contains(q) { return 300 }
        let parts = q.split(separator: " ").map(String.init)
        if parts.count > 1 {
            let haystack = ([title, detail] + keywords).joined(separator: " ")
            if parts.allSatisfy({ haystack.contains($0) }) { return 200 }
        }
        if q.count >= 2, isSubsequence(q, of: title) { return 100 }
        return nil
    }

    /// The entries that match, best first. Equal scores keep their given
    /// order. An empty query returns everything in the given order.
    public static func rank(_ entries: [CommandEntry], query: String) -> [CommandEntry] {
        var scored: [(entry: CommandEntry, score: Int, index: Int)] = []
        for (index, entry) in entries.enumerated() {
            if let value = score(entry, query: query) { scored.append((entry, value, index)) }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return scored.map(\.entry)
    }
}

/// What the command bar offers. The app only maps an entry's id to the thing
/// it does; which entries exist, their words, and what is shown for what was
/// typed are decided here.
public enum CommandBar {
    /// What the bar needs to know about the app right now.
    public struct Situation: Equatable, Sendable {
        /// Something is downloading, waiting or about to try again.
        public var hasBusy = false
        public var hasPaused = false

        public init(hasBusy: Bool = false, hasPaused: Bool = false) {
            self.hasBusy = hasBusy
            self.hasPaused = hasPaused
        }
    }

    public static let linkID = "link"
    public static let spokenID = "spoken"
    public static let videoPrefix = "video."
    public static func screenID(_ name: String) -> String { "go." + name }
    /// How many Library videos are listed, so they never bury the commands.
    public static let videoLimit = 6

    public static let settingsID = "settings"
    public static let pauseAllID = "pauseAll"
    public static let resumeAllID = "resumeAll"
    public static let clearFinishedID = "clearFinished"
    public static let checkChannelsID = "check"
    public static let pasteID = "paste"
    public static let openFolderID = "folder"
    public static let tourID = "tour"

    /// The screens (name, title, symbol), in the sidebar's order.
    public typealias ScreenEntry = (name: String, title: String, symbol: String)

    private static let screenWords: [String: [String]] = [
        "download": ["paste", "link", "new"],
        "queue": ["downloads", "progress"],
        "library": ["videos", "files", "watch"],
        "following": ["channels", "subscriptions"],
        "convert": ["cut", "clip", "shrink", "mp4", "audio"],
    ]

    /// Everything that is there whatever is typed: the screens, Settings and the actions that make sense now.
    public static func fixed(screens: [ScreenEntry], situation: Situation) -> [CommandEntry] {
        var list: [CommandEntry] = screens.map { screen in
            CommandEntry(id: screenID(screen.name), title: screen.title, detail: Messages.commandGoTo(screen.title),
                         group: Messages.commandGroupGo, symbol: screen.symbol,
                         keywords: ["go", "open", "show"] + (screenWords[screen.name] ?? []))
        }
        func add(_ id: String, _ title: String, _ detail: String, _ symbol: String, _ words: [String], group: String = Messages.commandGroupAction) {
            list.append(CommandEntry(id: id, title: title, detail: detail, group: group, symbol: symbol, keywords: words))
        }
        add(settingsID, Messages.commandSettings, Messages.commandSettingsDetail, "gearshape",
            ["preferences", "folders", "theme", "accent", "speed", "limit", "sign-in", "cookies", "tools"], group: Messages.commandGroupGo)
        if situation.hasBusy { add(pauseAllID, Messages.commandPauseAll, Messages.commandPauseAllDetail, "pause.fill", ["stop", "downloads"]) }
        if situation.hasPaused { add(resumeAllID, Messages.commandResumeAll, Messages.commandResumeAllDetail, "play.fill", ["continue", "downloads"]) }
        add(clearFinishedID, Messages.commandClearFinished, Messages.commandClearFinishedDetail, "xmark.circle", ["clean", "queue"])
        add(checkChannelsID, Messages.commandCheckChannels, Messages.commandCheckChannelsDetail, "arrow.clockwise", ["following", "new", "update"])
        add(pasteID, Messages.commandPaste, Messages.commandPasteDetail, "doc.on.clipboard", ["download", "clipboard"])
        add(openFolderID, Messages.commandOpenFolder, Messages.commandOpenFolderDetail, "folder", ["finder", "movies"])
        add(tourID, Messages.commandTour, Messages.commandTourDetail, "questionmark.circle", ["help", "intro", "tutorial"])
        return list
    }

    public static func videoID(_ record: LibraryRecord) -> String { videoPrefix + record.id.uuidString }

    /// The rows for what was typed, best first: a pasted link first, then the
    /// commands and up to six Library videos that can be played, then the
    /// search of spoken words. Videos are offered only once something is typed.
    public static func results(query: String, fixed: [CommandEntry], records: [LibraryRecord], spokenSearch: Bool) -> [CommandEntry] {
        let typed = query.trimmed
        var shown: [CommandEntry] = []
        let links = Links.extract(from: typed)
        if !links.isEmpty {
            shown.append(CommandEntry(id: linkID, title: Messages.commandLookUp(links.count), detail: links[0],
                                      group: Messages.commandGroupDownload, symbol: "arrow.down.to.line"))
        }
        var candidates = fixed
        if !typed.isEmpty {
            // A file that is gone cannot be played.
            candidates += records.filter { !$0.missing }.map { record in
                CommandEntry(id: videoID(record), title: record.title,
                             detail: [record.site, record.uploader].filter { !$0.isEmpty }.joined(separator: " · "),
                             group: Messages.commandGroupPlay, symbol: "play.fill")
            }
        }
        var videos = 0
        for entry in CommandSearch.rank(candidates, query: typed) {
            if entry.id.hasPrefix(videoPrefix) {
                guard videos < videoLimit else { continue }
                videos += 1
            }
            shown.append(entry)
        }
        if spokenSearch, typed.count >= 3, links.isEmpty {
            shown.append(CommandEntry(id: spokenID, title: Messages.commandFindSpoken(typed), detail: Messages.commandFindSpokenDetail,
                                      group: Messages.commandGroupSearch, symbol: "waveform"))
        }
        return shown
    }
}
