import Foundation

/// One chapter read from a comment's list of timestamps.
public struct CommentChapter: Equatable, Sendable {
    public let title: String
    public let start: Double
    public let end: Double

    /// As the download tool keeps a chapter.
    var json: [String: Any] { ["title": title, "start_time": start, "end_time": end] }
}

/// A comment that holds a usable chapter list.
public struct CommentChapterCandidate: Equatable, Sendable, Identifiable {
    public let id: String
    public let author: String
    public let text: String
    public let likes: Int
    public let chapters: [CommentChapter]
}

/// Finds a chapter list in a comment (Studio's parser, unchanged in what it
/// accepts): one timestamp per line, at either end of the line, at least
/// three, each later than the one before and inside the video.
public enum CommentChapterParser {
    private static let timestampPattern = #"(?<![\d:])(?:\d{1,3}:)?\d{1,3}:\d{2}(?![\d:])"#

    private static let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "[]()–—-:|•"))

    /// Drops separators from both ends, except that the characters in
    /// `keepingAtStart` stay where the text begins.
    private static func trimmed(_ text: String, keepingAtStart kept: String) -> String {
        let start = separators.subtracting(CharacterSet(charactersIn: kept))
        var scalars = Substring(text).unicodeScalars
        while let first = scalars.first, start.contains(first) { scalars.removeFirst() }
        while let last = scalars.last, separators.contains(last) { scalars.removeLast() }
        return String(scalars)
    }

    public static func parse(_ text: String, duration: Double) -> [CommentChapter] {
        guard duration.isFinite, duration > 0,
              let timestamp = try? NSRegularExpression(pattern: timestampPattern) else { return [] }
        var starts: [(title: String, seconds: Double)] = []
        for line in text.components(separatedBy: .newlines) {
            let ns = line as NSString
            let matches = timestamp.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            guard matches.count == 1, let match = matches.first else { return [] }
            let parts = ns.substring(with: match.range).split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2 || parts.count == 3, let last = parts.last, last < 60,
                  parts.count != 3 || parts[1] < 60 else { return [] }
            let seconds = Double(parts.reduce(0) { $0 * 60 + $1 })
            guard seconds < duration, starts.last.map({ seconds > $0.seconds }) ?? true else { return [] }
            // What stands between a time and its title is dropped: "[0:00] Intro",
            // "Intro – 0:00". A bracket on the title's far side belongs to the
            // title ("Intro (Live)"), which is where this differs from Studio.
            let before = trimmed(ns.substring(to: match.range.location), keepingAtStart: "([")
            let after = String(trimmed(String(ns.substring(from: NSMaxRange(match.range)).reversed()), keepingAtStart: ")]").reversed())
            // A timestamp in the middle of a sentence is not a chapter heading.
            let trackNumber = before.range(of: #"^#?\d{1,3}[.)]?$"#, options: .regularExpression) != nil
            guard before.isEmpty || after.isEmpty || trackNumber else { return [] }
            let title = (!after.isEmpty && (before.isEmpty || trackNumber)) ? after : before
            guard !title.isEmpty else { return [] }
            starts.append((title, seconds))
        }
        guard starts.count >= 3 else { return [] }
        // Keep the opening of the video when the list starts later than zero.
        if starts[0].seconds > 0 { starts.insert((Messages.chapterOpening, 0), at: 0) }
        return starts.enumerated().map { index, item in
            CommentChapter(title: item.title, start: item.seconds,
                           end: index + 1 < starts.count ? starts[index + 1].seconds : duration)
        }
    }

    /// Every comment of a video that holds a chapter list: the longest list
    /// first, then the most liked.
    public static func candidates(in info: [String: Any]) -> [CommentChapterCandidate] {
        guard let duration = (info["duration"] as? NSNumber)?.doubleValue else { return [] }
        return ((info["comments"] as? [[String: Any]]) ?? []).compactMap { comment -> CommentChapterCandidate? in
            let text = comment["text"] as? String ?? ""
            let chapters = parse(text, duration: duration)
            guard !chapters.isEmpty, let id = comment["id"] as? String else { return nil }
            return CommentChapterCandidate(id: id, author: comment["author"] as? String ?? Messages.commentAuthorUnknown,
                                           text: text, likes: (comment["like_count"] as? NSNumber)?.intValue ?? 0, chapters: chapters)
        }.sorted {
            if $0.chapters.count != $1.chapters.count { return $0.chapters.count > $1.chapters.count }
            if $0.likes != $1.likes { return $0.likes > $1.likes }
            return $0.id < $1.id
        }
    }
}

