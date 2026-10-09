import Foundation
import Testing
@testable import Engine

// Ported from Phobos's "song tags" checks and Studio's music-tag rules.
// These check the rules' shape and the patterns on their own (Python's
// `(?P<name>` is spelt `(?<name>` for ICU); IntegrationTests runs the real
// rules in yt-dlp against sample videos.

private func rules(_ edit: (inout DownloadRecipe) -> Void = { _ in }) -> [String] {
    var recipe = PresetCatalog.audioOnly.recipe
    edit(&recipe)
    return MusicTags.arguments(for: recipe)
}

/// ICU group names cannot contain an underscore, so they are dropped from both pattern and lookup.
private func icu(_ pattern: String) -> NSRegularExpression {
    var converted = pattern
    for name in ["music_title", "clean_title"] { converted = converted.replacingOccurrences(of: "(?P<\(name)>", with: "(?<\(name.replacingOccurrences(of: "_", with: ""))>") }
    return try! NSRegularExpression(pattern: converted.replacingOccurrences(of: "(?P<", with: "(?<"))
}

private func captures(_ pattern: String, in text: String, group: String) -> String? {
    let regex = icu(pattern)
    let range = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, range: range) else { return nil }
    let found = match.range(withName: group.replacingOccurrences(of: "_", with: ""))
    return found.location == NSNotFound ? nil : String(text[Range(found, in: text)!])
}

private func removing(_ pattern: String, from text: String) -> String {
    icu(pattern).stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
}

@Suite struct MusicTagsTests {
    @Test func noRulesUnlessTagsAreActive() {
        #expect(MusicTags.arguments(for: DownloadRecipe()).isEmpty)
        #expect(rules { $0.musicTags = false }.isEmpty)
        #expect(rules { $0.embedMetadata = false }.isEmpty)
        #expect(!rules().isEmpty)
        // Video gets tags only when asked.
        var video = DownloadRecipe()
        video.musicTagsOnVideo = true
        #expect(!MusicTags.arguments(for: video).isEmpty)
    }

    @Test func theArtistFallsBackToTheChannel() {
        #expect(rules().contains("%(artist,ta,uploader|)s:%(meta_artist)s"))
    }

    @Test func albumAndTrackNameAreReadWhereTheSiteHasThem() {
        let all = rules()
        #expect(all.contains("%(album|)s:%(meta_album)s"))
        #expect(all.contains { $0.hasPrefix("%(track,tt,") && $0.hasSuffix(":%(meta_title)s") })
    }

    @Test func theTrackNumberComesOnlyFromTheSiteByDefault() {
        let all = rules()
        #expect(all.contains("%(track_number|)s:%(meta_track)s"))
        #expect(!all.contains { $0.contains("playlist_index") })
    }

    @Test func studiosPlaylistGuessesAreOptions() {
        let guessing = rules { $0.trackNumbersFromPlaylist = true; $0.albumFallback = true }
        #expect(guessing.contains { $0.contains("playlist_index") && $0.contains("meta_track") })
        #expect(guessing.contains { $0.contains("playlist_title") && $0.contains("meta_album") })
        #expect(!guessing.contains("%(track_number|)s:%(meta_track)s"))
        #expect(!guessing.contains("%(album|)s:%(meta_album)s"))
    }

    @Test func onlyMusicIsSplitIntoArtistAndTitle() {
        let all = rules()
        #expect(all.contains { $0.contains("music_title") && $0.contains("Music") })
        #expect(all.contains { $0.hasPrefix("%(music_title|)s:") && $0.contains("(?P<ta>") })
    }

    @Test func studiosEveryTitleSplitIsAnOption() {
        let all = rules { $0.splitOnlyMusic = false }
        #expect(!all.contains { $0.contains("music_title") })
        #expect(all.contains { $0.contains("(?P<ta>") && $0.contains("(?P<tt>") })
    }

    @Test func splittingCanBeSwitchedOff() {
        #expect(!rules { $0.splitArtistTitle = false }.contains { $0.contains("(?P<ta>") })
    }

    @Test func aTopicOrVevoChannelLosesItsSuffix() {
        let all = rules()
        let index = all.firstIndex(of: "meta_artist,meta_album_artist")
        #expect(index != nil)
        let pattern = all[all.index(after: index!)]
        #expect(removing(pattern, from: "Radiohead - Topic") == "Radiohead")
        #expect(removing(pattern, from: "RadioheadVEVO") == "Radiohead")
        #expect(removing(pattern, from: "Radiohead Official") == "Radiohead")
        #expect(removing(pattern, from: "Official Radiohead") == "Official Radiohead")
        #expect(removing(pattern, from: "Topic Cats") == "Topic Cats")
    }

