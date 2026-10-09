import Foundation

/// What went wrong, as far as the download tool's wording reveals it. The
/// kind lets later code act on a failure (offer an update, a sign-in, a
/// retry) without matching on sentences.
public enum ErrorKind: String, Sendable, Equatable, CaseIterable {
    case unviewablePlaylist
    case protected
    case signInExpired
    case membersOnly
    case signInRequired
    case privateVideo
    case regionBlocked
    case unavailable
    /// The address leads nowhere (the site answered "not found" or "gone").
    case notFound
    /// The site answered "forbidden" or "unauthorized".
    case refused
    /// A scheduled stream or premiere that has not started.
    case upcoming
    case rateLimited
    case unsupportedSite
    case diskFull
    case toolOutOfDate
    case unreachable
    case unknown
}

public struct TranslatedError: Equatable, Sendable {
    public let kind: ErrorKind
    /// One plain sentence with a next step. For `.unknown`, the tool's own
    /// words with the "ERROR:" label removed.
    public let message: String
}

/// Turns the download tool's wording into a plain sentence with a next step.
public enum ErrorTranslator {
    /// The first rule whose phrase appears in the text wins, so order matters:
    /// "members-only" must be seen before the broader "sign in".
    private static let rules: [(kind: ErrorKind, message: String, matches: @Sendable (String) -> Bool)] = [
        (.unviewablePlaylist, Messages.unviewablePlaylist, { $0.contains("playlist type is unviewable") }),
        (.protected, Messages.protected, { $0.contains("drm") }),
        (.signInExpired, Messages.signInExpired, { any($0, "no longer valid", "cookies have expired") }),
        (.membersOnly, Messages.membersOnly, { any($0, "members-only", "join this channel", "available to this channel's members") }),
        (.signInRequired, Messages.signInRequired, { any($0, "not a bot", "confirm your age", "age-restricted", "sign in to confirm") }),
        (.privateVideo, Messages.privateVideo, { $0.contains("private video") }),
        (.regionBlocked, Messages.regionBlocked, { any($0, "available in your country", "available from your location") || ($0.contains("geo") && $0.contains("restrict")) }),
        (.upcoming, Messages.upcoming, { any($0, "will begin in", "premieres in", "premiere will begin") }),
        (.unavailable, Messages.unavailable, { any($0, "video unavailable", "video is unavailable", "has been removed", "does not exist") }),
        (.notFound, Messages.notFound, { any($0, "http error 404", "http error 410") }),
        (.refused, Messages.refused, { any($0, "http error 401", "http error 403") }),
        (.rateLimited, Messages.rateLimited, { any($0, "http error 429", "too many requests", "rate-limit", "rate limit") }),
        (.unsupportedSite, Messages.unsupportedSite, { $0.contains("unsupported url") }),
        (.diskFull, Messages.diskFull, { $0.contains("no space left") }),
        (.toolOutOfDate, Messages.toolOutOfDate, { any($0, "unable to extract", "extraction failed", "requested format is not available", "nsig") }),
        (.unreachable, Messages.unreachable, { any($0, "timed out", "unable to download webpage", "network is unreachable", "getaddrinfo",
                                                      "connection reset", "connection broken", "connection refused", "connection aborted",
                                                      "remote end closed", "incompleteread", "incomplete read", "nodename nor servname") }),
    ]

    private static func any(_ text: String, _ needles: String...) -> Bool {
        needles.contains { text.contains($0) }
    }

    public static func translate(_ raw: String) -> TranslatedError {
        let text = raw.replacingOccurrences(of: "ERROR: ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        for rule in rules where rule.matches(lower) {
            return TranslatedError(kind: rule.kind, message: rule.message)
        }
        return TranslatedError(kind: .unknown, message: text)
    }

    public static func friendly(_ raw: String) -> String {
        translate(raw).message
    }
}
