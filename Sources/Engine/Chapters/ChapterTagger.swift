import Foundation

/// The download tool copies the whole video's tags onto every file it splits
/// off by chapter, so each track would carry the album's title and no track
/// number. This plans the retagging of each chapter file (Studio's
/// `ChapterTagger`): its own title, "track N/total" and the cover, by stream
/// copy, without re-encoding. Planning only; the stage that runs FFmpeg is in
/// `Jobs/Stages`.
public enum ChapterTagger {
    public struct Track: Equatable, Sendable {
        public let path: String
        public let title: String
        public let artist: String?
    }

    /// What the download tool notes for one finished video: the file, and
    /// the files split off it by chapter.
    public struct Record: Equatable, Sendable {
        public let file: String
        public let tracks: [Track]
    }

    /// A cover picture taken out of a file.
    public struct Cover: Equatable, Sendable {
        public let path: String
        public let mime: String
    }

    /// The template for the line the download tool writes per finished video
    /// (`--print-to-file`): the final path and the chapter list, as one JSON object.
    public static let recordTemplate = "after_move:%(.{filepath,chapters})j"

    /// File endings whose tags FFmpeg can rewrite with a stream copy.
    public static let taggableExtensions: Set<String> = ["mp3", "m4a", "flac", "opus", "ogg"]

    /// Reads one line written with `recordTemplate`. Track titles are tidied
    /// by the recipe's music-tag settings, like the video's own title.
    public static func record(fromLine line: String, recipe: DownloadRecipe) -> Record? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let file = object["filepath"] as? String else { return nil }
        let chapters = (object["chapters"] as? [[String: Any]]) ?? []
        let tracks = chapters.compactMap { chapter -> Track? in
            // Only files the tool really split off, named in full.
            guard let path = chapter["filepath"] as? String, path.hasPrefix("/") else { return nil }
            var title = (chapter["title"] as? String) ?? ""
            var artist: String?
            if recipe.cleanTitles { title = clean(title) }
            if recipe.stripTitleNumbers { title = stripTrackNumber(title) }
            if recipe.splitArtistTitle, let pair = splitArtist(title) {
                artist = pair.artist
                title = recipe.stripTitleNumbers ? stripTrackNumber(pair.title) : pair.title
            }
            if title.isEmpty { title = ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
            return Track(path: path, title: title, artist: artist)
        }
        return Record(file: file, tracks: tracks)
    }

    /// The record for one finished file among the lines written so far.
    public static func record(for file: String, inLines text: String, recipe: DownloadRecipe) -> Record? {
        let wanted = URL(fileURLWithPath: file).standardizedFileURL.path
        for line in text.split(separator: "\n").reversed() {
            if let record = record(fromLine: String(line), recipe: recipe),
               URL(fileURLWithPath: record.file).standardizedFileURL.path == wanted { return record }
        }
        return nil
    }

    // MARK: Titles

    /// Python's named groups, as Foundation writes them.
    private static func foundation(_ pattern: String) -> String { pattern.replacingOccurrences(of: "(?P<", with: "(?<") }

    static func clean(_ title: String) -> String {
        guard let pattern = try? NSRegularExpression(pattern: MusicTags.junkTitlePattern) else { return title }
        return pattern.stringByReplacingMatches(in: title, range: NSRange(title.startIndex..., in: title), withTemplate: "").trimmed
    }

    /// "01. One More Time" becomes "One More Time"; "7 Rings" stays "7 Rings".
    static func stripTrackNumber(_ title: String) -> String {
        guard let pattern = try? NSRegularExpression(pattern: foundation(MusicTags.numberStrippingPattern(into: "t"))),
              let match = pattern.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let range = Range(match.range(withName: "t"), in: title) else { return title }
        let stripped = String(title[range]).trimmed
        return stripped.isEmpty ? title : stripped
    }

    static func splitArtist(_ title: String) -> (artist: String, title: String)? {
        guard let pattern = try? NSRegularExpression(pattern: foundation(MusicTags.artistTitlePattern)),
              let match = pattern.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let artist = Range(match.range(withName: "ta"), in: title),
              let song = Range(match.range(withName: "tt"), in: title) else { return nil }
        return (String(title[artist]).trimmed, String(title[song]).trimmed)
    }

    // MARK: Commands

    private static let quiet = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"]

    /// Takes the cover picture out of a file, untouched, into `output`.
    public static func coverArguments(input: String, output: String) -> [String] {
        quiet + ["-i", input, "-map", "0:v:0", "-c", "copy", "-f", "image2", output]
    }

    /// Makes a smaller JPEG of a picture, at most 1000 points wide. An Ogg
    /// cover travels inside a tag, which has to stay small.
    public static func smallCoverArguments(input: String, output: String) -> [String] {
        quiet + ["-i", input, "-frames:v", "1", "-vf", "scale='min(1000,iw)':-2", "-q:v", "3", "-f", "image2", "-c:v", "mjpeg", output]
    }

    /// The largest picture tag that is passed to FFmpeg, in characters.
    public static let maxPictureBlock = 600_000

    /// The kind of picture, from its first bytes. Nil when it is neither PNG nor JPEG.
    public static func mime(of image: Data) -> String? {
        if image.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if image.starts(with: [0xFF, 0xD8]) { return "image/jpeg" }
        return nil
    }

    /// Rewrites one track's tags into the new file `output`. For Ogg the
    /// cover goes in as `pictureBlock`; for the rest as a second input.
    public static func retagArguments(track: Track, index: Int, total: Int, cover: Cover?, pictureBlock: String?,
                                      output: String) -> [String] {
        let ext = (track.path as NSString).pathExtension.lowercased()
        let isOgg = Loudness.isOgg(ext)
        let coverInput = isOgg ? nil : cover
        var a = quiet + ["-i", track.path]
        if let coverInput { a += ["-i", coverInput.path] }
        a += ["-map", "0:a"]
        if coverInput != nil { a += ["-map", "1:0"] }
        a += ["-c", "copy"]
        // Ogg keeps tags on the audio stream: lift them to the file and clear
        // the stream's copy, or the old title there would win over the new one.
        a += isOgg ? ["-map_metadata", "0:s:a:0", "-map_metadata:s:a", "-1"] : ["-map_metadata", "0"]
        if coverInput != nil { a += ["-disposition:v:0", "attached_pic"] }
        if ext == "mp3" { a += ["-id3v2_version", "3"] }
        a += ["-metadata", "title=\(track.title)", "-metadata", "track=\(index + 1)/\(total)"]
        if let artist = track.artist { a += ["-metadata", "artist=\(artist)"] }
        if isOgg, let pictureBlock { a += ["-metadata", "METADATA_BLOCK_PICTURE=\(pictureBlock)"] }
        a.append(output)
        return a
    }

    /// An Ogg file's cover: a FLAC picture block, base64, for the
    /// `METADATA_BLOCK_PICTURE` tag.
    public static func pictureBlock(image: Data, mime: String) -> String {
        var block = Data()
        func u32(_ value: Int) {
            var bigEndian = UInt32(value).bigEndian
            withUnsafeBytes(of: &bigEndian) { block.append(contentsOf: $0) }
        }
        let mimeData = Data(mime.utf8)
        u32(3)                               // picture type: front cover
        u32(mimeData.count); block.append(mimeData)
        u32(0)                               // no description
        u32(0); u32(0); u32(0); u32(0)       // width, height, depth, colours: unknown is allowed
        u32(image.count); block.append(image)
        return block.base64EncodedString()
    }
}
