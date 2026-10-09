import Foundation
import Testing
@testable import Engine

@Suite struct DiskSpaceTests {
    @Test func aDownloadNeedsTwiceItsSizePlusTheMargin() {
        #expect(DiskSpace.verdict(needed: 1_000_000_000, available: 3_000_000_000) == .enough)
        #expect(DiskSpace.verdict(needed: 1_000_000_000, available: 2_999_999_999)
                == .tooLittle(available: 2_999_999_999, needed: 3_000_000_000))
    }

    @Test func aGuessNeverBlocks() {
        #expect(DiskSpace.verdict(needed: nil, available: 10) == .enough)
        #expect(DiskSpace.verdict(needed: 5_000_000_000, available: nil) == .enough)
        #expect(DiskSpace.verdict(needed: 0, available: 0) == .enough)
    }

    @Test func theSentenceNamesBothFigures() throws {
        let sentence = try #require(DiskSpace.warning(.tooLittle(available: 500_000_000, needed: 3_000_000_000)))
        #expect(sentence.contains("500 MB"))
        #expect(sentence.contains("3 GB"))
        #expect(DiskSpace.warning(.enough) == nil)
    }

    @Test func theRealDiskAnswersForAFolderThatDoesNotExistYet() {
        #expect((DiskSpace.available(at: NSTemporaryDirectory() + "no/such/folder") ?? 0) > 0)
    }
}

@Suite struct DiagnosticsTests {
    private func report(jobs: [Job] = [], settings: AppSettings = AppSettings()) -> String {
        Diagnostics.report(.init(appVersion: "1.0.0", build: "42", system: "Version 27.0", chip: "Apple silicon",
                                 tools: [.init(name: "yt-dlp", version: "2026.08.19", source: "installed by the app"),
                                         .init(name: "deno", version: nil, source: "not found")],
                                 jobs: jobs, settings: settings, freeSpace: 12_000_000_000,
                                 now: Date(timeIntervalSince1970: 0)))
    }

    @Test func itNamesVersionsToolsAndSpace() {
        let text = report()
        #expect(text.contains("App 1.0.0 (build 42)"))
        #expect(text.contains("yt-dlp: 2026.08.19 (installed by the app)"))
        #expect(text.contains("deno: no version (not found)"))
        #expect(text.contains("Free disk space: 12 GB"))
    }

    @Test func itHoldsNothingThatIdentifiesAPersonOrAVideo() {
        var settings = AppSettings()
        settings.toolPaths = ["yt-dlp": "/Users/someone/secret/yt-dlp"]
        var job = Job(createdAt: Date(timeIntervalSince1970: 0),
                      request: JobRequest(resolution: JobResolution(source: .video, link: "https://example.com/watch?v=PRIVATE",
                                                                    title: "My Private Title", site: "Example"),
                                          recipe: DownloadRecipe(), label: "Best available", folder: "/Users/someone/Movies"))
        job.state = .failed
        job.message = "Could not reach https://example.com/watch?v=PRIVATE from /Users/someone/Movies"
        let text = report(jobs: [job], settings: settings)
        #expect(!text.contains("PRIVATE"))
        #expect(!text.contains("My Private Title"))
        #expect(!text.contains("someone"))
        #expect(text.contains("Example: Could not reach <link>"))
    }
}
