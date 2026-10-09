import Foundation

/// The time, as the engine sees it. The queue waits on this for scheduled
/// downloads and for the pause before a retry, so tests can move time by hand.
public protocol EngineClock: Sendable {
    func now() -> Date
    /// Returns once `deadline` has passed. Throws when the task is cancelled first.
    func sleep(until deadline: Date) async throws
}

extension EngineClock {
    /// What `work` returns, or nil when `seconds` pass first. Whichever
    /// loses is cancelled, so a tool that `work` is waiting on is stopped.
    func limited<T: Sendable>(to seconds: TimeInterval, _ work: @escaping @Sendable () async -> T) async -> T? {
        let deadline = now().addingTimeInterval(seconds)
        return await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await self.sleep(until: deadline)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// The Mac's own clock.
public struct SystemClock: EngineClock {
    public init() {}

    public func now() -> Date { Date() }

    /// Waits in short steps and looks at the wall clock after each, so a
    /// download scheduled for 2:00 still starts at 2:00 when the Mac slept
    /// in between or its clock was changed.
    public func sleep(until deadline: Date) async throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return }
            try await Task.sleep(nanoseconds: UInt64(min(remaining, 30) * 1_000_000_000))
        }
    }
}
