import Foundation
import Testing
@testable import Engine

// Golden fixtures (plan Section 5): a recipe in, the exact yt-dlp arguments
// out, as JSON in `Fixtures/golden`. The files are language-neutral on
// purpose, so a Windows port can be held to the same behaviour (D1).
//
// To record a new fixture or accept a deliberate change, run
//     UPDATE_GOLDEN=1 scripts/test.sh --filter GoldenTests
// and read the diff before committing it.

enum GoldenFixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/golden", isDirectory: true)

    static var updating: Bool { ProcessInfo.processInfo.environment["UPDATE_GOLDEN"] == "1" }

    static func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") }.sorted()
    }

    static func load(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func save(_ fixture: [String: Any], as name: String) throws {
        let data = try JSONSerialization.data(withJSONObject: fixture, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: directory.appendingPathComponent(name))
    }

    /// The tools every fixture runs with unless it names its own.
    static let defaultTools: [String: String] = ["ytdlp": "/tools/yt-dlp", "ffmpeg": "/tools/ffmpeg", "deno": "/tools/deno"]

    static func request(from fixture: [String: Any]) throws -> YtdlpCommand.Request {
        var recipe = DownloadRecipe()
        if let id = fixture["preset"] as? String {
            recipe = try #require(PresetCatalog.preset(id: id), "unknown preset \(id)").recipe
        }
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

    static func toolchain(from fixture: [String: Any]) -> YtdlpCommand.Toolchain {
        let tools = fixture["tools"] as? [String: String] ?? defaultTools
        return YtdlpCommand.Toolchain(ytdlp: tools["ytdlp"] ?? "/tools/yt-dlp", ffmpeg: tools["ffmpeg"], deno: tools["deno"],
                                      environment: ["PATH": "/tools"])
    }

    /// What the engine produces for a fixture: a plan, or the sentence it was refused with.
    static func outcome(of fixture: [String: Any]) throws -> [String: Any] {
        let request = try request(from: fixture)
        do {
            let plan = try YtdlpCommand.plan(request, toolchain: toolchain(from: fixture))
            var result: [String: Any] = ["arguments": plan.arguments, "display": plan.displayCommand]
            if !plan.warnings.isEmpty { result["warnings"] = plan.warnings.map(\.message) }
            if !plan.notes.isEmpty { result["notes"] = plan.notes }
            return result
        } catch let failure as YtdlpCommand.Failure {
            return ["refused": failure.message]
        }
    }
}

@Suite struct GoldenTests {
    @Test func everyFixtureProducesItsRecordedCommand() throws {
        let names = try GoldenFixtures.names()
        #expect(names.count >= 60)
        for name in names {
            var fixture = try GoldenFixtures.load(name)
            let actual = try GoldenFixtures.outcome(of: fixture)
            if GoldenFixtures.updating {
                fixture["expect"] = actual
                try GoldenFixtures.save(fixture, as: name)
                continue
            }
            let expected = try #require(fixture["expect"] as? [String: Any], "\(name) has no recorded result; run with UPDATE_GOLDEN=1")
            #expect(NSDictionary(dictionary: actual).isEqual(to: expected), "\(name): got \(actual)")
        }
    }

    @Test func everyBuiltInPresetHasAFixture() throws {
        let names = Set(try GoldenFixtures.names())
        for preset in PresetCatalog.all {
            #expect(names.contains("preset-\(preset.id).json"), "no golden fixture for preset \(preset.id)")
        }
    }

    @Test func thePreviewIsTheExecutedCommandWithoutTheAppsBookkeeping() throws {
        for name in try GoldenFixtures.names() {
            let fixture = try GoldenFixtures.load(name)
            let request = try GoldenFixtures.request(from: fixture)
            guard let plan = try? YtdlpCommand.plan(request, toolchain: GoldenFixtures.toolchain(from: fixture)) else { continue }
            // Nothing the preview shows is missing from the run, and nothing else is hidden but the internals.
            #expect(plan.arguments == plan.internalArguments + plan.visibleArguments, "\(name)")
            #expect(plan.displayCommand == "yt-dlp " + plan.visibleArguments.map(DisplayCommand.shellQuote).joined(separator: " "), "\(name)")
            #expect(plan.internalArguments.first == "--newline", "\(name)")
            #expect(!plan.visibleArguments.contains("--progress-template"), "\(name)")
            #expect(plan.visibleArguments.contains("--ignore-config"), "\(name)")
            let dashes = plan.visibleArguments.firstIndex(of: "--")
            #expect(dashes != nil && plan.visibleArguments[(dashes! + 1)...].elementsEqual(request.links), "\(name)")
        }
    }

    @Test func theDisplayedCommandSplitsBackIntoTheVisibleArguments() throws {
        for name in try GoldenFixtures.names() {
            let fixture = try GoldenFixtures.load(name)
            let request = try GoldenFixtures.request(from: fixture)
            guard let plan = try? YtdlpCommand.plan(request, toolchain: GoldenFixtures.toolchain(from: fixture)) else { continue }
            // The preview survives being pasted into a shell: tokenising it gives the same arguments.
            let tokens = try #require(ExtraArgsPolicy.tokenize(plan.displayCommand), "\(name)")
            #expect(Array(tokens.dropFirst()) == plan.visibleArguments, "\(name)")
        }
    }
}
