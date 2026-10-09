import Foundation

/// What a media file on the Mac holds, as ffprobe reads it. (A link's facts
/// are `MediaFacts`; this is a file's.)
public struct FileFacts: Equatable, Sendable {
    public var duration: Double = 0
    /// Overall bits per second. Zero when unknown.
    public var bitRate: Double = 0
    public var videoCodec: String?
    public var audioCodec: String?
    public var width = 0
    public var height = 0
    /// The sound's samples per second. Zero when unknown.
    public var sampleRate = 0
    /// True when the file carries a cover picture.
    public var hasCover = false
    public var size: Int64 = 0

    public init(duration: Double = 0, bitRate: Double = 0, videoCodec: String? = nil, audioCodec: String? = nil,
                width: Int = 0, height: Int = 0, sampleRate: Int = 0, hasCover: Bool = false, size: Int64 = 0) {
        self.duration = duration
        self.bitRate = bitRate
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.width = width
        self.height = height
        self.sampleRate = sampleRate
        self.hasCover = hasCover
        self.size = size
    }

    /// The shorter side, which is what "1080p" counts, upright or not.
    public var resolution: Int { (width > 0 && height > 0) ? min(width, height) : max(width, height) }

    /// What to ask ffprobe for.
    public static func inspectArguments(_ path: String) -> [String] {
        ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", path]
    }

    /// Reads ffprobe's answer. Nil when it is not one.
    public static func parse(output: String, size: Int64) -> FileFacts? {
        guard let probe = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any],
              probe["streams"] != nil || probe["format"] != nil else { return nil }
        return parse(probe: probe, size: size)
    }

    public static func parse(probe: [String: Any], size: Int64) -> FileFacts {
        func number(_ value: Any?) -> Double {
            if let number = value as? NSNumber { return number.doubleValue }
            if let text = value as? String { return Double(text) ?? 0 }
            return 0
        }
        let format = (probe["format"] as? [String: Any]) ?? [:]
        var facts = FileFacts(duration: number(format["duration"]), bitRate: number(format["bit_rate"]), size: size)
        for item in (probe["streams"] as? [Any]) ?? [] {
            guard let stream = item as? [String: Any] else { continue }
            let type = (stream["codec_type"] as? String) ?? ""
            let codec = stream["codec_name"] as? String
            // A cover picture shows up as a "video" stream; it is not the video.
            let isCover = ((stream["disposition"] as? [String: Any])?["attached_pic"] as? NSNumber)?.intValue == 1
            if type == "video", isCover {
                facts.hasCover = true
            } else if type == "video", facts.videoCodec == nil {
                facts.videoCodec = codec
                facts.width = Int(number(stream["width"]))
                facts.height = Int(number(stream["height"]))
            } else if type == "audio", facts.audioCodec == nil {
                facts.audioCodec = codec
                facts.sampleRate = Int(number(stream["sample_rate"]))
            }
        }
        return facts
    }
}

/// Whether a file will play on an iPhone as it is, and what to make when it will not (Phobos).
public enum PhoneReady {
    private static let videoContainers: Set<String> = ["mp4", "m4v", "mov"]
    private static let audioContainers: Set<String> = ["m4a", "mp3", "aac", "wav", "aiff", "aif", "caf", "flac"]
    private static let videoCodecs: Set<String> = ["h264", "hevc"]
    static let soundWithVideo: Set<String> = ["aac", "alac", "mp3", "ac3", "eac3"]
    private static let soundAlone: Set<String> = ["aac", "alac", "mp3", "flac"]

    /// True when the file can be sent as it is.
    public static func isReady(path: String, facts: FileFacts) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        if let video = facts.videoCodec {
            guard videoContainers.contains(ext), videoCodecs.contains(video) else { return false }
            guard let audio = facts.audioCodec else { return true }
            return soundWithVideo.contains(audio)
        }
        guard let audio = facts.audioCodec, audioContainers.contains(ext) else { return false }
        return soundAlone.contains(audio) || audio.hasPrefix("pcm_")
    }

    /// The copy to make for a file that is not ready.
    public static func conversion(for facts: FileFacts) -> ConvertKind {
        facts.videoCodec != nil ? .playEverywhere : .extractAudio
    }
}
