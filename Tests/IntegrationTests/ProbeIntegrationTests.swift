import Foundation
import Testing
@testable import Engine

// The lookup against the real yt-dlp, without a network: a generated clip
// read from disk, and an address nothing answers on. Real sites are covered
// by the recorded samples in `Fixtures/probe`.

@Suite struct ProbeIntegrationTests {
    /// Runs the engine's own lookup command with the web link swapped for a local file.
    private func lookUp(_ file: URL) async throws -> (result: ProbeResult, output: CapturedOutput) {
        let plan = try Probe.plan(.init(link: "https://example.com/clip"), toolchain: Real.toolchain())
        let output = try await Real.run(plan.executable, Real.pointing(plan.arguments, at: file), environment: plan.environment)
        return (Probe.interpret(output: output.standardOutput, errors: output.standardError, link: file.absoluteString), output)
    }

    @Test func theRealToolAcceptsTheLookupAndItsAnswerIsRead() async throws {
        let folder = try Real.scratchFolder("probe")
        defer { try? FileManager.default.removeItem(at: folder) }
        let clip = try await Real.makeClip(in: folder)

        let (result, output) = try await lookUp(clip)
        #expect(output.outcome.succeeded, "\(output.standardError)")
        #expect(output.standardError.isEmpty, "the lookup is quiet: \(output.standardError)")
        guard case .video(let media) = result else {
            Issue.record("a video is recognised, got \(result)")
            return
        }
        #expect(media.facts.title == "clip")
        #expect(media.formats.count == 1)
        // A bare file: one version, so one choice, and one row in the table.
        #expect(ChoiceBuilder.choices(for: media).map(\.id) == ["best"])
        #expect(FormatCatalog(media).rows().count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["clip.mp4"], "a lookup downloads nothing")
    }

    @Test func aMissingFileIsAFailureWithASentence() async throws {
        let folder = try Real.scratchFolder("probe-missing")
        defer { try? FileManager.default.removeItem(at: folder) }
        let (result, output) = try await lookUp(folder.appendingPathComponent("nothing-here.mp4"))
        #expect(!output.outcome.succeeded)
        guard case .failure(let failure) = result else {
            Issue.record("a failure is reported, got \(result)")
            return
        }
        #expect(!failure.message.isEmpty && !failure.message.contains("ERROR:"))
    }

    @Test func aSiteThatDoesNotAnswerIsExplained() async throws {
        // Port 9 on this machine: nothing listens, so the tool fails at once and no network is used.
        _ = Real.path(.ytdlp)
        let result = await Probe.lookUp(.init(link: "http://127.0.0.1:9/video"), tools: Real.registry)
        #expect(result == .failure(ProbeFailure(kind: .tool(.unreachable), message: Messages.unreachable)))
    }

    @Test func theUsersConfigFileCannotChangeALookup() async throws {
        // A config file that would break any call that read it.
        let folder = try Real.scratchFolder("probe-config")
        defer { try? FileManager.default.removeItem(at: folder) }
        let clip = try await Real.makeClip(in: folder)
        let home = folder.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".config/yt-dlp"), withIntermediateDirectories: true)
        try Data("--no-such-option\n".utf8).write(to: home.appendingPathComponent(".config/yt-dlp/config"))

        let plan = try Probe.plan(.init(link: "https://example.com/clip"), toolchain: Real.toolchain())
        var environment = plan.environment
        environment["HOME"] = home.path
        environment["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config").path
        let output = try await Real.run(plan.executable, Real.pointing(plan.arguments, at: clip), environment: environment)
        #expect(output.outcome.succeeded, "\(output.standardError)")
    }
}
