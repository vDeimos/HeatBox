import Foundation

/// Trying again after a download fails for a reason that may pass (Phobos's
/// rules): which failures are worth another go, how long to wait, and when
/// to give up.
public enum RetryPolicy {
    /// Wording that means the problem is the site's or the connection's, and
    /// waiting a little may fix it.
    private static let passing = [
        "timed out", "timeout", "connection reset", "connection refused", "connection aborted",
        "remote end closed", "incompleteread", "incomplete read", "broken pipe",
        "nodename nor servname", "temporary failure in name resolution", "failed to resolve",
        "network is unreachable", "no route to host", "network connection was lost",
        "internet connection appears to be offline", "ssl:", "eof occurred",
        "http error 500", "http error 502", "http error 503", "http error 504",
        "http error 429", "too many requests", "unable to download",
    ]

    /// Wording that means trying again would only fail the same way.
    private static let lasting = [
        "http error 400", "http error 401", "http error 403", "http error 404", "http error 410",
        "private video", "sign in", "members-only", "members only", "video unavailable",
        "not available", "has been removed", "copyright", "unsupported url", "age-restricted",
        "confirm your age", "premiere", "live event", "drm", "no video formats",
    ]

    /// Whether a kind of failure may pass by itself. Nil when the kind does
    /// not say, and the tool's wording has to decide.
    public static func isPassing(_ kind: ErrorKind) -> Bool? {
        switch kind {
        case .unreachable, .rateLimited: return true
        case .unknown: return nil
        case .unviewablePlaylist, .protected, .signInExpired, .membersOnly, .signInRequired, .privateVideo,
             .regionBlocked, .unavailable, .notFound, .refused, .upcoming, .unsupportedSite, .diskFull, .toolOutOfDate:
            return false
        }
    }

    /// True when the tool's last line describes a problem that may pass.
    /// A lasting problem wins when a line mentions both.
    public static func isPassing(_ line: String) -> Bool {
        let lower = line.lowercased()
        guard !lower.trimmed.isEmpty else { return false }
        if lasting.contains(where: { lower.contains($0) }) { return false }
        if let verdict = isPassing(ErrorTranslator.translate(line).kind) { return verdict }
        return passing.contains(where: { lower.contains($0) })
    }

    /// Seconds between one attempt and the next.
    public static let waits: [TimeInterval] = [15, 60, 180]

    public static var maxAttempts: Int { waits.count }

    /// Seconds to wait before the next attempt, or nil when the attempts are
    /// used up. `attempt` is how many retries have already been made.
    public static func delay(afterAttempt attempt: Int) -> TimeInterval? {
        attempt >= 0 && attempt < waits.count ? waits[attempt] : nil
    }
}
