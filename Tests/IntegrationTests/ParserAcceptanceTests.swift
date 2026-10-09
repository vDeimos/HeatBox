import Foundation
import Testing
@testable import Engine

// "Every generated command is accepted by real yt-dlp's parser" (plan Phase 2).
// Each command is run with `--simulate` against a local file, so nothing is
// downloaded and no network is used; yt-dlp still parses every option,
// compiles every metadata rule and refuses anything it does not know.

@Suite struct ParserAcceptanceTests {
    @Test func yourDownloaderIsInstalledAndRecent() async throws {
        let result = try await Real.run(Real.path(.ytdlp), ["--version"])
        #expect(result.outcome.succeeded)
        #expect(result.standardOutput.hasPrefix("20"), "\(result.standardOutput)")
    }

    @Test func theHarnessCanFail() async throws {
        let folder = try Real.scratchFolder("harness")
        defer { try? FileManager.default.removeItem(at: folder) }
        let clip = try await Real.makeClip(in: folder)
        let args = Real.pointing(["--ignore-config", "--definitely-not-an-option", "--", "https://example.com/v"], at: clip, extra: ["--simulate"])
        let result = try await Real.run(Real.path(.ytdlp), args)
        #expect(!result.outcome.succeeded)
        #expect(result.standardError.contains("no such option"))
    }

    @Test func aBrokenMetadataRuleIsCaught() async throws {
        let folder = try Real.scratchFolder("badrule")
        defer { try? FileManager.default.removeItem(at: folder) }
        let clip = try await Real.makeClip(in: folder)
        let args = Real.pointing(["--ignore-config", "--parse-metadata", "title:(?P<x>", "--", "https://example.com/v"], at: clip, extra: ["--simulate"])
        let result = try await Real.run(Real.path(.ytdlp), args)
        #expect(!result.outcome.succeeded)
    }

    @Test func everyFixtureAndEveryPresetIsAccepted() async throws {
        let folder = try Real.scratchFolder("accept")
        defer { try? FileManager.default.removeItem(at: folder) }
        let clip = try await Real.makeClip(in: folder)
        let toolchain = Real.toolchain()
        var checked = 0
        var failures: [String] = []

        let cookies = folder.appendingPathComponent("cookies.txt")
        try "# Netscape HTTP Cookie File\n".write(to: cookies, atomically: true, encoding: .utf8)

        func check(_ name: String, _ request: YtdlpCommand.Request) async throws {
            var request = request
            // yt-dlp opens a cookies file while parsing, so it has to exist.
            if request.cookiesFile != nil { request.cookiesFile = cookies.path }
            // Reading a real browser's cookies would touch the person running the tests; see the browser-name test.
            request.recipe.cookieBrowser = .none
            guard let plan = try? YtdlpCommand.plan(request, toolchain: toolchain) else { return }
            let args = Real.pointing(plan.arguments, at: clip, extra: ["--simulate"])
            let result = try await Real.run(toolchain.ytdlp, args, environment: toolchain.environment)
            checked += 1
            if !result.outcome.succeeded || result.standardError.contains("yt-dlp: error") {
                failures.append("\(name): \(result.standardError.split(separator: "\n").suffix(2).joined(separator: " | "))")
            }
        }

        for (name, fixture) in try Fixtures.all() {
            try await check(name, try Fixtures.request(from: fixture))
        }
        for preset in PresetCatalog.all {
            var request = YtdlpCommand.Request(recipe: preset.recipe, links: ["https://example.com/v"], folder: folder.path)
            request.archiveFile = folder.appendingPathComponent("archive.txt").path
            try await check("preset \(preset.id)", request)
            // The same preset as a playlist, a clip and with a cut.
            request.recipe = preset.recipe.forPlaylist()
            try await check("preset \(preset.id) as a playlist", request)
        }
        #expect(checked >= 90, "only \(checked) commands were checked")
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    @Test func everyBrowserNameIsOneYtdlpKnows() async throws {
        // Pointed at a folder that does not exist, so no real browser data is read.
        for browser in CookieBrowser.allCases where browser != .none {
            let result = try await Real.run(Real.path(.ytdlp), ["--ignore-config", "--simulate",
                                                                "--cookies-from-browser", "\(browser.rawValue):/nonexistent/profile",
                                                                "--", "https://example.com/v"])
            #expect(!result.standardError.contains("unsupported browser"), "\(browser.rawValue): \(result.standardError)")
            #expect(!result.standardError.contains("no such option"))
        }
    }

    @Test func everyOptionTheAllowlistAcceptsIsARealOption() async throws {
        // An allowed name that yt-dlp does not know would be a typo that protects nothing.
        let help = try await Real.run(Real.path(.ytdlp), ["--help"])
        for (name, values) in ExtraArgsPolicy.allowedLongOptions {
            if help.standardOutput.contains(name) { continue }
            // A hidden option is not listed; the parser must still know it, so it does not say "no such option".
            let result = try await Real.run(Real.path(.ytdlp), ["--ignore-config", "--simulate", name] + Array(repeating: "1", count: values) + ["--", "https://example.com/v"])
            #expect(!result.standardError.contains("no such option"), "yt-dlp has no \(name)")
        }
        for (letter, values) in ExtraArgsPolicy.allowedShortOptions {
            let short = "-\(letter)"
            if help.standardOutput.contains("\(short),") || help.standardOutput.contains("\(short) ") { continue }
            let result = try await Real.run(Real.path(.ytdlp), ["--ignore-config", "--simulate", short] + Array(repeating: "1", count: values) + ["--", "https://example.com/v"])
            #expect(!result.standardError.contains("no such option"), "yt-dlp has no \(short)")
        }
    }

    @Test func yourConfigurationFilesAreNeverRead() async throws {
        // `--ignore-config` is on every command, so a config that would break
        // yt-dlp (or change what it does) is never loaded.
        let home = try Real.scratchFolder("home")
        defer { try? FileManager.default.removeItem(at: home) }
        let configFolder = home.appendingPathComponent(".config/yt-dlp", isDirectory: true)
        try FileManager.default.createDirectory(at: configFolder, withIntermediateDirectories: true)
        try "--this-option-does-not-exist\n".write(to: configFolder.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        var environment = Real.registry.environment()
        environment["HOME"] = home.path
        environment["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config").path

        let clip = try await Real.makeClip(in: home)
        let toolchain = Real.toolchain()
        let plan = try YtdlpCommand.plan(.init(recipe: DownloadRecipe(), links: ["https://example.com/v"], folder: home.path), toolchain: toolchain)
        let args = Real.pointing(plan.arguments, at: clip, extra: ["--simulate"])
        let without = try await Real.run(toolchain.ytdlp, args, environment: environment)
        #expect(without.outcome.succeeded, "\(without.standardError)")

        // Prove the config really would have been read.
        let bare = try await Real.run(toolchain.ytdlp, Array(args.filter { $0 != "--ignore-config" }), environment: environment)
        #expect(!bare.outcome.succeeded)
    }
}
