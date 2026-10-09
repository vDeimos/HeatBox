import Foundation

/// Evening out the volume of audio, so a playlist does not jump from quiet
/// to loud. Two passes with FFmpeg (Phobos): measure, then adjust with one
/// steady correction. The adjusting pass also carries Studio's volume change,
/// sample rate and channel options, and writes the sound back in the format
/// the file already has. Planning only: nothing here runs a tool.
public enum Loudness {
    /// The level most streaming services and podcasts aim for.
    public static let target = "I=-16:TP=-1.5:LRA=11"

    public struct Measurement: Equatable, Sendable {
        public var integrated: Double
        public var truePeak: Double
        public var range: Double
        public var threshold: Double
        public var offset: Double

        public init(integrated: Double, truePeak: Double, range: Double, threshold: Double, offset: Double) {
            self.integrated = integrated
            self.truePeak = truePeak
            self.range = range
            self.threshold = threshold
            self.offset = offset
        }
    }

    /// Reads the figures FFmpeg prints at the end of a measuring pass. Nil when
    /// there are none, or when the audio is silent and has nothing to measure.
    public static func parse(_ text: String) -> Measurement? {
        guard let open = text.lastIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
              let json = (try? JSONSerialization.jsonObject(with: Data(text[open...close].utf8))) as? [String: Any] else { return nil }
        func number(_ key: String) -> Double? {
            guard let raw = json[key] as? String, let value = Double(raw), value.isFinite else { return nil }
            return value
        }
        guard let integrated = number("input_i"), let peak = number("input_tp"), let range = number("input_lra"),
              let threshold = number("input_thresh"), let offset = number("target_offset") else { return nil }
        return Measurement(integrated: integrated, truePeak: peak, range: range, threshold: threshold, offset: offset)
    }

    public static func measureArguments(input: String) -> [String] {
        ["-nostdin", "-hide_banner", "-nostats", "-i", input, "-vn",
         "-af", "loudnorm=\(target):print_format=json", "-f", "null", "-"]
    }

    private static func figure(_ value: Double) -> String { String(format: "%.2f", value) }

    /// The filter for the adjusting pass. With a measurement it applies one
    /// steady correction; without one it falls back to a single adaptive
    /// pass. A volume change comes after, so "+3 dB" means louder than the target.
    public static func filter(_ measured: Measurement?, gainDB: Double = 0) -> String {
        var filter = "loudnorm=\(target)"
        if let m = measured {
            filter += ":measured_I=\(figure(m.integrated)):measured_TP=\(figure(m.truePeak))"
                + ":measured_LRA=\(figure(m.range)):measured_thresh=\(figure(m.threshold))"
                + ":offset=\(figure(m.offset)):linear=true"
        }
        if gainDB != 0 { filter += ",volume=\(String(format: "%.1f", gainDB))dB" }
        return filter
    }

    /// File endings whose sound the adjusting pass can write back.
    public static let extensions: Set<String> = ["m4a", "mp3", "opus", "ogg", "flac", "wav", "aac"]

    /// Ogg holds no picture stream; its cover travels as a tag.
    static func isOgg(_ ext: String) -> Bool { ext == "opus" || ext == "ogg" }

    /// The encoder that writes a file's sound back in the format it has.
    /// Lossless stays lossless. For the rest, a bitrate the recipe names is
    /// used; MP3 keeps its own quality scale; otherwise 192 kbps (Phobos),
    /// or the nearest equivalent of the recipe's quality.
    static func encoder(ext: String, codec: String?, quality: AudioQuality) -> [String]? {
        let rate: String
        switch quality {
        case .k320, .k256, .k192, .k160, .k128, .k96, .k64: rate = String(quality.rawValue.dropFirst()) + "k"
        case .q0: rate = "256k"
        case .q5: rate = "128k"
        case .q2, .standard: rate = "192k"
        }
        switch ext {
        case "m4a": return codec == "alac" ? ["-c:a", "alac"] : ["-c:a", "aac", "-b:a", rate]
        case "aac": return ["-c:a", "aac", "-b:a", rate]
        case "mp3":
            switch quality {
            case .q0: return ["-c:a", "libmp3lame", "-q:a", "0"]
            case .q2, .standard: return ["-c:a", "libmp3lame", "-q:a", "2"]
            case .q5: return ["-c:a", "libmp3lame", "-q:a", "5"]
            default: return ["-c:a", "libmp3lame", "-b:a", rate]
            }
        case "opus": return ["-c:a", "libopus", "-b:a", rate]
        case "ogg": return ["-c:a", "libvorbis", "-b:a", rate]
        case "flac": return ["-c:a", "flac"]
        case "wav": return ["-c:a", (codec?.hasPrefix("pcm_") ?? false) ? codec! : "pcm_s16le"]
        default: return nil
        }
    }

    /// Re-encodes the sound at the right level into the new file `output`,
    /// keeping the cover picture and the tags. Nil for a kind of file the
    /// pass cannot write. `pictureBlock` is an Ogg file's cover, as the tag
    /// it has to travel in (`ChapterTagger.pictureBlock`).
    public static func normalizeArguments(input: String, output: String, measured: Measurement?, facts: FileFacts,
                                          recipe: DownloadRecipe, pictureBlock: String? = nil) -> [String]? {
        let ext = (input as NSString).pathExtension.lowercased()
        guard let encoder = encoder(ext: ext, codec: facts.audioCodec, quality: recipe.audioQuality) else { return nil }
        var a = ["-nostdin", "-y", "-hide_banner", "-nostats", "-loglevel", "error", "-i", input, "-map", "0:a:0"]
        // A cover picture is copied, not re-encoded, where the file type can hold one as a stream.
        if ["m4a", "mp3", "flac"].contains(ext) { a += ["-map", "0:v?", "-c:v", "copy"] }
        a += encoder
        // The filter works at a very high sample rate inside; say what comes out.
        // Opus only exists at 48,000.
        let rate = ext == "opus" ? 48_000 : (recipe.sampleRate.hertz ?? (facts.sampleRate > 0 ? facts.sampleRate : 44_100))
        a += ["-ar", "\(rate)"]
        if let channels = recipe.channels.count { a += ["-ac", "\(channels)"] }
        a += ["-af", filter(measured, gainDB: recipe.gainDB), "-map_metadata", "0"]
        if isOgg(ext), let pictureBlock { a += ["-metadata:s:a:0", "METADATA_BLOCK_PICTURE=\(pictureBlock)"] }
        if ext == "m4a" { a += ["-movflags", "+faststart"] }
        if ext == "mp3" { a += ["-id3v2_version", "3"] }
        a.append(output)
        return a
    }
}
