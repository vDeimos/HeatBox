import Foundation

/// Splits the Extra arguments box into arguments and allows only the options
/// that change how a download is chosen, paced, named or fetched. A preset can
/// be shared, so what it says must never be able to run programs, load other
/// configuration, read or write files outside the download, or add links
/// (plan Section 1, "Deliberately left out").
///
/// This is an allowlist, not a denylist: an option that is not listed is
/// refused, so a new or obscure yt-dlp option (or an abbreviation or alias of
/// one) cannot get past the check. Names must match exactly.
public enum ExtraArgsPolicy {
    public enum Problem: Equatable, Sendable {
        /// An option that is refused, as the user typed it.
        case refused(option: String, reason: Reason)
        /// A quote that is never closed, or a backslash with nothing after it.
        case unfinished
    }

    public enum Reason: String, Sendable {
        /// Not on the list of options that may be used.
        case notAllowed
        /// A word that is not an option. yt-dlp would take it as another link.
        case notAnOption
        /// An option that takes a value, with none after it.
        case missingValue
        /// The end-of-options marker, which would let the extra words add links.
        case endsOptions
    }

    public struct Verdict: Equatable, Sendable {
        public let arguments: [String]
        public let problems: [Problem]
        public var isAllowed: Bool { problems.isEmpty }
    }

    /// Long options that may be used, with the number of values each takes.
    /// Each one only shapes what is chosen, paced or fetched. Deliberately not
    /// here: anything that runs a program or a downloader (`--exec`,
    /// `--downloader`, `--postprocessor-args`), loads code or configuration
    /// (`--config-locations`, `--plugin-dirs`, `--remote-components`,
    /// `--js-runtimes`), reads or writes a file (`--batch-file`, `--cookies`,
    /// `--download-archive`, `--print-to-file`, `--load-info-json`), changes
    /// where files go (`--output`, `--paths`, `--parse-metadata`,
    /// `--replace-in-metadata`), sends requests to an address of its own
    /// (`--sponsorblock-api`), or changes the tools (`--update`, `--alias`,
    /// `--preset-alias`, `--ffmpeg-location`).
    static let allowedLongOptions: [String: Int] = [
        // Flags
        "--abort-on-unavailable-fragments": 0, "--skip-unavailable-fragments": 0,
        "--allow-dynamic-mpd": 0, "--audio-multistreams": 0, "--no-audio-multistreams": 0,
        "--video-multistreams": 0, "--no-video-multistreams": 0,
        "--break-on-existing": 0, "--no-break-on-existing": 0, "--break-per-input": 0,
        "--check-formats": 0, "--no-check-formats": 0,
        "--continue": 0, "--no-continue": 0,
        "--force-ipv4": 0, "--force-ipv6": 0,
        "--force-keyframes-at-cuts": 0, "--no-force-keyframes-at-cuts": 0,
        "--geo-bypass": 0, "--no-geo-bypass": 0,
        "--ignore-errors": 0, "--no-warnings": 0, "--quiet": 0,
        "--keep-fragments": 0, "--no-keep-fragments": 0, "--keep-video": 0,
        "--legacy-server-connect": 0, "--no-check-certificates": 0, "--prefer-insecure": 0,
        "--lazy-playlist": 0, "--no-lazy-playlist": 0, "--playlist-random": 0,
        "--mtime": 0, "--no-mtime": 0, "--part": 0, "--no-part": 0,
        "--live-from-start": 0, "--no-live-from-start": 0,
        "--no-overwrites": 0, "--no-playlist": 0, "--yes-playlist": 0,
        "--no-sponsorblock": 0, "--prefer-free-formats": 0, "--no-prefer-free-formats": 0,
        "--resize-buffer": 0, "--no-resize-buffer": 0,
        "--hls-use-mpegts": 0, "--no-hls-use-mpegts": 0,
        // Values
        "--age-limit": 1, "--buffer-size": 1, "--concurrent-fragments": 1,
        "--date": 1, "--dateafter": 1, "--datebefore": 1,
        "--download-sections": 1, "--extractor-args": 1, "--extractor-retries": 1,
        "--file-access-retries": 1, "--format": 1, "--format-sort": 1,
        "--fragment-retries": 1, "--geo-bypass-country": 1, "--geo-verification-proxy": 1, "--http-chunk-size": 1,
        "--impersonate": 1, "--limit-rate": 1, "--match-filter": 1, "--match-filters": 1, "--break-match-filters": 1,
        "--max-downloads": 1, "--max-filesize": 1, "--min-filesize": 1,
        "--max-sleep-interval": 1, "--min-sleep-interval": 1, "--sleep-interval": 1,
        "--sleep-requests": 1, "--sleep-subtitles": 1,
        "--playlist-end": 1, "--playlist-items": 1, "--playlist-start": 1,
        "--proxy": 1, "--retries": 1, "--skip-playlist-after-errors": 1,
        "--socket-timeout": 1, "--source-address": 1, "--throttled-rate": 1,
        "--xff": 1, "--wait-for-video": 1,
        "--audio-format": 1, "--audio-quality": 1, "--merge-output-format": 1,
        "--recode-video": 1, "--remux-video": 1, "--remove-chapters": 1,
        "--sponsorblock-chapter-title": 1, "--sponsorblock-mark": 1, "--sponsorblock-remove": 1,
        "--sub-format": 1, "--sub-langs": 1, "--convert-subs": 1, "--convert-thumbnails": 1,
    ]

