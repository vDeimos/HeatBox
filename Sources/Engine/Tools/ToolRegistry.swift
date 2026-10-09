import Foundation

/// The outside programs the app runs.
public enum Tool: String, CaseIterable, Codable, Sendable {
    case ytdlp = "yt-dlp"
    case ffmpeg
    case ffprobe
    case deno

    /// The file name looked for in each folder.
    public var executableName: String { rawValue }

    /// What the tool is for, in a few words.
    public var purpose: String {
        switch self {
        case .ytdlp: return Messages.purposeDownloader
        case .ffmpeg: return Messages.purposeConverter
        case .ffprobe: return Messages.purposeInspector
        case .deno: return Messages.purposeScriptRuntime
        }
    }

    var versionArguments: [String] {
        switch self {
        case .ytdlp, .deno: return ["--version"]
        case .ffmpeg, .ffprobe: return ["-version"]
        }
    }
}

public struct ToolLocation: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// A path the user chose in Settings.
        case userOverride
        /// The app's own folder (filled by the provisioner in Phase 10).
        case managed
        /// Homebrew or another fixed system folder.
        case system
    }

    public let path: String
    public let source: Source
}

public struct ToolStatus: Equatable, Sendable {
    public let tool: Tool
    public let location: ToolLocation?
    public var found: Bool { location != nil }
}

/// Finds tools and builds the environment they run in. Lookup order
/// (ADR-003): the user's override, the managed folder, then fixed system
/// folders. The inherited `PATH` is never consulted, here or by the tools.
public struct ToolRegistry: Sendable {
    /// Homebrew on Apple silicon, Homebrew on Intel, then the system's own folder.
    public static let systemFolders = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    public var managedFolder: String
    /// Full paths chosen by the user. One that is not an absolute path to an
    /// executable file is ignored and the normal search is used.
    public var overrides: [Tool: String]
    private let isExecutable: @Sendable (String) -> Bool

    public init(managedFolder: String = AppPaths.standard().bin.path,
                overrides: [Tool: String] = [:],
                isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) {
        self.managedFolder = managedFolder
        self.overrides = overrides
        self.isExecutable = isExecutable
    }

    public func locate(_ tool: Tool) -> ToolLocation? {
        if let chosen = validOverride(for: tool) {
            return ToolLocation(path: chosen, source: .userOverride)
        }
        let managed = (managedFolder as NSString).appendingPathComponent(tool.executableName)
        if isExecutable(managed) { return ToolLocation(path: managed, source: .managed) }
        for folder in Self.systemFolders {
            let candidate = (folder as NSString).appendingPathComponent(tool.executableName)
            if isExecutable(candidate) { return ToolLocation(path: candidate, source: .system) }
        }
        return nil
    }

    public func path(_ tool: Tool) -> String? { locate(tool)?.path }

    /// Every tool and where it was found, in a fixed order.
    public func status() -> [ToolStatus] {
        Tool.allCases.map { ToolStatus(tool: $0, location: locate($0)) }
    }

    /// The tools a download cannot do without: the downloader, the converter
    /// it joins streams with, and the runtime it reads YouTube with.
    public static let neededForDownloads: [Tool] = [.ytdlp, .ffmpeg, .deno]

    /// Which of those are missing. While any is, the app shows its setup screen.
    public func missingForDownloads() -> [Tool] {
        Self.neededForDownloads.filter { locate($0) == nil }
    }

    private func validOverride(for tool: Tool) -> String? {
        guard let raw = overrides[tool]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), isExecutable(expanded) else { return nil }
        return expanded
    }

    /// The `PATH` tools run with: the folders of the user's overrides, the
    /// managed folder, the fixed system folders, then the basics. yt-dlp finds
    /// FFmpeg through this, so an overridden FFmpeg is the one it uses.
    public var searchPath: [String] {
        var folders: [String] = []
        func add(_ folder: String) {
            if !folder.isEmpty && !folders.contains(folder) { folders.append(folder) }
        }
        for tool in Tool.allCases {
            if let chosen = validOverride(for: tool) { add((chosen as NSString).deletingLastPathComponent) }
        }
        add(managedFolder)
        Self.systemFolders.forEach(add)
        ["/bin", "/usr/sbin", "/sbin"].forEach(add)
        return folders
    }

    /// The complete environment for every tool. It is built from scratch, so
    /// nothing set in a shell or by a launcher can change what a tool does:
    /// no inherited `PATH`, proxy variables or Python settings.
    public func environment() -> [String: String] {
        [
            "PATH": searchPath.joined(separator: ":"),
            "HOME": NSHomeDirectory(),
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
            "TMPDIR": NSTemporaryDirectory(),
            "LANG": "en_US.UTF-8",
            "PYTHONUNBUFFERED": "1",
            "PYTHONIOENCODING": "utf-8",
            "NO_COLOR": "1",
        ]
    }

    /// The version a tool reports, or nil when it is missing or will not say.
    public func version(of tool: Tool, runner: ProcessRunner = ProcessRunner()) async -> String? {
        guard let path = path(tool) else { return nil }
        let request = ProcessRequest(executable: path, arguments: tool.versionArguments, environment: environment())
        guard let result = try? await runner.run(request), result.outcome.succeeded else { return nil }
        return Self.parseVersion(of: tool, from: result.standardOutput)
    }

    /// Picks the version out of what a tool prints: "2026.08.19" from yt-dlp,
    /// "ffmpeg version 7.1.1 Copyright…" from FFmpeg, "deno 2.9.7 (stable…)" from Deno.
    public static func parseVersion(of tool: Tool, from output: String) -> String? {
        guard let first = output.split(whereSeparator: \.isNewline).first else { return nil }
        let words = first.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }
        switch tool {
        case .ytdlp:
            return words[0]
        case .ffmpeg, .ffprobe:
            guard let marker = words.firstIndex(of: "version"), marker + 1 < words.count else { return nil }
            // A build can add its maker after the number: "9.0.2-https://www.martin-riedl.de".
            let word = words[marker + 1]
            if let dash = word.firstIndex(of: "-"), word[..<dash].allSatisfy({ $0.isNumber || $0 == "." }), !word[..<dash].isEmpty {
                return String(word[..<dash])
            }
            return word
        case .deno:
            return words.count > 1 && words[0] == "deno" ? words[1] : nil
        }
    }

    /// One Terminal command that installs every tool with Homebrew, and
    /// Homebrew first if it is missing. Shown for the user to copy; the app
    /// never runs it.
    public static let homebrewSetupCommand = "command -v brew >/dev/null 2>&1 || /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"; eval \"$(/opt/homebrew/bin/brew shellenv)\"; brew install yt-dlp ffmpeg deno"
}
