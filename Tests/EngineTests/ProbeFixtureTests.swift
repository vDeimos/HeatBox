import Foundation
import Testing
@testable import Engine

// Probe fixtures (plan Section 5): what the download tool really said about a
// link, in `Fixtures/probe`, and what the engine makes of it. Like the golden
// fixtures they are language-neutral, so a Windows port can be held to the
// same behaviour (D1).
//
// A fixture is captured with `scripts/capture-probe-fixture.sh`. To record
// its "expect" block, or to accept a deliberate change, run
//     UPDATE_GOLDEN=1 scripts/test.sh --filter ProbeFixtureTests
// and read the diff before committing it.

enum ProbeFixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/probe", isDirectory: true)

    static func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") }.sorted()
    }

    static func load(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func save(_ fixture: [String: Any], as name: String) throws {
        let data = try JSONSerialization.data(withJSONObject: fixture, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: directory.appendingPathComponent(name))
    }

    /// The lookup's result for a fixture, read the way `Probe.lookUp` reads the tool.
    static func result(of fixture: [String: Any]) throws -> ProbeResult {
        let output = try JSONSerialization.data(withJSONObject: fixture["output"] ?? NSNull(), options: [.fragmentsAllowed])
        return Probe.interpret(output: String(decoding: output, as: UTF8.self),
                               errors: fixture["errors"] as? String ?? "",
                               link: try #require(fixture["link"] as? String))
    }

    static func name(of kind: ProbeFailure.Kind) -> String {
        switch kind {
        case .toolMissing: return "toolMissing"
        case .invalidLink: return "invalidLink"
        case .live: return "live"
        case .upcoming: return "upcoming"
        case .emptyPage: return "emptyPage"
        case .unreadable: return "unreadable"
        case .stopped: return "stopped"
        case .tool(let kind): return "tool." + kind.rawValue
        }
    }

    /// Everything the engine decides from a lookup, as plain JSON.
    static func outcome(of result: ProbeResult) -> [String: Any] {
        switch result {
        case .failure(let failure):
            return ["kind": "failure", "failure": name(of: failure.kind), "message": failure.message]
        case .playlist(let list):
            return ["kind": "playlist", "title": list.title, "uploader": list.uploader, "site": list.site,
                    "count": list.count, "link": list.link,
                    "entries": list.entries.map { [$0.id, $0.title, $0.link ?? "", $0.seconds.map { "\($0)" } ?? ""].joined(separator: " | ") }]
        case .video(let media):
            return [
                "kind": "video",
                "id": media.facts.id, "title": media.facts.title, "uploader": media.facts.uploader,
                "uploadDate": media.facts.uploadDate ?? "", "site": media.site, "link": media.link,
                "seconds": media.seconds, "duration": media.duration,
                "thumbnail": media.thumbnail?.absoluteString ?? "",
                "chapters": media.chapters.map { "\(TimeText.clock($0.start)) \($0.title)" },
                "choices": ChoiceBuilder.choices(for: media).map { choice in
                    ["id": choice.id, "title": choice.title, "badge": choice.badge, "size": choice.size,
                     "bytes": choice.bytes.map { NSNumber(value: $0) } ?? NSNull(), "explanation": choice.explanation] as [String: Any]
                },
                // The inspector's table, one line per row.
                "formats": FormatCatalog(media).rows().map { row in
                    [row.id, row.kind, row.ext, row.resolution, row.fps, row.videoCodec, row.audioCodec, row.bitrate, row.size, row.note]
                        .joined(separator: " | ")
                },
            ]
        }
    }
}

@Suite struct ProbeFixtureTests {
    @Test func everyFixtureGivesItsRecordedResult() throws {
        let names = try ProbeFixtures.names()
        for name in names {
            var fixture = try ProbeFixtures.load(name)
            let actual = ProbeFixtures.outcome(of: try ProbeFixtures.result(of: fixture))
            if GoldenFixtures.updating {
                fixture["expect"] = actual
                try ProbeFixtures.save(fixture, as: name)
                continue
            }
            let expected = try #require(fixture["expect"] as? [String: Any], "\(name) has no recorded result; run with UPDATE_GOLDEN=1")
            #expect(NSDictionary(dictionary: actual).isEqual(to: expected), "\(name): got \(actual)")
        }
    }

    /// The samples the plan asks for (Phase 3 verification).
    @Test(arguments: [
        ("video.json", "video"), ("video-chapters.json", "video"), ("video-in-mix.json", "video"),
        ("audio-site.json", "video"), ("single-format.json", "video"),
        ("playlist.json", "playlist"),
        ("mix.json", "failure"), ("live.json", "failure"), ("upcoming.json", "failure"),
        ("unavailable.json", "failure"), ("unsupported.json", "failure"),
    ])
    func theSamplesThePlanAsksForArePresent(name: String, kind: String) throws {
        let fixture = try ProbeFixtures.load(name)
        #expect(ProbeFixtures.outcome(of: try ProbeFixtures.result(of: fixture))["kind"] as? String == kind)
        #expect((fixture["about"] as? String)?.isEmpty == false)
    }

    @Test func fixturesHoldNothingTiedToTheMachineThatCapturedThem() throws {
        for name in try ProbeFixtures.names() {
            let text = try String(contentsOf: ProbeFixtures.directory.appendingPathComponent(name), encoding: .utf8)
            for needle in ["googlevideo", "http_headers", "User-Agent", "forwarded_for", "manifest_url", "cookies", "/Users/"] {
                #expect(!text.contains(needle), "\(name) contains \(needle)")
            }
        }
    }

    private func media(_ name: String) throws -> MediaFacts {
        guard case .video(let media) = try ProbeFixtures.result(of: try ProbeFixtures.load(name)) else {
            throw ProbeFailure.unreadable
        }
        return media
    }

    @Test func aYouTubeVideoOffersEveryTierItHas() throws {
        let media = try media("video.json")
        #expect(media.site == "YouTube")
        #expect(media.seconds > 0 && !media.duration.isEmpty)
        let choices = ChoiceBuilder.choices(for: media)
        #expect(choices.map(\.id) == ["best", "compatible", "res1440", "res1080", "res720", "res480", "res360", "audio"])
        #expect(choices[0].badge == "2160p")
        #expect(choices.allSatisfy { $0.bytes != nil }, "every choice has a size estimate")
        // Sizes fall as the resolution does.
        let tiers = choices.filter { $0.id.hasPrefix("res") }.compactMap(\.bytes)
        #expect(tiers == tiers.sorted(by: >))
        #expect(choices[0].bytes! > tiers[0])
    }

    @Test func oneLookupServesTheChoicesAndTheFormatTable() throws {
        for name in ["video.json", "video-chapters.json", "audio-site.json", "single-format.json"] {
            let media = try media(name)
            let table = FormatCatalog(media)
            #expect(table.formats.count == media.formats.count, "\(name)")
            #expect(table.rows().count == media.formats.count, "\(name)")
            #expect(!ChoiceBuilder.choices(for: media).isEmpty, "\(name)")
            #expect(!table.rows().contains { $0.ext == "mhtml" }, "\(name): storyboards are not formats")
            // Every row can be picked, and what is picked is one of the table's ids.
            for format in table.formats {
                #expect(table.selector(for: [format.id]) == format.id, "\(name)")
            }
        }
        let table = FormatCatalog(try media("video.json"))
        let video = try #require(table.formats(.video).first)
        let audio = try #require(table.formats(.audio).first)
        #expect(table.selector(for: [video.id, audio.id]) == "\(video.id)+\(audio.id)")
    }

    @Test func chaptersAreReadInOrder() throws {
        let media = try media("video-chapters.json")
        #expect(media.chapters.count >= 2)
        #expect(media.chapters.map(\.start) == media.chapters.map(\.start).sorted())
        #expect(media.chapters.first?.start == 0)
        #expect(media.chapters.allSatisfy { !$0.title.isEmpty })
        #expect(try self.media("video.json").chapters.isEmpty)
    }

    @Test func aVideoLinkThatNamesAMixIsReadAsTheVideo() throws {
        #expect(try media("video-in-mix.json").facts.id == media("video.json").facts.id)
    }

    @Test func anAudioSiteOffersNoVideoTiers() throws {
        let media = try media("audio-site.json")
        #expect(media.formats.allSatisfy { $0.kind == .audio })
        #expect(ChoiceBuilder.choices(for: media).map(\.id) == ["best", "audio"])
        #expect(ChoiceBuilder.choices(for: media).last?.bytes != nil)
    }

    @Test func aSingleFileOffersOnlyItself() throws {
        let fixture = try ProbeFixtures.load("single-format.json")
        let media = try media("single-format.json")
        #expect(media.formats.map(\.kind) == [.unknown])
        #expect(ChoiceBuilder.choices(for: media).map(\.title) == ["Original file"])
        #expect(media.link == fixture["link"] as? String, "the link that was given is kept, not the mirror's")
    }

    @Test func aPlaylistIsCountedAndListed() throws {
        guard case .playlist(let list) = try ProbeFixtures.result(of: try ProbeFixtures.load("playlist.json")) else {
            Issue.record("a playlist is recognised")
            return
        }
        #expect(list.count == list.entries.count && list.count > 1)
        #expect(list.site == "YouTube")
        #expect(list.entries.allSatisfy { $0.link.map(Links.isWebLink) == true && !$0.title.isEmpty && !$0.id.isEmpty })
    }

    @Test(arguments: [
        ("mix.json", ProbeFailure(kind: .tool(.unviewablePlaylist), message: Messages.unviewablePlaylist)),
        ("live.json", ProbeFailure.live),
        ("upcoming.json", ProbeFailure.upcoming),
        ("unavailable.json", ProbeFailure(kind: .tool(.unavailable), message: Messages.unavailable)),
        ("unsupported.json", ProbeFailure(kind: .tool(.unsupportedSite), message: Messages.unsupportedSite)),
    ])
    func whatCannotBeDownloadedIsRefusedWithASentence(name: String, failure: ProbeFailure) throws {
        #expect(try ProbeFixtures.result(of: try ProbeFixtures.load(name)) == .failure(failure))
    }
}
