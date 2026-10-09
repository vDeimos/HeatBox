import Foundation

/// The record of what has been downloaded, in a SQLite database.
///
/// The Library is the app's memory, never the owner of the files: a record
/// can be taken off the list without touching its file, a file is only ever
/// removed by moving it to the Trash, and a file that was moved or renamed in
/// the Finder is found again by its size and name instead of being forgotten.
public actor LibraryRepository {
    public static let version = 1

    private let db: SQLiteDatabase
    /// Where the pictures are kept. Reading a picture needs no turn on the actor.
    public nonisolated let thumbnails: URL
    private let trash: any Trash
    private let archive: ArchiveBridge?
    private var watchers: [UUID: AsyncStream<Void>.Continuation] = [:]

    // MARK: Opening

    /// Opens the library, creating it when it is missing. `database` nil
    /// keeps it in memory. A file that cannot be read as a library is set
    /// aside as `library.unreadable.sqlite`, never written over, and a new
    /// one is started.
    public init(database: URL?, thumbnails: URL, trash: any Trash = SystemTrash(), archive: ArchiveBridge? = nil) {
        self.thumbnails = thumbnails
        self.trash = trash
        self.archive = archive
        try? FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        if let database {
            try? FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        if let opened = Self.open(database) {
            db = opened
        } else if let database, let fresh = Self.setAsideAndOpen(database) {
            db = fresh
        } else {
            // Nothing on disk can be opened: the app still runs, and forgets when it quits.
            db = Self.open(nil)!
        }
    }

    public init(paths: AppPaths, trash: any Trash = SystemTrash()) {
        self.init(database: paths.libraryDatabase, thumbnails: paths.thumbnails, trash: trash, archive: ArchiveBridge(paths: paths))
    }

    private static func open(_ file: URL?) -> SQLiteDatabase? {
        guard let db = try? SQLiteDatabase(file: file) else { return nil }
        do {
            // A file that is not a database fails here, at the first read.
            let version = db.userVersion
            guard version <= Self.version else { return nil }
            try db.execute("PRAGMA journal_mode = WAL")
            try db.execute("""
                CREATE TABLE IF NOT EXISTS records (
                    id TEXT PRIMARY KEY NOT NULL,
                    video_id TEXT NOT NULL,
                    title TEXT NOT NULL,
                    uploader TEXT NOT NULL,
                    duration TEXT NOT NULL,
                    site TEXT NOT NULL,
                    choice TEXT NOT NULL,
                    path TEXT NOT NULL,
                    link TEXT NOT NULL,
                    added REAL NOT NULL,
                    watched INTEGER NOT NULL,
                    is_copy INTEGER NOT NULL,
                    audio INTEGER NOT NULL,
                    bytes INTEGER,
                    thumbnail TEXT,
                    archive_id TEXT,
                    missing INTEGER NOT NULL DEFAULT 0,
                    search TEXT NOT NULL,
                    sort_title TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS records_added ON records (added);
                CREATE INDEX IF NOT EXISTS records_video ON records (video_id);
                CREATE INDEX IF NOT EXISTS records_path ON records (path);
                """)
            if version == 0 { db.userVersion = Self.version }
            return db
        } catch {
            return nil
        }
    }

    private static func setAsideAndOpen(_ file: URL) -> SQLiteDatabase? {
        let aside = file.deletingLastPathComponent().appendingPathComponent("library.unreadable.sqlite")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: file, to: aside)
        for ending in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: file.path + ending)
        }
        return open(file)
    }

    // MARK: Changes

    /// Yields once now and again after every change, so a screen can read the list anew.
    public func changes() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        watchers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.forget(watcher: id) }
        }
        continuation.yield()
        return stream
    }

    private func forget(watcher id: UUID) {
        watchers[id] = nil
    }

    private func changed() {
        for watcher in watchers.values { watcher.yield() }
    }

    // MARK: Rows

    private static let columns = "id, video_id, title, uploader, duration, site, choice, path, link, added, watched, is_copy, bytes, thumbnail, archive_id, missing"

    private static func record(from row: [SQLValue]) -> LibraryRecord? {
        guard row.count >= 16, let id = row[0].string.flatMap(UUID.init(uuidString:)), let path = row[7].string else { return nil }
        return LibraryRecord(id: id, videoID: row[1].string ?? "", title: row[2].string ?? "", uploader: row[3].string ?? "",
                             duration: row[4].string ?? "", site: row[5].string ?? "", choice: row[6].string ?? "",
                             path: path, link: row[8].string ?? "",
                             added: Date(timeIntervalSince1970: row[9].double ?? 0), watched: row[10].int == 1,
                             isCopy: row[11].int == 1, bytes: row[12].int, thumbnail: row[13].string,
                             archiveID: row[14].string, missing: row[15].int == 1)
    }

    private func write(_ record: LibraryRecord) throws {
        try db.run("""
            INSERT OR REPLACE INTO records (id, video_id, title, uploader, duration, site, choice, path, link, added, watched,
                is_copy, audio, bytes, thumbnail, archive_id, missing, search, sort_title)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [
                .text(record.id.uuidString), .text(record.videoID), .text(record.title), .text(record.uploader),
                .text(record.duration), .text(record.site), .text(record.choice), .text(record.path), .text(record.link),
                .real(record.added.timeIntervalSince1970), .bool(record.watched), .bool(record.isCopy), .bool(record.isAudio),
                .optional(record.bytes), .optional(record.thumbnail), .optional(record.archiveID), .bool(record.missing),
                .text(LibraryQuery.folded([record.title, record.site, record.uploader].joined(separator: "\n"))),
                .text(LibraryQuery.folded(record.title)),
            ])
    }

    // MARK: Adding

    /// Adds a record, or replaces the one with the same id.
    public func add(_ record: LibraryRecord) {
        try? write(record)
        changed()
    }

    /// Adds many records at once: all of them, or none.
    public func add(_ records: [LibraryRecord]) {
        guard !records.isEmpty else { return }
        try? db.transaction {
            for record in records { try write(record) }
        }
        changed()
    }

    /// Records a copy made from a file that is in the Library, beside its
    /// original: the same video, another file. Nil when the original is not here.
    @discardableResult
    public func addCopy(of originalPath: String, at newPath: String, label: String, now: Date = Date()) -> LibraryRecord? {
        guard let original = record(atPath: originalPath) else { return nil }
        var copy = original
        copy.id = UUID()
        copy.path = newPath
        copy.title = ((newPath as NSString).lastPathComponent as NSString).deletingPathExtension
        copy.choice = label
        copy.added = now
        copy.watched = false
        copy.isCopy = true
        copy.missing = false
        copy.bytes = Self.size(of: newPath)
        copy.archiveID = nil
        add(copy)
        return copy
    }

    // MARK: Reading

    public func count() -> Int {
        Int((try? db.run("SELECT COUNT(*) FROM records"))?.first?.first?.int ?? 0)
    }

    public func record(_ id: UUID) -> LibraryRecord? {
        (try? db.run("SELECT \(Self.columns) FROM records WHERE id = ?", [.text(id.uuidString)]))?.first.flatMap(Self.record)
    }

    public func record(atPath path: String) -> LibraryRecord? {
        (try? db.run("SELECT \(Self.columns) FROM records WHERE path = ? ORDER BY added DESC LIMIT 1", [.text(path)]))?
            .first.flatMap(Self.record)
    }

    /// The records a query asks for, in its order.
    public func records(matching query: LibraryQuery = LibraryQuery()) -> [LibraryRecord] {
        var conditions: [String] = []
        var values: [SQLValue] = []
        switch query.filter {
        case .all: break
        case .video: conditions.append("audio = 0")
        case .audio: conditions.append("audio = 1")
        case .unwatched: conditions.append("watched = 0")
        }
        for word in query.words {
            conditions.append("instr(search, ?) > 0")
            values.append(.text(word))
        }
        let order: String
        switch query.sort {
        case .newest: order = "added DESC"
        case .oldest: order = "added ASC"
        case .title: order = "sort_title ASC, added DESC"
        case .site: order = "site COLLATE NOCASE ASC, added DESC"
        }
        let filter = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let rows = (try? db.run("SELECT \(Self.columns) FROM records \(filter) ORDER BY \(order)", values)) ?? []
        return rows.compactMap(Self.record)
    }

    public func sections(matching query: LibraryQuery = LibraryQuery()) -> [LibrarySection] {
        LibrarySection.group(records(matching: query), byChannel: query.byChannel)
    }

    /// Earlier downloads of the same video whose files are still there,
    /// newest first. Copies do not count: they are not downloads.
    public func earlier(videoID: String, site: String) -> [LibraryRecord] {
        guard !videoID.isEmpty else { return [] }
        let rows = (try? db.run("SELECT \(Self.columns) FROM records WHERE video_id = ? AND is_copy = 0 ORDER BY added DESC",
                                [.text(videoID)])) ?? []
        return rows.compactMap(Self.record).filter { record in
            (record.site.isEmpty || site.isEmpty || record.site == site) && FileManager.default.fileExists(atPath: record.path)
        }
    }

    public func thumbnailNames() -> Set<String> {
        Set(((try? db.run("SELECT DISTINCT thumbnail FROM records WHERE thumbnail IS NOT NULL")) ?? []).compactMap { $0.first?.string })
    }

    // MARK: Changing

    public func setWatched(_ id: UUID, _ watched: Bool) {
        _ = try? db.run("UPDATE records SET watched = ? WHERE id = ?", [.bool(watched), .text(id.uuidString)])
        changed()
    }

    /// Takes a record off the list. The file itself is not touched.
    @discardableResult
    public func remove(_ id: UUID) -> LibraryRecord? {
        guard let record = record(id) else { return nil }
        _ = try? db.run("DELETE FROM records WHERE id = ?", [.text(id.uuidString)])
        changed()
        return record
    }

    /// Moves a record's file to the Trash and takes the record off the list.
    /// A record whose file is already gone is simply taken off. The video's
    /// line leaves the download archive, so it can be fetched again.
    public func trash(_ id: UUID) throws -> TrashedRecord {
        guard let record = record(id) else { throw LibraryFailure.cannotTrash }
        var trashedAt: URL?
        if FileManager.default.fileExists(atPath: record.path) {
            do {
                trashedAt = try trash.trash(URL(fileURLWithPath: record.path))
            } catch {
                throw LibraryFailure.cannotTrash
            }
        }
        _ = try? db.run("DELETE FROM records WHERE id = ?", [.text(id.uuidString)])
        if let entry = record.archiveID, !hasOtherDownload(of: record) { archive?.forget([entry]) }
        changed()
        return TrashedRecord(record: record, trashedAt: trashedAt)
    }

    /// Puts a trashed file back where it was, and its record back on the
    /// list. Never over a file that has taken the name meanwhile.
    public func undo(_ trashed: TrashedRecord) throws {
        guard let from = trashed.trashedAt, FileManager.default.fileExists(atPath: from.path),
              !FileManager.default.fileExists(atPath: trashed.record.path) else { throw LibraryFailure.cannotPutBack }
        do {
            try FileManager.default.createDirectory(atPath: trashed.record.folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: from, to: URL(fileURLWithPath: trashed.record.path))
        } catch {
            throw LibraryFailure.cannotPutBack
        }
        var record = trashed.record
        record.missing = false
        try? write(record)
        if let entry = record.archiveID { archive?.remember([entry]) }
        changed()
    }

    /// The person wants a video again whose file is gone: the download
    /// archive must not answer "already downloaded".
    public func forgetInArchive(_ record: LibraryRecord) {
        if let entry = record.archiveID { archive?.forget([entry]) }
    }

    private func hasOtherDownload(of record: LibraryRecord) -> Bool {
        guard let entry = record.archiveID else { return false }
        let rows = (try? db.run("SELECT path FROM records WHERE archive_id = ? AND is_copy = 0", [.text(entry)])) ?? []
        return rows.contains { $0.first?.string.map(FileManager.default.fileExists(atPath:)) ?? false }
    }

    // MARK: Pictures

    public nonisolated func thumbnailURL(named name: String?) -> URL? {
        guard let name, !name.isEmpty, !name.contains("/") else { return nil }
        let file = thumbnails.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// Takes a picture into the thumbnails folder under a name of its own and
    /// returns that name. `moving` takes the file itself; otherwise it is copied.
    public nonisolated func storeThumbnail(from file: URL, moving: Bool) -> String? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let ext = file.pathExtension.lowercased()
        let name = UUID().uuidString.lowercased() + (ext.isEmpty ? "" : "." + ext)
        let target = thumbnails.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true)
            if moving {
                try FileManager.default.moveItem(at: file, to: target)
            } else {
                try FileManager.default.copyItem(at: file, to: target)
            }
            return name
        } catch {
            return nil
        }
    }

    /// Removes pictures no record uses any more. Returns how many.
    @discardableResult
    public func sweepThumbnails() -> Int {
        let used = thumbnailNames()
        var removed = 0
        for name in (try? FileManager.default.contentsOfDirectory(atPath: thumbnails.path)) ?? [] where !used.contains(name) {
            if (try? FileManager.default.removeItem(at: thumbnails.appendingPathComponent(name))) != nil { removed += 1 }
        }
        return removed
    }

    // MARK: Files that moved

    public struct FileCheck: Equatable, Sendable {
        /// Records whose file is not where they say and was not found elsewhere.
        public var missing = 0
        /// Records whose file had moved and was found again.
        public var found = 0
    }

    private static func size(of path: String) -> Int64? {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value
    }

    /// Folders that are really one thing, which a search for media does not go into.
    private static let bundleExtensions: Set<String> = ["app", "bundle", "framework", "photoslibrary", "musiclibrary", "tvlibrary", "fcpbundle", "imovielibrary"]

    /// A path with any links in it followed, so two ways of writing one place compare equal.
    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// "abc" for "Title [abc]".
    private static func bracketID(_ path: String) -> String? {
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard stem.hasSuffix("]"), let open = stem.lastIndex(of: "[") else { return nil }
        let id = stem[stem.index(after: open)..<stem.index(before: stem.endIndex)]
        return id.isEmpty ? nil : String(id)
    }

    /// Looks at every record's file. One that is where it should be has its
    /// size noted. One that is gone is looked for in `folders` (the folders
    /// downloads are saved to) and in the folder it was in: a file of exactly
    /// the same size and kind that no record points at is taken for it when
    /// its name is the same or carries the video's id, or when nothing else
    /// could be meant. Otherwise the record is marked missing. Nothing is
    /// ever moved or renamed here.
    @discardableResult
    public func refreshFiles(searchIn folders: [String] = [], fileLimit: Int = 50_000) -> FileCheck {
        struct Row { let id: String; let path: String; let bytes: Int64?; let videoID: String; let missing: Bool }
        let rows = ((try? db.run("SELECT id, path, bytes, video_id, missing FROM records ORDER BY added")) ?? []).compactMap { row -> Row? in
            guard let id = row[0].string, let path = row[1].string else { return nil }
            return Row(id: id, path: path, bytes: row[2].int, videoID: row[3].string ?? "", missing: row[4].int == 1)
        }
        var check = FileCheck()
        var gone: [Row] = []
        var present = Set<String>()
        var updates: [(sql: String, values: [SQLValue])] = []
        for row in rows {
            if let size = Self.size(of: row.path) {
                present.insert(Self.resolved(row.path))
                if row.missing || row.bytes != size {
                    updates.append(("UPDATE records SET bytes = ?, missing = 0 WHERE id = ?", [.integer(size), .text(row.id)]))
                }
            } else {
                gone.append(row)
            }
        }

        // Only a file whose size is known can be recognised elsewhere.
        let wanted = Set(gone.compactMap(\.bytes))
        var candidates: [Int64: [String]] = [:]
        if !wanted.isEmpty {
            var places: [String] = []
            for folder in folders + gone.map({ ($0.path as NSString).deletingLastPathComponent })
            where !folder.isEmpty && !places.contains(folder) && !places.contains(where: { folder.hasPrefix($0 + "/") }) {
                places.removeAll { $0.hasPrefix(folder + "/") }
                places.append(folder)
            }
            var seen = 0
            search: for place in places {
                // Paths are built from the folder as it was given, so a found
                // file is named the way the person's folders are.
                guard let walker = FileManager.default.enumerator(atPath: place) else { continue }
                for case let relative as String in walker {
                    let name = (relative as NSString).lastPathComponent
                    let attributes = walker.fileAttributes
                    let kind = attributes?[.type] as? FileAttributeType
                    if kind == .typeDirectory {
                        // Hidden folders and bundles (an app, a photo library) are not where downloads are kept.
                        if name.hasPrefix(".") || Self.bundleExtensions.contains((name as NSString).pathExtension.lowercased()) {
                            walker.skipDescendants()
                        }
                        continue
                    }
                    seen += 1
                    if seen > fileLimit { break search }
                    guard kind == .typeRegular, !name.hasPrefix("."),
                          let size = (attributes?[.size] as? NSNumber)?.int64Value, wanted.contains(size) else { continue }
                    let path = (place as NSString).appendingPathComponent(relative)
                    if !present.contains(Self.resolved(path)) { candidates[size, default: []].append(path) }
                }
            }
        }

        var claimed = Set<String>()
        for row in gone {
            var found: String?
            if let bytes = row.bytes {
                let ext = (row.path as NSString).pathExtension.lowercased()
                let name = (row.path as NSString).lastPathComponent
                let options = (candidates[bytes] ?? []).filter { path in
                    guard !claimed.contains(path), (path as NSString).pathExtension.lowercased() == ext else { return false }
                    // A name that carries another video's id is another video.
                    if let id = Self.bracketID(path), !row.videoID.isEmpty, id != row.videoID { return false }
                    return true
                }
                let sure = options.filter { path in
                    (path as NSString).lastPathComponent == name || (!row.videoID.isEmpty && Self.bracketID(path) == row.videoID)
                }
                if sure.count == 1 {
                    found = sure[0]
                } else if sure.isEmpty, options.count == 1 {
                    let rivals = gone.filter { $0.id != row.id && $0.bytes == bytes && ($0.path as NSString).pathExtension.lowercased() == ext }
                    if rivals.isEmpty { found = options[0] }
                }
            }
            if let found {
                claimed.insert(found)
                check.found += 1
                updates.append(("UPDATE records SET path = ?, missing = 0 WHERE id = ?", [.text(found), .text(row.id)]))
            } else {
                check.missing += 1
                if !row.missing { updates.append(("UPDATE records SET missing = 1 WHERE id = ?", [.text(row.id)])) }
            }
        }

        if !updates.isEmpty {
            try? db.transaction {
                for update in updates { try db.run(update.sql, update.values) }
            }
            changed()
        }
        return check
    }
}