    @Test func officialVideoStyleNotesAreDropped() {
        for note in ["(Official Video)", "[Lyrics]", "(HD)", "(Full Album)", "[Official Music Video]", "(Remastered 2011)",
                     "(Official Audio)", "(Lyric Video)", "[4K]", "(Visualizer)", "(visualiser)"] {
            #expect(removing(MusicTags.junkTitlePattern, from: "Song \(note)") == "Song", "\(note)")
        }
        for keep in ["Song (Live in Paris)", "Song (feat. Someone)", "Song [Remix]", "Video Games", "Hdr"] {
            #expect(removing(MusicTags.junkTitlePattern, from: keep) == keep, "\(keep)")
        }
    }

    @Test func aNumberInFrontOfTheTitleIsDropped() {
        for (title, clean) in [("01. Song", "Song"), ("1 - Song", "Song"), ("03 Song", "Song"), ("[04] Song", "Song"),
                               ("(5) Song", "Song"), ("#6 - Song", "Song"), ("Track 7 - Song", "Song"), ("8) Song", "Song"),
                               ("09: Song", "Song"), ("007 - Song", "Song")] {
            #expect(captures(MusicTags.numberStrippingPattern(into: "t"), in: title, group: "t") == clean, "\(title)")
        }
    }

    @Test func realTitlesThatStartWithANumberSurvive() {
        for title in ["7 Rings", "99 Luftballons", "4:44", "1-800-273-8255", "2 Become 1", "1999", "21 Guns", "12:51"] {
            #expect(captures(MusicTags.numberStrippingPattern(into: "t"), in: title, group: "t") == title, "\(title)")
            #expect(removing(MusicTags.leadingNumberRemovalPattern, from: title) == title, "\(title)")
        }
    }

    @Test func aNumberAfterTheArtistIsDroppedFromTheTitle() {
        #expect(removing(MusicTags.leadingNumberRemovalPattern, from: "03. Song") == "Song")
        #expect(removing(MusicTags.leadingNumberRemovalPattern, from: "03.") == "03.")
    }

    @Test func artistAndTitleSplitAtADash() {
        for dash in ["-", "–", "—"] {
            let title = "Radiohead \(dash) Karma Police"
            #expect(captures(MusicTags.artistTitlePattern, in: title, group: "ta") == "Radiohead")
            #expect(captures(MusicTags.artistTitlePattern, in: title, group: "tt") == "Karma Police")
        }
        // The first dash splits, so a dash in the title stays in the title.
        #expect(captures(MusicTags.artistTitlePattern, in: "A - B - C", group: "tt") == "B - C")
        // No spaces around the dash means it is part of a word, and a leading number is not an artist.
        #expect(captures(MusicTags.artistTitlePattern, in: "Jay-Z", group: "ta") == nil)
        #expect(captures(MusicTags.artistTitlePattern, in: "01 - Song", group: "ta") == nil)
    }

    @Test func theMusicCategoryGuardNeedsTheWordMusic() {
        let guarded = "Music, Entertainment|Radiohead - Karma Police"
        #expect(captures(MusicTags.musicCategoryPattern, in: guarded, group: "music_title") == "Radiohead - Karma Police")
        #expect(captures(MusicTags.musicCategoryPattern, in: "People & Blogs|Guest - Episode 4", group: "music_title") == nil)
        #expect(captures(MusicTags.musicCategoryPattern, in: "Musicals|A - B", group: "music_title") == nil)
        #expect(captures(MusicTags.musicCategoryPattern, in: "|A - B", group: "music_title") == nil)
    }

    @Test func theRulesRunInAnOrderThatWorks() throws {
        let all = rules()
        func position(_ text: String) throws -> Int { try #require(all.firstIndex { $0.contains(text) }, "\(text)") }
        // Strip numbers, then split, then fill the tags, then tidy.
        #expect(try position("clean_title") < position("music_title"))
        #expect(try position("music_title") < position("%(artist,ta,uploader|)s"))
        #expect(try position("%(artist,ta,uploader|)s") < position("%(album|)s"))
        #expect(try position("meta_album_artist") < all.firstIndex(of: "--replace-in-metadata")!)
        #expect(all.filter { $0 == "--replace-in-metadata" }.count == 3)
    }

    @Test func turningTidyingOffKeepsTheTitleAsTheSiteWroteIt() {
        let plain = rules { $0.cleanTitles = false; $0.stripTitleNumbers = false }
        #expect(!plain.contains("--replace-in-metadata"))
        #expect(!plain.contains { $0.contains("clean_title") })
        #expect(plain.contains { $0.hasPrefix("%(track,tt,title|)s") })
    }

    @Test func rulesComeInPairs() {
        // Every rule is a flag and one value; a replacement has three values.
        var iterator = rules()[...]
        while let flag = iterator.popFirst() {
            #expect(flag == "--parse-metadata" || flag == "--replace-in-metadata")
            let count = flag == "--parse-metadata" ? 1 : 3
            #expect(iterator.count >= count)
            iterator = iterator.dropFirst(count)
        }
    }
}
