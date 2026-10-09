import Foundation

/// What the tools printed while a job ran, for the Queue screen's Log view.
/// It is bounded twice over: a line is cut at `maxLineLength` bytes as it is
/// read, and only the newest `maxLines` are kept. Progress lines are not log
/// lines. The log lives in memory and is not saved with the queue.
public struct JobLog: Equatable, Sendable {
    public static let maxLines = 2000
    /// Given to `ProcessRunner.start` for every tool a job runs.
    public static let maxLineLength = 4000

    public private(set) var lines: [String] = []
    /// How many older lines were let go to stay within `maxLines`.
    public private(set) var dropped = 0
    private let limit: Int

    public init(limit: Int = JobLog.maxLines) {
        self.limit = max(1, limit)
    }

    public mutating func append(_ line: String) {
        lines.append(line)
        // Let go of a batch at a time, so a chatty tool does not shift the array on every line.
        let slack = max(1, limit / 10)
        if lines.count >= limit + slack {
            let extra = lines.count - limit
            lines.removeFirst(extra)
            dropped += extra
        }
    }

    /// The whole log as text, saying so when its beginning is gone.
    public var text: String {
        ((dropped > 0 ? [Messages.logDropped(dropped)] : []) + lines).joined(separator: "\n")
    }
}
