import Foundation

/// How much smaller to make a video.
public enum ShrinkLevel: String, CaseIterable, Codable, Sendable {
    case close, medium, small

    /// The share of the original picture quality that is kept.
    var share: Double {
        switch self {
        case .close: return 0.6
        case .medium: return 0.35
        case .small: return 0.15
        }
    }

    /// The picture is scaled down to this height when it is taller.
    var maxHeight: Int? {
        switch self {
        case .close: return nil
        case .medium: return 1080
        case .small: return 720
        }
    }
}

/// A change to a file that is already on the Mac.
public enum ConvertKind: Equatable, Sendable {
    case playEverywhere
    case shrink(ShrinkLevel)
    case extractAudio
    case clip(start: Double, end: Double)
}

/// Plans every FFmpeg run that changes a file (plan Rule 2: this returns
/// values and runs nothing): Phobos's conversions of a file on the Mac, and
/// the re-encode after a download with Studio's encoders. The original is
/// never the output; a plan always names a new file.
public enum FFmpegPlanner {
    static let prefix = ["-nostdin", "-y", "-hide_banner", "-loglevel", "error", "-nostats", "-progress", "pipe:1"]

    public struct Plan: Equatable, Sendable {
        public let arguments: [String]
        /// A second attempt on the other kind of encoder, used when the first fails.
        public let fallback: [String]?
        public let output: String
        public let estimatedBytes: Double?
        /// Length of the result in seconds, for the progress bar. Zero when unknown.
        public let outputDuration: Double
        /// True when nothing is re-encoded, so the job is quick and loses no quality.
        public let copiesOnly: Bool
    }

    /// Reads one line of the tool's progress report. Returns seconds done.
    public static func progressSeconds(line: String) -> Double? {
        for key in ["out_time_us=", "out_time_ms="] where line.hasPrefix(key) {
            guard let micro = Double(line.dropFirst(key.count)) else { return nil }
            return micro / 1_000_000
        }
        return nil
    }

    static func seconds(_ value: Double) -> String { String(format: "%.3f", value) }

    // MARK: Converting a file on the Mac (Phobos)

    /// Bits per second to aim for when re-encoding the picture at full quality.
    static func videoBitRate(_ facts: FileFacts) -> Double {
        facts.bitRate > 0 ? max(facts.bitRate - 160_000, 300_000) : 6_000_000
    }

    private static func hardwareH264(_ bitRate: Double) -> [String] {
        ["-c:v", "h264_videotoolbox", "-b:v", String(Int(bitRate)), "-allow_sw", "1", "-pix_fmt", "yuv420p"]
    }

    private static let softwareH264 = ["-c:v", "libx264", "-crf", "20", "-preset", "medium", "-pix_fmt", "yuv420p"]

