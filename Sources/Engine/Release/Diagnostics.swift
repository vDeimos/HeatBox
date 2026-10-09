import Foundation

/// The text a person can attach to a bug report (Phase 11). It holds versions,
/// tool sources and how the queue stands, and nothing that identifies a person
/// or what they download: no links, titles, file names, folders, sign-in or
/// settings values beyond on/off switches. Their home folder name never appears.
public enum Diagnostics {
    public struct Tool: Equatable, Sendable {
        public var name: String
        public var version: String?
        /// "Chosen by you", "Installed by the app", "Homebrew" or "Not found".
        public var source: String

        public init(name: String, version: String?, source: String) {
            self.name = name
            self.version = version
            self.source = source
        }
    }

    public struct Input: Sendable {
        public var appVersion: String
        public var build: String
        public var system: String
        public var chip: String
        public var tools: [Tool]
        public var jobs: [Job]
        public var settings: AppSettings
        public var freeSpace: Int64?
        public var now: Date

        public init(appVersion: String, build: String, system: String, chip: String, tools: [Tool], jobs: [Job],
                    settings: AppSettings, freeSpace: Int64?, now: Date = Date()) {
            self.appVersion = appVersion
            self.build = build
            self.system = system
            self.chip = chip
            self.tools = tools
            self.jobs = jobs
            self.settings = settings
            self.freeSpace = freeSpace
            self.now = now
        }
    }

    public static func report(_ input: Input) -> String {
        var lines: [String] = []
        lines.append("\(Engine.productName) diagnostics")
        lines.append("Made \(ISO8601DateFormatter().string(from: input.now))")
        lines.append("")
        lines.append("App \(input.appVersion) (build \(input.build))")
        lines.append("macOS \(input.system), \(input.chip)")
        if let free = input.freeSpace { lines.append("Free disk space: \(ByteText.string(free))") }
        lines.append("")
        lines.append("Tools")
        for tool in input.tools {
            lines.append("  \(tool.name): \(tool.version ?? "no version") (\(tool.source))")
        }
        lines.append("")
        let s = input.settings
        lines.append("Switches")
        lines.append("  parallel downloads \(s.maxConcurrent), retry \(onOff(s.autoRetry)), speed limit \(s.speedLimitKB == 0 ? "none" : "\(s.speedLimitKB) KB/s")")
        lines.append("  subtitles \(onOff(s.subtitles)), cover \(onOff(s.coverImage)), sponsor cuts \(onOff(s.cutSponsors)), even volume \(onOff(s.evenLoudness))")
        lines.append("  spoken search \(onOff(s.spokenSearch)), listening \(onOff(s.transcribeLocally)), saved sign-in \(onOff(s.useSignIn))")
        lines.append("  own tool paths set: \(s.toolPaths.count)")
        lines.append("")
        lines.append("Downloads: \(input.jobs.count)")
        let counts = Dictionary(grouping: input.jobs, by: { $0.state.label }).mapValues(\.count)
        for (state, count) in counts.sorted(by: { $0.key < $1.key }) { lines.append("  \(state): \(count)") }
        let failed = input.jobs.filter { if case .failed = $0.state { return true } else { return false } }
        if !failed.isEmpty {
            lines.append("")
            lines.append("Latest failures (site and sentence only)")
            for job in failed.suffix(10) { lines.append("  \(job.site.isEmpty ? "unknown site" : job.site): \(scrub(job.message))") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func onOff(_ value: Bool) -> String { value ? "on" : "off" }

    /// Takes the home folder's name and any web link out of a sentence.
    static func scrub(_ text: String, home: String = NSHomeDirectory()) -> String {
        var out = text
        if home.count > 1 { out = out.replacingOccurrences(of: home, with: "~") }
        // Any other account's folder name is a name too.
        out = out.replacingOccurrences(of: "/Users/[^/ ]+", with: "~", options: .regularExpression)
        let words = out.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            let lower = word.lowercased()
            return lower.hasPrefix("http://") || lower.hasPrefix("https://") ? "<link>" : String(word)
        }
        return words.joined(separator: " ")
    }
}