/// Getting a video's details ready with chapters taken from its comments
/// (Studio's `CommentChapterService`). The details are fetched just before
/// downloading and handed to the download as a file, so the chapters are
/// embedded, split and tagged like the site's own. Planning and reading
/// only: the stage that runs the tool is in `Jobs/Stages`.
public enum CommentChapters {
    /// Asks for one video's full details, with its top 200 comments when
    /// wanted. Like every yt-dlp call it ignores the user's config, uses Deno
    /// when present and puts `--` before the link (plan Rule 4).
    public static func fetchArguments(link: String, includeComments: Bool, cookiesFile: String?, cookieBrowser: CookieBrowser,
                                      proxy: String, toolchain: YtdlpCommand.Toolchain) -> [String] {
        var args = YtdlpCommand.baseArguments(toolchain)
        args += ["--skip-download", "--dump-single-json", "--no-clean-info-json", "--no-colors", "--no-warnings", "--no-playlist"]
        if includeComments {
            args += ["--write-comments", "--extractor-args", "youtube:comment_sort=top;max_comments=200,200,0,0"]
        } else {
            args += ["--no-write-comments"]
        }
        if !proxy.trimmed.isEmpty { args += ["--proxy", proxy.trimmed] }
        if let cookies = cookiesFile, !cookies.isEmpty {
            args += ["--cookies", cookies]
        } else if cookieBrowser != .none {
            args += ["--cookies-from-browser", cookieBrowser.rawValue]
        }
        return args + ["--", link]
    }

    /// True when the video has no chapters of its own.
    public static func lacksChapters(_ info: [String: Any]) -> Bool {
        ((info["chapters"] as? [[String: Any]]) ?? []).isEmpty
    }

    public enum Problem: Error, Equatable, Sendable {
        /// No comment holds a chapter list.
        case noneFound
        /// The comment that was picked is no longer among the top comments.
        case selectionGone
        /// The link is a list, not one video.
        case notOneVideo
    }

    public struct Prepared {
        /// The details to hand the download.
        public var info: [String: Any]
        /// A line for the log saying what was done.
        public var note: String
    }

    /// Puts the chapters in place. `.comments` always takes them from a
    /// comment and it is a problem when there is none; `.commentsIfMissing`
    /// keeps the site's own chapters when it has them and carries on quietly
    /// without any when no comment has a list. `selection` is the id of the
    /// comment the person picked; without one the best candidate is used.
    public static func prepare(_ info: [String: Any], source: ChapterSource, selection: String? = nil,
                               keepComments: Bool) throws -> Prepared {
        guard info["entries"] == nil else { throw Problem.notOneVideo }
        var video = info
        var note = Messages.commentChaptersKeptOwn
        if source == .comments || (source == .commentsIfMissing && lacksChapters(info)) {
            let candidates = CommentChapterParser.candidates(in: info)
            let picked = selection == nil ? candidates.first : candidates.first { $0.id == selection }
            if let picked {
                video["chapters"] = picked.chapters.map(\.json)
                note = Messages.commentChaptersUsed(picked.chapters.count, author: picked.author)
            } else if selection != nil {
                throw Problem.selectionGone
            } else if source == .comments {
                throw Problem.noneFound
            } else {
                note = Messages.commentChaptersNoneQuiet
            }
        }
        // The download chooses formats and subtitles itself, from its own settings.
        for key in ["requested_formats", "requested_downloads", "requested_subtitles"] { video.removeValue(forKey: key) }
        if !keepComments { video.removeValue(forKey: "comments") }
        return Prepared(info: video, note: note)
    }
}

// MARK: - Looking for lists, for the picker

extension CommentChapters {
    /// What the picker shows: the comments that hold a chapter list, best
    /// first, or one sentence saying why there are none.
    public struct Found: Equatable, Sendable {
        public var candidates: [CommentChapterCandidate] = []
        public var problem: String?
    }

    /// Reads one video's top comments and finds the chapter lists in them.
    /// The same request the download makes just before it starts, so what is
    /// picked here is what the download finds again by the comment's id.
    public static func find(link: String, cookiesFile: String? = nil, cookieBrowser: CookieBrowser = .none, proxy: String = "",
                            toolchain: YtdlpCommand.Toolchain, runner: ProcessRunner = ProcessRunner(),
                            clock: any EngineClock = SystemClock(), timeout: TimeInterval = 180) async -> Found {
        guard Links.isWebLink(link) else { return Found(problem: Messages.commandInvalidLink(link)) }
        let arguments = fetchArguments(link: link, includeComments: true, cookiesFile: cookiesFile, cookieBrowser: cookieBrowser,
                                       proxy: proxy, toolchain: toolchain)
        let request = ProcessRequest(executable: toolchain.ytdlp, arguments: arguments, environment: toolchain.environment)
        let answer = await clock.limited(to: timeout) { try? await runner.run(request) }
        guard let output = answer ?? nil, !Task.isCancelled,
              let info = (try? JSONSerialization.jsonObject(with: Data(output.standardOutput.utf8))) as? [String: Any] else {
            return Found(problem: Messages.commentPickerUnreadable)
        }
        let candidates = CommentChapterParser.candidates(in: info)
        return Found(candidates: candidates, problem: candidates.isEmpty ? Messages.commentPickerNone : nil)
    }
}
