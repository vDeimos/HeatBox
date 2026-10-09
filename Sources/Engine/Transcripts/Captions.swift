import Foundation

/// A passage of speech and the second it begins.
public struct Cue: Equatable, Sendable {
    public var start: Double
    public var text: String

    public init(start: Double, text: String) {
        self.start = start
        self.text = text
    }
}

/// One recognised word and the second it was said.
public struct TimedWord: Equatable, Sendable {
    public var start: Double
    public var text: String

    public init(start: Double, text: String) {
        self.start = start
        self.text = text
    }
}

/// Reading what was said in a video (Phobos): turns caption files into short
/// searchable passages, and plans the commands that get captions or sound.
/// Nothing here runs a tool.
public enum Captions {
    /// Length of each piece of sound handed to the speech recogniser. Short
    /// pieces keep every recogniser within its limits.
    public static let chunkSeconds = 50

    /// "00:01:02.345", "01:02.345" or "00:01:02,345" as seconds.
    public static func seconds(from stamp: String) -> Double? {
        let cleaned = stamp.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// One line of caption text without styling tags, entities or extra spaces.
    public static func clean(_ line: String) -> String {
        var text = line.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
        for (entity, plain) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                                ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: plain)
        }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Reads WebVTT or SRT. A line that repeats the one just before it is
    /// dropped, which undoes the way automatic captions repeat each line
    /// while they scroll.
    public static func parse(_ text: String) -> [Cue] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var cues: [Cue] = []
        var previous = ""
        var index = 0
        while index < lines.count {
            guard let arrow = lines[index].range(of: "-->") else {
                index += 1
                continue
            }
            let start = seconds(from: String(lines[index][..<arrow.lowerBound]))
            index += 1
            var block: [String] = []
            while index < lines.count, !lines[index].isEmpty {
                let line = lines[index]
                if line.contains("-->") { break }
                // The number that starts the next SRT cue is not text.
                let next = index + 1 < lines.count ? lines[index + 1] : ""
                if next.contains("-->"), !line.isEmpty, line.allSatisfy({ $0.isNumber || $0 == " " }) { break }
                block.append(line)
                index += 1
            }
            guard let begin = start else { continue }
            for raw in block {
                let cleaned = clean(raw)
                guard !cleaned.isEmpty, cleaned != previous else { continue }
                cues.append(Cue(start: begin, text: cleaned))
                previous = cleaned
            }
        }
        return cues
    }

    /// Joins short cues into passages of about ten seconds, so a phrase that
    /// runs across two captions can still be found.
    public static func chunk(_ cues: [Cue], maxSeconds: Double = 10, maxWords: Int = 28) -> [Cue] {
        var result: [Cue] = []
        var start = 0.0
        var words: [String] = []
        func flush() {
            if !words.isEmpty {
                result.append(Cue(start: start, text: words.joined(separator: " ")))
                words = []
            }
        }
        for cue in cues {
            let pieces = cue.text.split(separator: " ").map(String.init)
            if !words.isEmpty && (cue.start - start >= maxSeconds || words.count + pieces.count > maxWords) {
                flush()
            }
            if words.isEmpty { start = cue.start }
            words += pieces
        }
        flush()
        return result
    }

    /// Passages built from recognised words.
    public static func passages(from words: [TimedWord]) -> [Cue] {
        chunk(words.map { Cue(start: $0.start, text: $0.text) }, maxSeconds: 8, maxWords: 24)
    }

    /// The languages to ask a site for: the Mac's own, then English.
    public static func languages(for code: String?) -> String {
        let code = (code ?? "en").lowercased()
        return code == "en" || code.isEmpty ? "en" : "\(code),en"
    }

    /// Asks the site for a video's captions and nothing else (plan Rule 4).
    /// Nil when the link is not a web link.
    public static func fetchArguments(link: String, languages: String, folder: String, cookiesFile: String?,
                                      toolchain: YtdlpCommand.Toolchain) -> [String]? {
        guard Links.isWebLink(link) else { return nil }
        var args = YtdlpCommand.baseArguments(toolchain)
        args += ["--no-warnings", "--skip-download", "--no-playlist",
                 "--write-subs", "--write-auto-subs", "--sub-langs", languages,
                 "--sub-format", "vtt/best", "--convert-subs", "vtt", "--sleep-subtitles", "2",
                 "-P", folder, "-o", "%(id)s.%(ext)s"]
        if let ffmpeg = toolchain.ffmpeg { args += ["--ffmpeg-location", ffmpeg] }
        if let cookies = cookiesFile, !cookies.isEmpty { args += ["--cookies", cookies] }
        return args + ["--", link]
    }

    /// Takes the first caption track out of a video file, as SRT.
    public static func embeddedArguments(input: String, output: String) -> [String] {
        ["-nostdin", "-y", "-hide_banner", "-loglevel", "error",
         "-i", input, "-map", "0:s:0", "-c:s", "srt", output]
    }

    /// Cuts the sound into short mono pieces that a speech recogniser can take.
    public static func audioChunkArguments(input: String, folder: String) -> [String] {
        ["-nostdin", "-y", "-hide_banner", "-loglevel", "error",
         "-i", input, "-vn", "-map", "0:a:0", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le",
         "-f", "segment", "-segment_time", String(chunkSeconds), "-reset_timestamps", "1",
         folder + "/chunk_%04d.wav"]
    }
}
