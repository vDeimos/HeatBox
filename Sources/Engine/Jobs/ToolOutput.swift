import Foundation

/// Reads the lines the download tool prints while it works.
public enum ToolOutput {
    public enum Event: Equatable, Sendable {
        /// A progress line (`YtdlpCommand.progressTemplate`). The fraction is
        /// for the file being downloaded and is nil when the tool cannot tell.
        case progress(fraction: Double?, speed: String, timeLeft: String, size: String, item: Int?, itemCount: Int?, title: String)
        /// A playlist moved on to this item.
        case item(index: Int, count: Int)
        /// A named step after downloading.
        case stage(String)
        /// The tool reported an error; the text is in its own words, with the label.
        case error(String)
        /// The tool skipped something it already has.
        case alreadyHave
        /// The tool says the person stopped it.
        case interrupted
        case other
    }

    /// The tool's names for its steps, in plain words (Studio's stage names).
    static let stages: [String: String] = [
        "Merger": Messages.stageMerging, "ExtractAudio": Messages.stageExtractingAudio,
        "VideoRemuxer": Messages.stageRemuxing, "VideoConvertor": Messages.stageConvertingVideo,
        "EmbedThumbnail": Messages.stageEmbeddingCover, "Metadata": Messages.stageWritingTags,
        "SplitChapters": Messages.stageSplittingChapters, "SponsorBlock": Messages.stageSponsorBlock,
        "ModifyChapters": Messages.stageCutting, "EmbedSubtitle": Messages.stageEmbeddingSubtitles,
        "FixupM3u8": Messages.stageFixing, "FixupM4a": Messages.stageFixing, "FixupStretched": Messages.stageFixing,
        "FixupTimestamp": Messages.stageFixing, "FixupDuration": Messages.stageFixing,
        "ThumbnailsConvertor": Messages.stageConvertingCover, "SubtitlesConvertor": Messages.stageConvertingSubtitles,
        "MoveFiles": Messages.stageFinishing,
    ]

    public static func parse(_ line: String) -> Event {
        if line.hasPrefix(YtdlpCommand.progressPrefix) {
            return progress(String(line.dropFirst(YtdlpCommand.progressPrefix.count)))
        }
        if line.hasPrefix("ERROR:") {
            if line.lowercased().contains("interrupted by user") { return .interrupted }
            // The tool sometimes prints the label alone and the reason on the next line.
            return line.dropFirst(6).trimmingCharacters(in: .whitespaces).isEmpty ? .other : .error(line)
        }
        if line.hasPrefix("[download] Got error:") { return .error(line) }
        if line.hasPrefix("[download] Downloading item ") {
            let numbers = line.split(separator: " ").compactMap { Int($0) }
            if numbers.count == 2 { return .item(index: max(numbers[0], 1), count: max(numbers[1], 1)) }
        }
        if line.hasSuffix("has already been recorded in the archive") || line.hasSuffix("has already been downloaded") {
            return .alreadyHave
        }
        if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
            let tag = String(line[line.index(after: line.startIndex)..<close])
            if let name = stages[tag] { return .stage(name) }
        }
        return .other
    }

    /// percent|speed|eta|total|estimate|playlist item|playlist size|title.
    private static func progress(_ body: String) -> Event {
        let parts = body.split(separator: "|", maxSplits: 7, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        func part(_ index: Int) -> String {
            guard index < parts.count else { return "" }
            let value = parts[index]
            return ["NA", "N/A", "Unknown", "None"].contains(value) || value.hasPrefix("Unknown") ? "" : value
        }
        let fraction = Double(part(0).replacingOccurrences(of: "%", with: "")).map { min(max($0 / 100, 0), 1) }
        let size = part(3).isEmpty ? (part(4).isEmpty ? "" : "~" + part(4)) : part(3)
        return .progress(fraction: fraction, speed: part(1), timeLeft: part(2), size: size,
                         item: Int(part(5)), itemCount: Int(part(6)), title: part(7))
    }
}
