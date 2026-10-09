import Foundation

/// Keeps the download archive in step with the Library.
///
/// The archive is the download tool's own list of what it has fetched, one
/// "site id" line per video, which a recipe can ask it to skip. The tool only
/// ever adds to it. So when a file is moved to the Trash, or is gone and the
/// person asks for it again, its line is taken out here; otherwise the tool
/// would answer "already downloaded" for a video that is no longer there.
/// Undoing a move to the Trash puts the line back.
public struct ArchiveBridge: Equatable, Sendable {
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    public init(paths: AppPaths) {
        self.init(file: paths.archiveFile)
    }

    /// The line the tool writes for a video: its name for the site, in small
    /// letters, and the video's id. Nil when either is missing.
    public static func entry(extractorKey: String, videoID: String) -> String? {
        let key = extractorKey.trimmed.lowercased()
        let id = videoID.trimmed
        guard !key.isEmpty, !id.isEmpty, !key.contains(where: \.isWhitespace), !id.contains(where: \.isNewline) else { return nil }
        return "\(key) \(id)"
    }

    private func lines() -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }

    public func contains(_ entry: String) -> Bool {
        lines().contains(entry)
    }

    /// Takes lines out. Everything else stays as it was, in its order.
    /// Returns how many lines were removed.
    @discardableResult
    public func forget(_ entries: [String]) -> Int {
        let unwanted = Set(entries)
        let current = lines()
        guard !unwanted.isEmpty, !current.isEmpty else { return 0 }
        let kept = current.filter { !unwanted.contains($0) }
        guard kept.count != current.count else { return 0 }
        let text = kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
        try? Data(text.utf8).write(to: file, options: .atomic)
        return current.count - kept.count
    }

    /// Adds lines that are not there yet. An archive that does not exist is
    /// left alone: nothing has asked for one.
    public func remember(_ entries: [String]) {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        var current = lines()
        var changed = false
        for entry in entries where !entry.isEmpty && !current.contains(entry) {
            current.append(entry)
            changed = true
        }
        guard changed else { return }
        try? Data((current.joined(separator: "\n") + "\n").utf8).write(to: file, options: .atomic)
    }
}

/// What the download tool notes about each finished video, for the Library.
public enum DownloadNote {
    /// The template for the line written per finished video (`--print-to-file`).
    public static let template = "after_move:%(.{filepath,id,title,uploader,channel,duration,extractor_key,webpage_url})j"

    public struct Note: Equatable, Sendable {
        public var file: String
        public var videoID: String
        public var title: String
        public var uploader: String
        public var seconds: Double?
        public var extractorKey: String
        public var link: String?

        public var archiveID: String? { ArchiveBridge.entry(extractorKey: extractorKey, videoID: videoID) }
    }

    public static func note(fromLine line: String) -> Note? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let file = object["filepath"] as? String, !file.isEmpty else { return nil }
        func text(_ key: String) -> String {
            guard let value = object[key] as? String, value != "NA" else { return "" }
            return value
        }
        let uploader = text("uploader").isEmpty ? text("channel") : text("uploader")
        let link = text("webpage_url")
        return Note(file: file, videoID: text("id"), title: text("title"), uploader: uploader,
                    seconds: Probe.number(object["duration"]), extractorKey: text("extractor_key"),
                    link: Links.isWebLink(link) ? link : nil)
    }

    /// The note for one finished file among the lines written so far. The
    /// newest wins: a file downloaded again in a later run is described again.
    public static func note(for file: String, inLines text: String) -> Note? {
        let wanted = URL(fileURLWithPath: file).standardizedFileURL.path
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            if let note = note(fromLine: String(line)), URL(fileURLWithPath: note.file).standardizedFileURL.path == wanted {
                return note
            }
        }
        return nil
    }
}
