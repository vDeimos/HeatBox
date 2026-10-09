import Foundation

/// Starting a download at a chosen time (Phobos's rules).
public enum Schedule {
    /// The next moment the clock reads `hour:minute`, strictly after `now`.
    public static func nextOccurrence(hour: Int, minute: Int, after now: Date, calendar: Calendar = .current) -> Date {
        var parts = DateComponents()
        parts.hour = hour
        parts.minute = minute
        parts.second = 0
        return calendar.nextDate(after: now, matching: parts, matchingPolicy: .nextTime) ?? now.addingTimeInterval(3600)
    }

    /// The next time the clock shows the hour and minute of `picked`.
    public static func nextOccurrence(matching picked: Date, after now: Date, calendar: Calendar = .current) -> Date {
        let parts = calendar.dateComponents([.hour, .minute], from: picked)
        return nextOccurrence(hour: parts.hour ?? 0, minute: parts.minute ?? 0, after: now, calendar: calendar)
    }
}

/// A ceiling on how fast downloads may go. It is a default set in Settings
/// (plan Rule 6); a recipe that names its own limit keeps it.
public enum SpeedLimit {
    /// Kilobytes per second, as offered in Settings; 0 means no limit.
    public static let options: [(kilobytes: Int, label: String)] = [
        (0, Messages.speedNoLimit), (512, "500 KB/s"), (1024, "1 MB/s"),
        (2048, "2 MB/s"), (5120, "5 MB/s"), (10240, "10 MB/s"),
    ]

    /// Bytes per second, or nil for no limit.
    public static func bytesPerSecond(kilobytes: Int) -> Int? {
        kilobytes > 0 ? kilobytes * 1024 : nil
    }

    /// The limit as a recipe writes it ("2048K"), or nil for no limit.
    public static func rateArgument(kilobytes: Int) -> String? {
        kilobytes > 0 ? "\(kilobytes)K" : nil
    }
}
