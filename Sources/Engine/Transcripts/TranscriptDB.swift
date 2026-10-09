import Foundation

/// A place in a video where the searched words were said.
public struct SpokenHit: Equatable, Sendable {
    /// The Library record's id, as text.
    public let video: String
    public let start: Double
    /// The matching passage. Matched words sit between U+E000 and U+E001.
    public let snippet: String
}

/// A piece of a passage, marked when it is one of the words searched for.
public struct SpokenPiece: Equatable, Sendable {
    public let text: String
    public let matched: Bool

    public init(text: String, matched: Bool) {
        self.text = text
        self.matched = matched
    }
}

/// The searchable record of what was said in each video (Phobos's
/// `transcripts.sqlite`, same layout, so a copy of Phobos's file is usable as
/// it is). Full-text search where this Mac's SQLite has it, plain matching
/// where it does not. A video is named by its Library record's id.
public actor TranscriptDB {
    /// Where a video's words came from.
    public enum Source: String, Sendable {
        case file, site, speech
        /// Looked at, and nothing was said (or nothing could be read).
        case none
    }

    static let markStart: Character = "\u{E000}"
    static let markEnd: Character = "\u{E001}"

    private let db: SQLiteDatabase
    public nonisolated let usesFullText: Bool

    /// Opens the database, creating it when missing. Nil keeps it in memory.
    /// A file that cannot be read as one is set aside as
    /// `transcripts.unreadable.sqlite`, never written over.
    public init(file: URL?) {
        if let opened = Self.open(file) {
            (db, usesFullText) = opened
        } else if let file, let fresh = Self.setAsideAndOpen(file) {
            (db, usesFullText) = fresh
        } else {
            (db, usesFullText) = Self.open(nil)!
        }
    }

    public init(paths: AppPaths) {
        self.init(file: paths.transcriptsDatabase)
    }

    private static func open(_ file: URL?) -> (SQLiteDatabase, Bool)? {
        guard let db = try? SQLiteDatabase(file: file) else { return nil }
        do {
            // A file that is not a database fails here, at the first statement.
            try db.execute("CREATE TABLE IF NOT EXISTS videos (video TEXT PRIMARY KEY, source TEXT NOT NULL, indexed REAL NOT NULL)")
            if tableSQL("spoken", in: db).isEmpty {
                do {
                    try db.execute("CREATE VIRTUAL TABLE spoken USING fts5(text, video UNINDEXED, start UNINDEXED, tokenize = 'unicode61 remove_diacritics 2')")
                } catch {
                    try db.execute("CREATE TABLE spoken (text TEXT, video TEXT, start REAL)")
                    try db.execute("CREATE INDEX IF NOT EXISTS spoken_video ON spoken (video)")
                }
            }
            return (db, tableSQL("spoken", in: db).lowercased().contains("fts5"))
        } catch {
            return nil
        }
    }

    private static func setAsideAndOpen(_ file: URL) -> (SQLiteDatabase, Bool)? {
        let aside = file.deletingLastPathComponent().appendingPathComponent("transcripts.unreadable.sqlite")
        try? FileManager.default.removeItem(at: aside)
        guard (try? FileManager.default.moveItem(at: file, to: aside)) != nil else { return nil }
        return open(file)
    }

    private static func tableSQL(_ name: String, in db: SQLiteDatabase) -> String {
        (try? db.run("SELECT sql FROM sqlite_master WHERE name = ?", [.text(name)]))?.first?.first?.string ?? ""
    }

    // MARK: Writing

    /// Stores what was said in a video, replacing anything stored before. An
    /// empty list with the source `none` records that the video was looked at
    /// and had no words.
    @discardableResult
    public func replace(video: String, source: Source, cues: [Cue], now: Date = Date()) -> Bool {
        do {
            try db.transaction {
                try db.run("DELETE FROM spoken WHERE video = ?", [.text(video)])
                for cue in cues {
                    try db.run("INSERT INTO spoken (text, video, start) VALUES (?, ?, ?)", [.text(cue.text), .text(video), .real(cue.start)])
                }
                try db.run("INSERT OR REPLACE INTO videos (video, source, indexed) VALUES (?, ?, ?)",
                           [.text(video), .text(source.rawValue), .real(now.timeIntervalSince1970)])
            }
            return true
        } catch {
            return false
        }
    }

    public func remove(video: String) {
        try? db.transaction {
            try db.run("DELETE FROM spoken WHERE video = ?", [.text(video)])
            try db.run("DELETE FROM videos WHERE video = ?", [.text(video)])
            return
        }
    }

    /// Forgets the videos that were looked at and found to have no words, so they are tried again.
    public func forgetEmpty() {
        _ = try? db.run("DELETE FROM videos WHERE source = ?", [.text(Source.none.rawValue)])
    }

    // MARK: Reading

    /// Every video that has been looked at, and where its words came from.
    public func indexedVideos() -> [String: String] {
        var found: [String: String] = [:]
        for row in (try? db.run("SELECT video, source FROM videos")) ?? [] {
            if let video = row[0].string, let source = row[1].string { found[video] = source }
        }
        return found
    }

    /// How many videos can be searched, and how many were found to have no words.
    public func counts() -> (searchable: Int, empty: Int) {
        let all = indexedVideos()
        let empty = all.values.filter { $0 == Source.none.rawValue }.count
        return (all.count - empty, empty)
    }

    /// The words of a query that are worth searching for.
    public static func tokens(_ query: String) -> [String] {
        query.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// A full-text query: every word must appear, and the last may be unfinished.
    public static func matchQuery(for words: [String]) -> String {
        words.enumerated()
            .map { "\"" + $0.element + "\"" + ($0.offset == words.count - 1 ? "*" : "") }
            .joined(separator: " ")
    }

    /// A passage cut into pieces, each marked as matched or not.
    public static func pieces(of snippet: String) -> [SpokenPiece] {
        var result: [SpokenPiece] = []
        var current = ""
        var matched = false
        for character in snippet {
            if character == markStart || character == markEnd {
                if !current.isEmpty { result.append(SpokenPiece(text: current, matched: matched)) }
                current = ""
                matched = character == markStart
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { result.append(SpokenPiece(text: current, matched: matched)) }
        return result
    }

    /// Passages that contain every word of the query, best matches first.
    public func search(_ query: String, limit: Int = 60) -> [SpokenHit] {
        let words = Self.tokens(query)
        guard !words.isEmpty else { return [] }
        let rows: [[SQLValue]]?
        if usesFullText {
            // The two marks are fixed characters of the app's own; what was typed is a bound value.
            let sql = "SELECT video, start, snippet(spoken, 0, '\(Self.markStart)', '\(Self.markEnd)', '…', 14) FROM spoken WHERE spoken MATCH ? ORDER BY rank LIMIT ?"
            rows = try? db.run(sql, [.text(Self.matchQuery(for: words)), .integer(Int64(limit))])
        } else {
            let sql = "SELECT video, start, text FROM spoken WHERE "
                + words.map { _ in "text LIKE ? ESCAPE '\\'" }.joined(separator: " AND ") + " LIMIT ?"
            rows = try? db.run(sql, words.map { .text("%" + $0 + "%") } + [.integer(Int64(limit))])
        }
        return (rows ?? []).compactMap { row in
            guard let video = row[0].string, let text = row[2].string else { return nil }
            return SpokenHit(video: video, start: row[1].double ?? 0, snippet: text)
        }
    }
}
