import Foundation

/// Whether there is room for a download (Phase 11). Deciding is separate from
/// asking the disk, so the rule is tested without one.
public enum DiskSpace {
    /// What is kept free beyond the download itself: the app also writes a
    /// working copy, and a re-encode or a merge needs room for the result.
    public static let margin: Int64 = 1_000_000_000

    public enum Verdict: Equatable, Sendable {
        case enough
        /// Not enough room; says how much is free and how much is needed.
        case tooLittle(available: Int64, needed: Int64)
    }

    /// `needed` is the estimated size of what will be saved. A download counts
    /// twice because its parts and its result can sit side by side. When
    /// either figure is unknown the answer is "enough": a guess never blocks.
    public static func verdict(needed: Int64?, available: Int64?) -> Verdict {
        guard let needed, needed > 0, let available else { return .enough }
        let required = needed * 2 + margin
        return available >= required ? .enough : .tooLittle(available: available, needed: required)
    }

    /// Free space on the disk that holds `path`, counting what the system can
    /// clear for itself. Nil when it cannot be read.
    public static func available(at path: String) -> Int64? {
        var url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        while !fm.fileExists(atPath: url.path), url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// The sentence for a refusal, or nil when there is room.
    public static func warning(_ verdict: Verdict) -> String? {
        guard case .tooLittle(let available, let needed) = verdict else { return nil }
        return Messages.diskLow(free: ByteText.string(available), needed: ByteText.string(needed))
    }
}
