import Foundation

/// The four things the Convert screen can do to a file that is already on the Mac.
public enum ConvertChoice: String, CaseIterable, Sendable {
    case mp4, shrink, audio, clip

    public var title: String {
        switch self {
        case .mp4: return Messages.convertMP4Title
        case .shrink: return Messages.convertShrinkTitle
        case .audio: return Messages.convertAudioTitle
        case .clip: return Messages.convertClipTitle
        }
    }

    public var explanation: String {
        switch self {
        case .mp4: return Messages.convertMP4Explanation
        case .shrink: return Messages.convertShrinkExplanation
        case .audio: return Messages.convertAudioExplanation
        case .clip: return Messages.convertClipExplanation
        }
    }
}

extension ShrinkLevel {
    public var label: String {
        switch self {
        case .close: return Messages.shrinkClose
        case .medium: return Messages.shrinkMedium
        case .small: return Messages.shrinkSmall
        }
    }
}

/// Reads a file's facts with ffprobe.
public enum FileInspector {
    public static func size(of path: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Nil when the inspector is missing, the file cannot be read, or it holds neither picture nor sound.
    public static func inspect(_ path: String, tools: ToolRegistry, runner: ProcessRunner = ProcessRunner()) async -> FileFacts? {
        guard let ffprobe = tools.path(.ffprobe) else { return nil }
        let request = ProcessRequest(executable: ffprobe, arguments: FileFacts.inspectArguments(path), environment: tools.environment())
        guard let ran = try? await runner.run(request), ran.outcome.succeeded,
              let facts = FileFacts.parse(output: ran.standardOutput, size: size(of: path)),
              facts.videoCodec != nil || facts.audioCodec != nil else { return nil }
        return facts
    }
}

/// What is on the Convert screen: a file, what it holds, and what the person
/// picked. Everything the screen decides is decided here (plan Rule 1).
public struct ConvertDraft: Equatable, Sendable {
    public let input: String
    public let facts: FileFacts
    public var choice: ConvertChoice
    public var level = ShrinkLevel.medium
    public var clipStart: Double = 0
    public var clipEnd: Double

    /// Starts on "play everywhere", or on a clip for a file with no picture.
    public init(input: String, facts: FileFacts) {
        self.input = input
        self.facts = facts
        clipEnd = facts.duration
        choice = facts.videoCodec == nil ? .clip : .mp4
        if !available(choice) { choice = ConvertChoice.allCases.first(where: available) ?? choice }
    }

    public var name: String { (input as NSString).lastPathComponent }

    public func available(_ choice: ConvertChoice) -> Bool {
        switch choice {
        case .mp4, .shrink: return facts.videoCodec != nil
        case .audio: return facts.audioCodec != nil
        case .clip: return facts.duration > 1
        }
    }

    public var kind: ConvertKind {
        switch choice {
        case .mp4: return .playEverywhere
        case .shrink: return .shrink(level)
        case .audio: return .extractAudio
        case .clip: return .clip(start: clipStart, end: clipEnd)
        }
    }

    /// What to run. Nil when the chosen job makes no sense for this file.
    public func plan(exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> FFmpegPlanner.Plan? {
        FFmpegPlanner.convert(kind, input: input, facts: facts, exists: exists)
    }

    /// Why the chosen job cannot be done on this file, when it cannot.
    public func blocker(exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        guard plan(exists: exists) == nil else { return nil }
        switch choice {
        case .mp4: return facts.videoCodec == nil ? Messages.convertNoPicture : nil
        case .shrink: return facts.videoCodec == nil ? Messages.convertNoPicture : Messages.convertAlreadySmall
        case .audio: return Messages.convertNoSound
        case .clip: return Messages.convertClipTimes
        }
    }

    /// The name of the copy, as the list of conversions and the Library show it.
    public var label: String {
        switch choice {
        case .mp4: return Messages.convertLabelMP4
        case .shrink: return Messages.convertLabelShrink(level.label)
        case .audio: return Messages.convertLabelAudio
        case .clip: return Messages.convertLabelClip(TimeText.clock(clipStart), TimeText.clock(clipEnd))
        }
    }

    /// How big a shrunk copy would be, for the three size buttons.
    public func estimate(for level: ShrinkLevel) -> String {
        guard let bytes = FFmpegPlanner.convert(.shrink(level), input: input, facts: facts, exists: { _ in false })?.estimatedBytes else {
            return Messages.convertNoSaving
        }
        return ByteText.string(Int64(bytes))
    }

    /// "1080p · 12:34 · 1.2 GB · Movies › YouTube"
    public func factsLine(home: String = NSHomeDirectory()) -> String {
        var parts: [String] = []
        if facts.videoCodec != nil && facts.resolution > 0 { parts.append("\(facts.resolution)p") }
        if facts.videoCodec == nil { parts.append(Messages.formatKindAudio) }
        if facts.duration > 0 { parts.append(TimeText.clock(facts.duration.rounded())) }
        parts.append(ByteText.string(facts.size))
        parts.append(Naming.breadcrumb((input as NSString).deletingLastPathComponent, home: home))
        return parts.joined(separator: " · ")
    }

    /// The sentence beside the Start button.
    public func summary(for plan: FFmpegPlanner.Plan) -> String {
        Messages.convertSavesAs((plan.output as NSString).lastPathComponent, size: plan.estimatedBytes.map { ByteText.string(Int64($0)) })
    }

    /// Re-encoding uses a lot of power, so on battery the person is asked first. Repackaging is quick and is not asked about.
    public static func asksOnBattery(_ plan: FFmpegPlanner.Plan, onBattery: Bool) -> Bool {
        onBattery && !plan.copiesOnly
    }
}

/// Getting a file onto an iPhone (Phobos): a file the phone plays is sent as
/// it is, any other gets a phone-friendly copy first.
public enum PhoneSend: Equatable, Sendable {
    case ready
    case needsCopy(FFmpegPlanner.Plan)
    case impossible

    public static func decide(path: String, facts: FileFacts,
                              exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> PhoneSend {
        if PhoneReady.isReady(path: path, facts: facts) { return .ready }
        guard let plan = FFmpegPlanner.convert(PhoneReady.conversion(for: facts), input: path, facts: facts, exists: exists) else {
            return .impossible
        }
        return .needsCopy(plan)
    }
}
