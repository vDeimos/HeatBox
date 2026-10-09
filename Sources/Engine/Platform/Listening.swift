import Foundation

/// Whether this Mac can turn speech into words without sending sound anywhere.
public enum SpeechAvailability: Equatable, Sendable {
    case ready
    /// The person has not been asked yet.
    case undecided
    /// The person, or a policy on this Mac, said no.
    case notAllowed
    /// This Mac cannot do it on its own, or the program is not one macOS can ask about.
    case unavailable
}

/// Speech recognition, as the engine sees it. The app implements it with the
/// Mac's own recogniser, on the device only; tests implement it with a script.
public protocol SpeechRecognizer: Sendable {
    func availability() -> SpeechAvailability
    /// Asks the person once. Does nothing when they have already answered.
    func requestAccess() async
    /// The words in one short piece of sound. A piece with no speech, or one
    /// that fails, gives none.
    func words(in file: URL) async -> [TimedWord]
}

/// Whether the Mac is running on its battery.
public protocol PowerSource: Sendable {
    /// True on battery. False on mains power, or when it cannot be told.
    var onBattery: Bool { get }
}

/// A Mac that is always plugged in, for where power does not matter.
public struct MainsPower: PowerSource {
    public init() {}
    public var onBattery: Bool { false }
}

/// No recogniser at all.
public struct NoSpeechRecognizer: SpeechRecognizer {
    public init() {}
    public func availability() -> SpeechAvailability { .unavailable }
    public func requestAccess() async {}
    public func words(in file: URL) async -> [TimedWord] { [] }
}
