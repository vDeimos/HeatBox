import Foundation
import Testing
@testable import Engine

private func registry(having present: Set<String>, overrides: [Tool: String] = [:]) -> ToolRegistry {
    ToolRegistry(managedFolder: "/managed/bin", overrides: overrides, isExecutable: { present.contains($0) })
}

@Suite struct ToolRegistryTests {
    @Test func allFourToolsAreChecked() {
        let status = registry(having: ["/opt/homebrew/bin/yt-dlp", "/opt/homebrew/bin/ffmpeg"]).status()
        #expect(status.map(\.tool.rawValue) == ["yt-dlp", "ffmpeg", "ffprobe", "deno"])
        #expect(status.map(\.found) == [true, true, false, false])
        #expect(Tool.allCases.allSatisfy { !$0.purpose.isEmpty })
    }

    @Test func aDownloadNeedsThreeOfThem() {
        #expect(registry(having: []).missingForDownloads() == [.ytdlp, .ffmpeg, .deno])
        #expect(registry(having: ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/deno"]).missingForDownloads() == [.ffmpeg])
        // ffprobe is not needed to download.
        #expect(registry(having: ["/opt/homebrew/bin/yt-dlp", "/opt/homebrew/bin/ffmpeg", "/managed/bin/deno"]).missingForDownloads().isEmpty)
    }

    @Test func theManagedFolderWinsOverHomebrew() {
        let tools = registry(having: ["/managed/bin/yt-dlp", "/opt/homebrew/bin/yt-dlp", "/usr/local/bin/ffmpeg"])
        #expect(tools.locate(.ytdlp) == ToolLocation(path: "/managed/bin/yt-dlp", source: .managed))
        #expect(tools.locate(.ffmpeg) == ToolLocation(path: "/usr/local/bin/ffmpeg", source: .system))
        #expect(tools.locate(.deno) == nil)
    }

    @Test func appleSiliconHomebrewWinsOverIntelHomebrew() {
        let tools = registry(having: ["/usr/local/bin/deno", "/opt/homebrew/bin/deno"])
        #expect(tools.path(.deno) == "/opt/homebrew/bin/deno")
    }

    @Test func aUsersChoiceWinsOverEverything() {
        let tools = registry(having: ["/managed/bin/ffmpeg", "/custom/ffmpeg"], overrides: [.ffmpeg: "  /custom/ffmpeg\n"])
        #expect(tools.locate(.ffmpeg) == ToolLocation(path: "/custom/ffmpeg", source: .userOverride))
    }

    @Test func aChoiceThatIsNotAnExecutableIsIgnored() {
        let present: Set<String> = ["/managed/bin/ffmpeg", "relative/ffmpeg"]
        #expect(registry(having: present, overrides: [.ffmpeg: "/gone/ffmpeg"]).path(.ffmpeg) == "/managed/bin/ffmpeg")
        #expect(registry(having: present, overrides: [.ffmpeg: "relative/ffmpeg"]).path(.ffmpeg) == "/managed/bin/ffmpeg")
        #expect(registry(having: present, overrides: [.ffmpeg: "   "]).path(.ffmpeg) == "/managed/bin/ffmpeg")
    }

    @Test func thePathIsFixedAndListsAChosenFolderFirst() {
        let plain = registry(having: [])
        #expect(plain.searchPath == ["/managed/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        let chosen = registry(having: ["/custom/ffmpeg"], overrides: [.ffmpeg: "/custom/ffmpeg"])
        #expect(chosen.searchPath.first == "/custom")
        #expect(chosen.environment()["PATH"] == chosen.searchPath.joined(separator: ":"))
    }

    @Test func theEnvironmentIsBuiltFromScratch() {
        setenv("SXP_TEST_INHERITED", "leak", 1)
        defer { unsetenv("SXP_TEST_INHERITED") }
        let environment = registry(having: []).environment()
        #expect(environment["SXP_TEST_INHERITED"] == nil)
        #expect(Set(environment.keys) == ["PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "PYTHONUNBUFFERED", "PYTHONIOENCODING", "NO_COLOR"])
        #expect(environment["HOME"] == NSHomeDirectory())
    }

    @Test func versionsAreReadFromWhatToolsPrint() {
        #expect(ToolRegistry.parseVersion(of: .ytdlp, from: "2026.08.19\n") == "2026.08.19")
        #expect(ToolRegistry.parseVersion(of: .ffmpeg, from: "ffmpeg version 7.1.1 Copyright (c) 2000-2025 the FFmpeg developers\nbuilt with clang") == "7.1.1")
        #expect(ToolRegistry.parseVersion(of: .ffprobe, from: "ffprobe version N-118000-gabc123 Copyright (c) 2007-2025") == "N-118000-gabc123")
        #expect(ToolRegistry.parseVersion(of: .deno, from: "deno 2.9.7 (stable, release, aarch64-apple-darwin)\nv8 14.0\ntypescript 5.9") == "2.9.7")
        #expect(ToolRegistry.parseVersion(of: .deno, from: "") == nil)
        #expect(ToolRegistry.parseVersion(of: .ffmpeg, from: "something else") == nil)
    }

    @Test func aMissingToolHasNoVersion() async {
        #expect(await registry(having: []).version(of: .ytdlp) == nil)
    }

    @Test func aToolsVersionIsReadByRunningIt() async throws {
        // A stand-in tool: a script in a temporary managed folder.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("deno")
        try "#!/bin/sh\necho \"deno 9.9.9 (test) $1\"\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let tools = ToolRegistry(managedFolder: folder.path)
        #expect(tools.locate(.deno)?.source == .managed)
        #expect(await tools.version(of: .deno) == "9.9.9")
    }

    @Test func theSetupCommandInstallsEverythingAndHomebrewOnlyIfNeeded() {
        #expect(ToolRegistry.homebrewSetupCommand.contains("brew install yt-dlp ffmpeg deno"))
        #expect(ToolRegistry.homebrewSetupCommand.hasPrefix("command -v brew"))
    }
}

@Suite struct BuildVersionTests {
    @Test func aBuildersNameAfterTheNumberIsLeftOut() {
        #expect(ToolRegistry.parseVersion(of: .ffmpeg, from: "ffmpeg version 9.0.2-https://www.martin-riedl.de Copyright (c) 2000-2026") == "9.0.2")
        #expect(ToolRegistry.parseVersion(of: .ffprobe, from: "ffprobe version 7.1.1 Copyright") == "7.1.1")
        // A snapshot's own name is kept whole.
        #expect(ToolRegistry.parseVersion(of: .ffmpeg, from: "ffmpeg version N-122320-g38e89fe502 Copyright") == "N-122320-g38e89fe502")
    }
}
