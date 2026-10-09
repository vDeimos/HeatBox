import Foundation
import Testing
@testable import Engine

// Helpers for tests that run the real tools. A missing tool is a failure with
// the install command, never a skipped test (plan Section 5).

enum Real {
    static let registry = ToolRegistry()

    /// The path of a tool, or a recorded failure saying how to install it.
    static func path(_ tool: Tool, sourceLocation: SourceLocation = #_sourceLocation) -> String {
        guard let path = registry.path(tool) else {
            Issue.record("\(tool.rawValue) is not installed. Run: brew install yt-dlp ffmpeg deno", sourceLocation: sourceLocation)
            return "/missing/\(tool.rawValue)"
        }
        return path
    }

    static func toolchain() -> YtdlpCommand.Toolchain {
        YtdlpCommand.Toolchain(ytdlp: path(.ytdlp), ffmpeg: registry.path(.ffmpeg), deno: registry.path(.deno),
                               environment: registry.environment())
    }

    static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) async throws -> CapturedOutput {
        try await ProcessRunner().run(ProcessRequest(executable: executable, arguments: arguments,
                                                    environment: environment ?? registry.environment()))
    }

    /// A fresh folder for one test, removed afterwards by the caller.
    static func scratchFolder(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("studioxphobos-tests-\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A one-second test video with sound, made by FFmpeg.
    static func makeClip(in folder: URL, named name: String = "clip.mp4") async throws -> URL {
        let output = folder.appendingPathComponent(name)
        let result = try await run(path(.ffmpeg), ["-loglevel", "error", "-y",
                                                   "-f", "lavfi", "-i", "testsrc=duration=1:size=320x240:rate=15",
                                                   "-f", "lavfi", "-i", "sine=duration=1",
                                                   "-c:v", "libx264", "-c:a", "aac", "-pix_fmt", "yuv420p", output.path])
        #expect(result.outcome.succeeded, "\(result.standardError)")
        return output
    }

    /// The command's arguments with its web links swapped for a local file, which
    /// yt-dlp reads once `--enable-file-urls` is given. The command is otherwise unchanged.
    static func pointing(_ arguments: [String], at file: URL, extra: [String] = []) -> [String] {
        guard let dashes = arguments.lastIndex(of: "--") else { return arguments }
        let linkCount = arguments.count - dashes - 1
        return Array(arguments[..<dashes]) + ["--enable-file-urls"] + extra + ["--"]
            + Array(repeating: file.absoluteString, count: linkCount)
    }
}

// MARK: Golden fixtures (the same files the unit tests check)

enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/golden", isDirectory: true)

    static func all() throws -> [(name: String, fixture: [String: Any])] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") }.sorted().map { name in
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            return (name, try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]))
        }
    }

    static func request(from fixture: [String: Any]) throws -> YtdlpCommand.Request {
        var recipe = DownloadRecipe()
        if let id = fixture["preset"] as? String { recipe = try #require(PresetCatalog.preset(id: id)).recipe }
        if let overrides = fixture["recipe"] as? [String: Any] { recipe = recipe.overlaid(with: overrides) }
        return YtdlpCommand.Request(
            recipe: recipe,
            links: fixture["links"] as? [String] ?? [],
            folder: fixture["folder"] as? String ?? "/Users/test/Movies",
            archiveFile: fixture["archiveFile"] as? String,
            cookiesFile: fixture["cookiesFile"] as? String,
            workspace: fixture["workspace"] as? String,
            outputListFile: fixture["outputListFile"] as? String,
            chaptersFile: fixture["chaptersFile"] as? String)
    }
}
