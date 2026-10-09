import Foundation
import Testing
@testable import Engine

// The music-tag rules run in the real yt-dlp, over sample video descriptions
// loaded from a file (`--load-info-json`, no network). This is the authority
// on what the rules do; the unit tests only check their shape.

private struct Tags: Equatable {
    var artist = "", title = "", album = "", track = "", albumArtist = "", date = ""
}

private func tags(for info: [String: Any], recipe: DownloadRecipe = PresetCatalog.audioOnly.recipe) async throws -> Tags {
    let folder = try Real.scratchFolder("tags")
    defer { try? FileManager.default.removeItem(at: folder) }
    var full: [String: Any] = [
        "id": "abc123def45", "_type": "video", "extractor": "generic", "extractor_key": "Generic",
        "webpage_url": "https://example.com/v", "url": "https://example.com/a.mp4", "ext": "mp4",
        "formats": [["format_id": "0", "url": "https://example.com/a.mp4", "ext": "mp4"]],
    ]
    full.merge(info) { _, new in new }
    let file = folder.appendingPathComponent("info.json")
    try JSONSerialization.data(withJSONObject: full).write(to: file)

    let separator = "\u{1F}"
    let fields = ["meta_artist", "meta_title", "meta_album", "meta_track", "meta_album_artist", "meta_date"]
    let print = fields.map { "%(\($0)|)s" }.joined(separator: separator)
    let args = ["--ignore-config", "--simulate", "--load-info-json", file.path, "--print", print] + MusicTags.arguments(for: recipe)
    let result = try await Real.run(Real.path(.ytdlp), args)
    #expect(result.outcome.succeeded, "\(result.standardError)")
    let parts = result.standardOutput.components(separatedBy: separator)
    try #require(parts.count == fields.count, "\(result.standardOutput)")
    return Tags(artist: parts[0], title: parts[1], album: parts[2], track: parts[3], albumArtist: parts[4], date: parts[5])
}

@Suite struct MusicTagsIntegrationTests {
    @Test func aMusicVideoIsSplitAndTidied() async throws {
        let result = try await tags(for: ["title": "Radiohead - Karma Police (Official Video)", "uploader": "RadioheadVEVO",
                                          "categories": ["Music"], "upload_date": "19970825"])
        #expect(result.artist == "Radiohead")
        #expect(result.title == "Karma Police")
        #expect(result.albumArtist == "Radiohead")
        #expect(result.date == "1997")
        #expect(result.album == "" && result.track == "")
    }

    @Test func aNumberInFrontOfTheTitleIsDropped() async throws {
        let result = try await tags(for: ["title": "07 - Radiohead - Karma Police", "uploader": "Radiohead", "categories": ["Music"]])
        #expect(result.artist == "Radiohead" && result.title == "Karma Police")
    }

    @Test func aNumberAfterTheArtistIsDroppedToo() async throws {
        let result = try await tags(for: ["title": "Radiohead - 03. Karma Police", "uploader": "Radiohead", "categories": ["Music"]])
        #expect(result.title == "Karma Police")
    }

    @Test func titlesThatStartWithANumberKeepIt() async throws {
        let result = try await tags(for: ["title": "7 Rings", "uploader": "Ariana Grande - Topic", "categories": ["Music"]])
        #expect(result.title == "7 Rings")
        #expect(result.artist == "Ariana Grande")
    }

    @Test func somethingThatIsNotMusicIsNotSplit() async throws {
        let result = try await tags(for: ["title": "Dr. Smith - Episode 4 (Full Episode)", "uploader": "Some Podcast",
                                          "categories": ["People & Blogs"]])
        #expect(result.artist == "Some Podcast")
        #expect(result.title == "Dr. Smith - Episode 4 (Full Episode)")
    }

    @Test func studiosEveryTitleSplitIsAnOption() async throws {
        var recipe = PresetCatalog.audioOnly.recipe
        recipe.splitOnlyMusic = false
        let result = try await tags(for: ["title": "Dr. Smith - Episode 4", "uploader": "Some Podcast",
                                          "categories": ["People & Blogs"]], recipe: recipe)
        #expect(result.artist == "Dr. Smith" && result.title == "Episode 4")
    }

    @Test func theSitesOwnWordsWin() async throws {
        let result = try await tags(for: ["title": "Björk - Hyperballad (Official Video)", "uploader": "BjorkVEVO",
                                          "artist": "Björk", "track": "Hyperballad", "album": "Post", "track_number": 5,
                                          "categories": ["Music"], "release_year": 1995])
        #expect(result == Tags(artist: "Björk", title: "Hyperballad", album: "Post", track: "5", albumArtist: "Björk", date: "1995"))
    }

    @Test func aTrackNumberIsNeverGuessedFromAPlaylistByDefault() async throws {
        let result = try await tags(for: ["title": "A - B", "uploader": "U", "categories": ["Music"],
                                          "playlist_index": 3, "n_entries": 12, "playlist_title": "My Mix"])
        #expect(result.track == "" && result.album == "")
    }

    @Test func studiosPlaylistGuessesWorkWhenAsked() async throws {
        // yt-dlp clears `playlist_index` for a video loaded from a file, so the
        // position itself is checked in Phase 4's playlist run against a local server.
        var recipe = PresetCatalog.audioOnly.recipe
        recipe.trackNumbersFromPlaylist = true
        recipe.albumFallback = true
        let guessed = try await tags(for: ["title": "A - B", "uploader": "U", "categories": ["Music"],
                                           "n_entries": 12, "playlist_title": "My Mix"], recipe: recipe)
        #expect(guessed.album == "My Mix")
        // The site's own track number still wins, and the playlist size completes it.
        let site = try await tags(for: ["title": "A - B", "uploader": "U", "categories": ["Music"], "track_number": 9,
                                        "n_entries": 12], recipe: recipe)
        #expect(site.track == "9/12")
        // Without the guesses the site's number stands alone.
        let plain = try await tags(for: ["title": "A - B", "uploader": "U", "categories": ["Music"], "track_number": 9, "n_entries": 12])
        #expect(plain.track == "9" && plain.album == "")
    }

    @Test func splittingOffLeavesTheWholeTitle() async throws {
        var recipe = PresetCatalog.audioOnly.recipe
        recipe.splitArtistTitle = false
        let result = try await tags(for: ["title": "A - B", "uploader": "A", "categories": ["Music"]], recipe: recipe)
        #expect(result.artist == "A" && result.title == "A - B")
    }

    @Test func cleaningOffKeepsEveryNote() async throws {
        var recipe = PresetCatalog.audioOnly.recipe
        recipe.cleanTitles = false
        recipe.stripTitleNumbers = false
        let result = try await tags(for: ["title": "03 - Song (Official Video)", "uploader": "ArtistVEVO"], recipe: recipe)
        #expect(result.title == "03 - Song (Official Video)")
        #expect(result.artist == "ArtistVEVO")
    }

    @Test func aVideoWithNoUsableTitleDoesNotCrashTheRules() async throws {
        let result = try await tags(for: ["title": "???", "uploader": "Someone"])
        #expect(result.title == "???" && result.artist == "Someone")
    }
}
