import Foundation
import Testing
@testable import Engine

// A recipe all the way through the real tools: the command is built by
// `YtdlpCommand`, run by `ProcessRunner`, and the files it leaves are
// inspected with ffprobe. The source is a generated clip read from disk,
// so there is no network. Phase 4 adds the queue, pauses and playlists.

private struct Probed {
    var codecs: [String]
    var tags: [String: String]
}

private func probe(_ file: URL) async throws -> Probed {
    let result = try await Real.run(Real.path(.ffprobe), ["-v", "error", "-print_format", "json", "-show_streams", "-show_format", file.path])
    #expect(result.outcome.succeeded, "\(result.standardError)")
    let json = try #require(JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8)) as? [String: Any])
    let streams = json["streams"] as? [[String: Any]] ?? []
    let format = json["format"] as? [String: Any] ?? [:]
    let tags = (format["tags"] as? [String: String] ?? [:]).reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
    return Probed(codecs: streams.compactMap { $0["codec_name"] as? String }, tags: tags)
}

private func run(_ request: YtdlpCommand.Request, source: URL, extra: [String] = []) async throws -> (plan: YtdlpCommand.Plan, lines: [String], outcome: ProcessOutcome) {
    let plan = try YtdlpCommand.plan(request, toolchain: Real.toolchain())
    let args = Real.pointing(plan.arguments, at: source, extra: extra)
    let lines = LineCollector()
    let running = try ProcessRunner().start(ProcessRequest(executable: plan.executable, arguments: args, environment: plan.environment)) { lines.add($0.text) }
    let outcome = await running.waitUntilExit()
    return (plan, lines.all, outcome)
}

private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}

@Suite struct CommandRunTests {
    @Test func aVideoIsDownloadedNamedAndReported() async throws {
        let root = try Real.scratchFolder("run-video")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await Real.makeClip(in: root)
        let destination = root.appendingPathComponent("Movies/Site")
        let workspace = root.appendingPathComponent("jobs/one")
        let paths = root.appendingPathComponent("paths.txt")
        let request = YtdlpCommand.Request(recipe: PresetCatalog.best.recipe, links: ["https://example.com/v"], folder: destination.path,
                                           workspace: workspace.path, outputListFile: paths.path)
        let result = try await run(request, source: source)
        #expect(result.outcome.succeeded, "\(result.lines.suffix(5))")

        // The guided name carries the id, and the file is where the engine was told to put it.
        let file = destination.appendingPathComponent("clip [clip].mp4")
        #expect(FileManager.default.fileExists(atPath: file.path), "\(result.lines.suffix(5))")
        // Every finished file is written to the list the engine reads.
        let listed = try String(contentsOf: paths, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(listed == [file.path])
        // The progress template is understood and carries the prefix.
        let progress = result.lines.filter { $0.hasPrefix(YtdlpCommand.progressPrefix) }
        #expect(!progress.isEmpty, "\(result.lines)")
        let fields = progress.last!.dropFirst(YtdlpCommand.progressPrefix.count).split(separator: "|", omittingEmptySubsequences: false)
        #expect(fields.count == 8, "\(fields)")
        #expect(fields.last == "clip")
        // The scratch folder was used for the job and holds nothing once it is finished.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: workspace.path)) ?? []
        #expect(leftovers.isEmpty, "\(leftovers)")
        let facts = try await probe(file)
        #expect(Set(facts.codecs) == ["h264", "aac"])
    }

    @Test func twoJobsForTheSameLinkKeepApartInTheirOwnWorkspaces() async throws {
        let root = try Real.scratchFolder("run-twins")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await Real.makeClip(in: root)
        let a = YtdlpCommand.Request(recipe: DownloadRecipe(), links: ["https://example.com/v"], folder: root.appendingPathComponent("a").path,
                                     workspace: root.appendingPathComponent("jobs/a").path)
        let b = YtdlpCommand.Request(recipe: DownloadRecipe(), links: ["https://example.com/v"], folder: root.appendingPathComponent("b").path,
                                     workspace: root.appendingPathComponent("jobs/b").path)
        async let first = run(a, source: source)
        async let second = run(b, source: source)
        let (one, two) = try await (first, second)
        #expect(one.outcome.succeeded && two.outcome.succeeded)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("a/clip [clip].mp4").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("b/clip [clip].mp4").path))
    }

    @Test func audioComesOutAsM4aWithItsTags() async throws {
        let root = try Real.scratchFolder("run-audio")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await Real.makeClip(in: root)
        let destination = root.appendingPathComponent("Music")
        let request = YtdlpCommand.Request(recipe: PresetCatalog.audioOnly.recipe, links: ["https://example.com/v"], folder: destination.path)
        let result = try await run(request, source: source)
        #expect(result.outcome.succeeded, "\(result.lines.suffix(5))")
        let file = destination.appendingPathComponent("clip [clip].m4a")
        #expect(FileManager.default.fileExists(atPath: file.path), "\(result.lines.suffix(5))")
        let facts = try await probe(file)
        #expect(facts.codecs == ["aac"])
        #expect(facts.tags["title"] == "clip")
    }

    @Test func aClipRequestReachesTheToolAndIsUnderstood() async throws {
        // yt-dlp can only cut a stream that is split into pieces (HLS, DASH), and a plain
        // file on disk is not. The tool says so by name, which proves it read the section
        // and the exact-cut flag. Cutting a real stream is part of Phase 4's local server tests.
        let root = try Real.scratchFolder("run-clip")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await Real.makeClip(in: root)
        var recipe = DownloadRecipe()
        recipe.clip = Clip(start: 0.2, end: 0.8)
        let request = YtdlpCommand.Request(recipe: recipe, links: ["https://example.com/v"], folder: root.appendingPathComponent("out").path)
        let result = try await run(request, source: source)
        #expect(!result.outcome.succeeded)
        #expect(result.lines.contains { $0.contains("0.2-0.8") }, "\(result.lines.suffix(5))")
        #expect(result.lines.contains { $0.contains("cannot be partially downloaded") })
        let produced = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("out").path)) ?? []
        #expect(produced.isEmpty, "\(produced)")
    }
}
