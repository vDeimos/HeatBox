import Foundation

/// A running process, told apart from any later process that is given the
/// same number by the moment it started.
public struct ProcessIdentity: Codable, Equatable, Sendable {
    public var pid: Int32
    /// Seconds since 1970, as the system records it.
    public var startedAt: Double

    public init(pid: Int32, startedAt: Double) {
        self.pid = pid
        self.startedAt = startedAt
    }

    /// The identity of a process that is running now, or nil when there is none with that number.
    public static func of(_ pid: Int32) -> ProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ProcessIdentity(pid: pid, startedAt: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }

    public var isStillRunning: Bool {
        guard let current = Self.of(pid) else { return false }
        return abs(current.startedAt - startedAt) < 0.001
    }

    /// Ends the process and everything in its process group. It is asked
    /// first, so a download tool can write out what it holds in memory, and
    /// after `grace` it is made to. Does nothing when the process has already
    /// ended or its number now belongs to something else. Returns true when
    /// something was stopped.
    @discardableResult
    public func stopGroup(grace: TimeInterval = 1.5) -> Bool {
        guard isStillRunning else { return false }
        kill(pid, SIGINT)
        let polite = Date().addingTimeInterval(grace)
        while isStillRunning && Date() < polite { usleep(20_000) }
        // Whether or not it went: whatever is left of its group goes now.
        if kill(-pid, SIGKILL) != 0 && isStillRunning { kill(pid, SIGKILL) }
        let deadline = Date().addingTimeInterval(3)
        while isStillRunning && Date() < deadline { usleep(20_000) }
        return true
    }
}