    /// Works out what to run. Nil when the job makes no sense for the file:
    /// taking the sound out of a file that has none, or shrinking a file
    /// that would not get smaller.
    public static func convert(_ kind: ConvertKind, input: String, facts: FileFacts,
                               exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Plan? {
        let directory = (input as NSString).deletingLastPathComponent
        let stem = ((input as NSString).lastPathComponent as NSString).deletingPathExtension
        func output(_ suffix: String, _ ext: String) -> String {
            Naming.uniquePath(directory: directory, stem: "\(stem) (\(suffix))", ext: ext, exists: exists)
        }
        let hasVideo = facts.videoCodec != nil
        let hasAudio = facts.audioCodec != nil
        let bitRate = videoBitRate(facts)

        switch kind {
        case .playEverywhere:
            guard hasVideo else { return nil }
            let videoFits = ["h264", "hevc"].contains(facts.videoCodec ?? "")
            let audioFits = !hasAudio || PhoneReady.soundWithVideo.contains(facts.audioCodec ?? "")
            let out = output("MP4", "mp4")
            var video = videoFits ? ["-c:v", "copy"] : hardwareH264(bitRate)
            if videoFits && facts.videoCodec == "hevc" { video += ["-tag:v", "hvc1"] }
            let audio = hasAudio ? (audioFits ? ["-c:a", "copy"] : ["-c:a", "aac", "-b:a", "192k"]) : []
            let head = prefix + ["-i", input, "-map", "0:v:0", "-map", "0:a:0?"]
            let tail = audio + ["-movflags", "+faststart", out]
            return Plan(arguments: head + video + tail,
                        fallback: videoFits ? nil : head + softwareH264 + tail,
                        output: out,
                        estimatedBytes: videoFits ? Double(facts.size) : (bitRate + 192_000) * facts.duration / 8,
                        outputDuration: facts.duration,
                        copiesOnly: videoFits && audioFits)

        case .shrink(let level):
            guard hasVideo else { return nil }
            // Aim for a share of what the picture uses now. Software encoding
            // goes first because the Mac's video hardware often ignores low
            // targets and can make a file bigger.
            let videoSource = facts.bitRate > 0 ? max(facts.bitRate * 0.85, 100_000) : bitRate
            let target = max(videoSource * level.share, 80_000)
            let audioRate: Double = level == .small ? 96_000 : 128_000
            var filter: [String] = []
            if let limit = level.maxHeight, facts.resolution > limit {
                // Scale the shorter side, so an upright video is treated fairly.
                filter = ["-vf", facts.height > facts.width ? "scale=\(limit):-2" : "scale=-2:\(limit)"]
            }
            let shrunk = (target + (hasAudio ? audioRate : 0)) * facts.duration / 8
            // A file that is already small cannot be made smaller by squeezing it further.
            if facts.size > 0 && shrunk >= Double(facts.size) * 0.85 { return nil }
            let out = output(level.rawValue, "mp4")
            let audio = hasAudio ? ["-c:a", "aac", "-b:a", "\(Int(audioRate / 1000))k"] : []
            let head = prefix + ["-i", input, "-map", "0:v:0", "-map", "0:a:0?"] + filter
            let tail = audio + ["-movflags", "+faststart", out]
            let squeeze = ["-c:v", "libx264", "-b:v", String(Int(target)), "-preset", "medium", "-pix_fmt", "yuv420p"]
            return Plan(arguments: head + squeeze + tail, fallback: head + hardwareH264(target) + tail, output: out,
                        estimatedBytes: shrunk, outputDuration: facts.duration, copiesOnly: false)

        case .extractAudio:
            guard hasAudio else { return nil }
            let copies = facts.audioCodec == "aac"
            let out = output("audio", "m4a")
            let audio = copies ? ["-c:a", "copy"] : ["-c:a", "aac", "-b:a", "192k"]
            return Plan(arguments: prefix + ["-i", input, "-vn", "-map", "0:a:0"] + audio + [out], fallback: nil, output: out,
                        estimatedBytes: copies ? nil : 192_000 * facts.duration / 8,
                        outputDuration: facts.duration, copiesOnly: copies)

        case .clip(let start, let end):
            guard end > start, start >= 0 else { return nil }
            let length = min(end, facts.duration > 0 ? facts.duration : end) - start
            guard length > 0 else { return nil }
            let cut = ["-ss", seconds(start), "-to", seconds(end), "-i", input]
            if hasVideo {
                let out = output("clip", "mp4")
                let audio = hasAudio ? ["-c:a", "aac", "-b:a", "192k"] : []
                let head = prefix + cut + ["-map", "0:v:0", "-map", "0:a:0?"]
                let tail = audio + ["-movflags", "+faststart", out]
                return Plan(arguments: head + hardwareH264(bitRate) + tail, fallback: head + softwareH264 + tail, output: out,
                            estimatedBytes: (bitRate + 192_000) * length / 8, outputDuration: length, copiesOnly: false)
            }
            guard hasAudio else { return nil }
            let out = output("clip", "m4a")
            return Plan(arguments: prefix + cut + ["-vn", "-c:a", "aac", "-b:a", "192k", out], fallback: nil, output: out,
                        estimatedBytes: 192_000 * length / 8, outputDuration: length, copiesOnly: false)
        }
    }

    // MARK: Re-encoding after a download (Studio's encoders)

    /// File endings the re-encode applies to.
    public static let videoExtensions: Set<String> = ["mp4", "mkv", "webm", "mov", "m4v"]

    /// The software encoder that stands in when the Mac's video hardware refuses.
    static func softwareStandIn(for encoder: VideoEncoder) -> (encoder: VideoEncoder, quality: Double)? {
        switch encoder {
        case .videoToolboxH264: return (.x264, 20)
        case .videoToolboxHEVC: return (.x265, 23)
        default: return nil
        }
    }

    /// Sound that can be copied into a container untouched.
    static func audioFits(_ codec: String?, in container: VideoContainer) -> Bool {
        guard let codec else { return true }
        switch container {
        case .webm: return ["opus", "vorbis"].contains(codec)
        case .mp4: return ["aac", "alac", "mp3", "ac3", "eac3", "opus", "flac"].contains(codec)
        case .mov: return ["aac", "alac", "mp3", "ac3", "eac3"].contains(codec) || codec.hasPrefix("pcm_")
        case .mkv, .automatic: return true
        }
    }

    /// The re-encode a recipe asks for, from `input` into the new file
    /// `output`. The recipe has passed the validator, so its container can
    /// hold what its encoder makes. `facts` may be missing; then the length
    /// and size are unknown and the sound is re-encoded to be safe.
    public static func encode(recipe: DownloadRecipe, input: String, output: String, facts: FileFacts?) -> Plan {
        let first = encodeArguments(recipe: recipe, encoder: recipe.encoder, quality: recipe.qualityFactor,
                                    input: input, output: output, facts: facts)
        let second = softwareStandIn(for: recipe.encoder).map { standIn -> [String] in
            var softer = recipe
            softer.encoderSpeed = .medium
            return encodeArguments(recipe: softer, encoder: standIn.encoder, quality: standIn.quality,
                                   input: input, output: output, facts: facts)
        }
        var estimate: Double?
        if recipe.encoder.usesBitrate, let duration = facts?.duration, duration > 0 {
            estimate = (recipe.hardwareBitrateMbps * 1_000_000 + Double(recipe.encodeAudioBitrate.bitsPerSecond)) * duration / 8
        }
        return Plan(arguments: first, fallback: second, output: output, estimatedBytes: estimate,
                    outputDuration: facts?.duration ?? 0, copiesOnly: false)
    }

    private static func encodeArguments(recipe r: DownloadRecipe, encoder: VideoEncoder, quality: Double,
                                        input: String, output: String, facts: FileFacts?) -> [String] {
        let container = r.container
        let apple = container == .mp4 || container == .mov
        let factor = "\(Int(quality.rounded()))"
        let bitrate = String(format: "%.1fM", r.hardwareBitrateMbps)

        // The picture itself, never a cover image that happens to come first.
        var a = prefix + ["-i", input, "-map", "0:V:0", "-map", "0:a?", "-map", "0:s?"]
        // A cover picture is carried over untouched: as a second "video" in
        // MP4 and MOV, as an attachment from MKV to MKV. (Studio dropped it.)
        let carriesCover = apple && facts?.hasCover == true
        if carriesCover { a += ["-map", "0:v:disp:attached_pic?"] }
        if container == .mkv && (input as NSString).pathExtension.lowercased() == "mkv" { a += ["-map", "0:t?"] }
        a += ["-map_metadata", "0", "-map_chapters", "0", "-c:v:0", encoder.rawValue]

        switch encoder {
        case .x264:
            a += ["-crf", factor, "-preset", r.encoderSpeed.rawValue, "-pix_fmt:v:0", "yuv420p"]
        case .x265:
            a += ["-crf", factor, "-preset", r.encoderSpeed.rawValue]
            if apple { a += ["-tag:v:0", "hvc1"] }
        case .videoToolboxH264:
            a += ["-b:v:0", bitrate, "-pix_fmt:v:0", "yuv420p"]
        case .videoToolboxHEVC:
            a += ["-b:v:0", bitrate]
            if apple { a += ["-tag:v:0", "hvc1"] }
        case .vp9:
            a += ["-crf", factor, "-b:v:0", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "2"]
        case .av1:
            a += ["-crf", factor, "-preset", "\(r.encoderSpeed.svtAV1Preset)"]
        case .prores:
            a += ["-profile:v:0", "3", "-pix_fmt:v:0", "yuv422p10le"]
        }
        // Never scale up: the height is the smaller of the target and what the video has.
        if let height = r.scale.height { a += ["-filter:v:0", "scale=-2:'min(\(height),ih)'"] }
        if carriesCover { a += ["-c:v:1", "copy", "-disposition:v:1", "attached_pic"] }

        let filters = YtdlpCommand.audioFilterArguments(r)
        // Without the file's facts, only MKV is known to take whatever the sound is.
        let fits = facts.map { audioFits($0.audioCodec, in: container) } ?? (container == .mkv)
        if r.encodeAudio || !filters.isEmpty || !fits {
            a += ["-c:a", container == .webm ? "libopus" : "aac", "-b:a", r.encodeAudioBitrate.argument] + filters
        } else {
            a += ["-c:a", "copy"]
        }

        switch container {
        case .mp4, .mov: a += ["-c:s", "mov_text"]
        case .webm: a += ["-c:s", "webvtt"]
        case .mkv, .automatic: a += ["-c:s", "copy"]
        }
        if apple { a += ["-movflags", "+faststart"] }
        a.append(output)
        return a
    }
}

extension EncoderSpeed {
    /// SVT-AV1 counts its speeds from 0 (slowest) to 13.
    var svtAV1Preset: Int {
        switch self {
        case .ultrafast: return 12
        case .superfast: return 11
        case .veryfast: return 10
        case .faster: return 9
        case .fast: return 8
        case .medium: return 6
        case .slow: return 5
        case .slower: return 4
        case .veryslow: return 3
        }
    }
}

extension AudioBitrate {
    var bitsPerSecond: Int { (Int(rawValue.dropFirst()) ?? 192) * 1000 }
}
