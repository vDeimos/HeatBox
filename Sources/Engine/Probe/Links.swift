import Foundation

/// Finding links in pasted text and deciding what they point at.
public enum Links {
    /// True for an `http` or `https` address with a host. Nothing else is
    /// ever handed to a tool (plan Rule 4).
    public static func isWebLink(_ text: String) -> Bool {
        guard let parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = parts.host, !host.isEmpty else { return false }
        return true
    }

    /// Every distinct web link in a block of pasted text, in order.
    public static func extract(from text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))
        for piece in text.components(separatedBy: separators) where isWebLink(piece) {
            if seen.insert(piece).inserted { result.append(piece) }
        }
        return result
    }

    /// For a YouTube link that names one video, a link to just that video,
    /// plus the playlist link if the address also named a playlist.
    public static func splitYouTube(_ link: String) -> (video: String, playlist: String?)? {
        guard isWebLink(link), let parts = URLComponents(string: link), let host = parts.host?.lowercased() else { return nil }
        var videoID: String?
        if isHost(host, "youtu.be") {
            let id = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !id.isEmpty { videoID = id }
        } else if isHost(host, "youtube.com") && parts.path == "/watch" {
            videoID = parts.queryItems?.first(where: { $0.name == "v" })?.value
        }
        guard let id = videoID, isIdentifier(id) else { return nil }
        var playlist: String?
        if let list = parts.queryItems?.first(where: { $0.name == "list" })?.value,
           isIdentifier(list), isReadablePlaylist(list) {
            playlist = "https://www.youtube.com/playlist?list=\(list)"
        }
        return ("https://www.youtube.com/watch?v=\(id)", playlist)
    }

    /// YouTube refuses to show some lists to outside programs: the "Mix"
    /// playlists it builds as you watch (RD...), and personal lists such as
    /// Liked videos (LL) and Watch Later (WL). Those are never offered.
    public static func isReadablePlaylist(_ id: String) -> Bool {
        !["RD", "LL", "WL"].contains { id.hasPrefix($0) }
    }

    /// The address a channel's list of videos lives at. A YouTube channel
    /// link such as youtube.com/@name becomes youtube.com/@name/videos;
    /// links to other sites are left alone.
    public static func channelVideosURL(_ link: String) -> String {
        guard var parts = URLComponents(string: link), let host = parts.host?.lowercased(),
              isHost(host, "youtube.com") else { return link }
        var segments = parts.path.split(separator: "/").map(String.init)
        guard let first = segments.first else { return link }
        let isChannel = first.hasPrefix("@") || ["channel", "c", "user"].contains(first)
        guard isChannel else { return link }
        let base = first.hasPrefix("@") ? 1 : 2
        guard segments.count >= base else { return link }
        let tabs = ["featured", "videos", "shorts", "streams", "live", "playlists", "community", "about", "releases"]
        if segments.count == base {
            segments.append("videos")
        } else if tabs.contains(segments[base]) {
            segments = Array(segments.prefix(base)) + ["videos"]
        } else {
            return link
        }
        parts.path = "/" + segments.joined(separator: "/")
        parts.query = nil
        return parts.string ?? link
    }

    /// The single-video form of a link, where one can be worked out.
    public static func singleVideo(_ link: String) -> String {
        splitYouTube(link)?.video ?? link
    }

    // MARK: Links handed to the app

    /// The code for a browser bookmark that sends the current page to the app.
    public static let bookmarklet = "javascript:(function(){location.href='\(Engine.urlScheme)://open?url='+encodeURIComponent(location.href);})();"

    /// The page address carried inside a `<scheme>://open?url=...` link.
    /// It only ever fills in the Download screen; it never starts anything.
    public static func linkFromAppURL(_ url: URL) -> String? {
        guard url.scheme?.lowercased() == Engine.urlScheme, url.host?.lowercased() == "open",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = parts.queryItems?.first(where: { $0.name == "url" })?.value,
              isWebLink(value) else { return nil }
        return value
    }

    /// The address inside a .webloc file, which is what some browsers create
    /// when a link is dragged out of them.
    public static func weblocTarget(_ file: URL) -> String? {
        guard file.pathExtension.lowercased() == "webloc",
              let plist = NSDictionary(contentsOf: file),
              let target = plist["URL"] as? String,
              isWebLink(target) else { return nil }
        return target
    }

    /// The page address in something the system handed the app: one of the
    /// app's own links, a .webloc file, or a web link itself. Nil for
    /// anything else.
    public static func linkFromOpened(_ url: URL) -> String? {
        if url.isFileURL { return weblocTarget(url) }
        if url.scheme?.lowercased() == Engine.urlScheme { return linkFromAppURL(url) }
        return isWebLink(url.absoluteString) ? url.absoluteString : nil
    }

    // MARK: Helpers

    /// True for the site itself or one of its subdomains, and not for a
    /// lookalike such as "notyoutube.com".
    private static func isHost(_ host: String, _ site: String) -> Bool {
        host == site || host.hasSuffix("." + site)
    }

    /// Video and playlist ids are letters, digits, "-" and "_".
    private static func isIdentifier(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" || $0 == "_"
        }
    }
}
