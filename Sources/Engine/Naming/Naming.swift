import Foundation

public enum NameStyle: String, CaseIterable, Codable, Sendable {
    case title
    case uploaderTitle
    case dateTitle
}

/// The facts about a video that a file name can be built from.
public struct VideoFacts: Equatable, Codable, Sendable {
    public var id: String
    public var title: String
    public var uploader: String
    /// As the download tool reports it: "20261004". Nil when the site gives none.
    public var uploadDate: String?

    public init(id: String, title: String, uploader: String, uploadDate: String? = nil) {
        self.id = id
        self.title = title
        self.uploader = uploader
        self.uploadDate = uploadDate
    }
}

/// The one place that decides what files are called. Together with
/// `FolderRules`, no other file builds a destination path or a file name.
public enum Naming {
    /// The longest name a disk is sure to take. macOS's own disks count 255
    /// UTF-16 units; network shares and disks from other systems count 255
    /// UTF-8 bytes. A name within both fits everywhere.
    public static let nameLimit = 255
    /// How much of a name the title part may use. The rest is kept for what
    /// is added after it: " (clip)", " (9999)", ".encoded" and an ending
    /// such as ".en-orig.vtt".
    public static let stemLimit = 200
    /// Room for the number a taken name is given: " (9999)".
    static let numberRoom = 7

    /// How much room a piece of a name takes: its UTF-8 bytes, or its UTF-16
    /// units once accents are written separately (as some disks store them),
    /// whichever is more. A letter of Chinese is 3, most emoji 4, a family
    /// emoji 25, though each is one character on screen.
    static func size(_ text: String) -> Int {
        max(text.utf8.count, text.decomposedStringWithCanonicalMapping.utf16.count)
    }

    /// The start of `text` that fits in `size` (see `size(_:)`), cut between
    /// two characters as a person sees them, never inside one, and without a
    /// space or a full stop left at the end. May be empty.
    public static func shortened(_ text: String, toSize limit: Int) -> String {
        guard size(text) > limit else { return text }
        var result = ""
        var used = 0
        for character in text {
            let cost = size(String(character))
            if used + cost > limit { break }
            result.append(character)
            used += cost
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }

    /// A stem cut so that it, a number for a taken name and `ending` together
    /// make a name every disk takes. Short names come back unchanged.
    public static func stem(_ stem: String, fitting ending: String) -> String {
        let room = max(nameLimit - numberRoom - size(ending), 16)
        let cut = shortened(stem, toSize: room)
        return cut.isEmpty ? stem : cut
    }

    /// Makes text safe to use as one file or folder name on macOS. The result
    /// never contains a slash and is never "." or "..", so a title cannot
    /// steer a file out of its folder. It is at most `limit` characters and,
    /// however those characters are stored, at most `size` on disk.
    public static func clean(_ text: String, limit: Int = 120, size: Int = Naming.stemLimit) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            if scalar == "/" || scalar == ":" {
                result.append("-")
            } else if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) {
                result.append(" ")
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        while result.contains("  ") { result = result.replacingOccurrences(of: "  ", with: " ") }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if result.count > limit {
            result = String(result.prefix(limit)).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        }
        result = shortened(result, toSize: size)
        return result.isEmpty ? "Untitled" : result
    }

    /// The file name, without extension, for a video in the chosen style.
    /// Never more than `stemLimit` on disk, whatever the style puts in front
    /// of the title.
    public static func fileStem(style: NameStyle, facts: VideoFacts) -> String {
        switch style {
        case .title:
            return clean(facts.title)
        case .uploaderTitle:
            guard !facts.uploader.isEmpty else { return clean(facts.title) }
            let front = clean(facts.uploader, limit: 60, size: 60) + " - "
            return front + clean(facts.title, size: stemLimit - size(front))
        case .dateTitle:
            guard let raw = facts.uploadDate, raw.count == 8, raw.allSatisfy({ $0.isASCII && $0.isNumber }) else { return clean(facts.title) }
            let year = raw.prefix(4)
            let month = raw.dropFirst(4).prefix(2)
            let day = raw.suffix(2)
            let front = "\(year)-\(month)-\(day) "
            return front + clean(facts.title, size: stemLimit - size(front))
        }
    }

    /// A path that does not collide with an existing file: "Title.mp4",
    /// then "Title (2).mp4", "Title (3).mp4", and so on.
    public static func uniquePath(directory: String, stem: String, ext: String,
                                  exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        let suffix = ext.isEmpty ? "" : "." + ext
        let stem = Naming.stem(stem, fitting: suffix)
        var candidate = (directory as NSString).appendingPathComponent(stem + suffix)
        var number = 2
        while exists(candidate) && number < 10_000 {
            candidate = (directory as NSString).appendingPathComponent("\(stem) (\(number))\(suffix)")
            number += 1
        }
        return candidate
    }

    /// A folder as a person would say it: "/Users/sam/Movies/YouTube" becomes
    /// "Movies › YouTube". Folders outside the home folder keep their full path.
    public static func breadcrumb(_ path: String, home: String = NSHomeDirectory()) -> String {
        let prefix = home.hasSuffix("/") ? home : home + "/"
        guard path.hasPrefix(prefix) else { return path == home ? "Home" : path }
        let parts = path.dropFirst(prefix.count).split(separator: "/").map(String.init)
        return parts.isEmpty ? "Home" : parts.joined(separator: " › ")
    }

    /// A tidy site name from what the download tool calls the site.
    public static func siteName(extractorKey: String, domain: String?) -> String {
        var key = extractorKey
        for suffix in ["Tab", "Playlist", "User", "Channel", "Album", "Collection", "Vod", "Clips", "Stream", "Search"]
        where key.hasSuffix(suffix) && key.count > suffix.count {
            key = String(key.dropLast(suffix.count))
            break
        }
        let pretty: [String: String] = [
            "youtube": "YouTube", "twitter": "X", "tiktok": "TikTok", "soundcloud": "SoundCloud",
            "vimeo": "Vimeo", "twitch": "Twitch", "reddit": "Reddit", "instagram": "Instagram",
            "facebook": "Facebook", "bandcamp": "Bandcamp", "dailymotion": "Dailymotion",
        ]
        var name = pretty[key.lowercased()] ?? key
        if key.isEmpty || key == "Generic" {
            if let domain, !domain.isEmpty { name = domain } else { name = "Other" }
        }
        return clean(name, limit: 60)
    }
}