    /// Short options that may be used, with the number of values each takes.
    static let allowedShortOptions: [Character: Int] = [
        "4": 0, "6": 0, "c": 0, "i": 0, "k": 0, "q": 0, "w": 0,
        "f": 1, "I": 1, "N": 1, "R": 1, "r": 1, "S": 1,
    ]

    public static func check(_ text: String) -> Verdict {
        guard let tokens = tokenize(text) else { return Verdict(arguments: [], problems: [.unfinished]) }
        var problems: [Problem] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            if token == "--" {
                problems.append(.refused(option: token, reason: .endsOptions))
            } else if token.hasPrefix("--") {
                // `--name` or `--name=value`; the name is matched exactly.
                let parts = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = String(parts[0])
                guard let values = allowedLongOptions[name] else {
                    problems.append(.refused(option: token, reason: .notAllowed))
                    continue
                }
                if parts.count == 2 {
                    if values == 0 { problems.append(.refused(option: token, reason: .notAllowed)) }
                } else if values == 1 {
                    if index < tokens.count { index += 1 } else { problems.append(.refused(option: token, reason: .missingValue)) }
                }
            } else if token.hasPrefix("-") && token.count > 1 {
                // `-N` takes the next word, `-N8` has its value attached. Clumps such as `-ik` are refused.
                let letter = token[token.index(after: token.startIndex)]
                guard let values = allowedShortOptions[letter] else {
                    problems.append(.refused(option: token, reason: .notAllowed))
                    continue
                }
                if token.count == 2 {
                    if values == 1 {
                        if index < tokens.count { index += 1 } else { problems.append(.refused(option: token, reason: .missingValue)) }
                    }
                } else if values == 0 {
                    problems.append(.refused(option: token, reason: .notAllowed))
                }
            } else {
                problems.append(.refused(option: token, reason: .notAnOption))
            }
        }
        return Verdict(arguments: tokens, problems: problems)
    }

    /// Words split the way a shell would, without running one: quotes group,
    /// a backslash escapes. Nil when a quote is never closed or the text ends
    /// in a backslash.
    public static func tokenize(_ text: String) -> [String]? {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        var inToken = false
        for character in text {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\" && quote != "'" {
                escaping = true
                inToken = true
                continue
            }
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                inToken = true
                continue
            }
            if character.isWhitespace {
                if inToken {
                    tokens.append(current)
                    current = ""
                    inToken = false
                }
                continue
            }
            current.append(character)
            inToken = true
        }
        if quote != nil || escaping { return nil }
        if inToken { tokens.append(current) }
        return tokens
    }
}
