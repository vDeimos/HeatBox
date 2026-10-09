import Foundation
import Testing
@testable import Engine

// Studio's comment-chapter and chapter-tagging checks, ported.

private let trackList = "0:00 Intro\n0:02 First song\n0:04 Last song"

private func video(chapters: [[String: Any]] = []) -> [String: Any] {
    ["id": "video-one", "title": "Test album", "duration": 6.0, "chapters": chapters,
     "requested_formats": [["format_id": "a"]],
     "comments": [["id": "comment-one", "author": "Listener", "like_count": 10, "text": trackList]]]
}

private func titles(_ prepared: CommentChapters.Prepared) -> [String] {
    ((prepared.info["chapters"] as? [[String: Any]]) ?? []).compactMap { $0["title"] as? String }
}

@Suite struct CommentChapterParserTests {
    @Test func theUsualWaysOfWritingAListAreRead() {
        let chapters = CommentChapterParser.parse("Track list\n[0:00] Intro\n1. 0:02 First song\nLast song – 0:04", duration: 6)
        #expect(chapters.map(\.title) == ["Intro", "First song", "Last song"])
        #expect(chapters.map(\.start) == [0, 2, 4])
        // Each chapter ends where the next begins, and the last with the video.
        #expect(chapters.map(\.end) == [2, 4, 6])
        let hours = CommentChapterParser.parse("0:00 Intro\n1:02:03 Middle\n2:00:00 End", duration: 8000)
        #expect(hours.map(\.start) == [0, 3723, 7200])
    }

    @Test func bracketsThatBelongToATitleAreKept() {
        let chapters = CommentChapterParser.parse("(0:00) Intro (Live)\n[0:02] - Second [Demo]\n(Remix) Third - 0:04\nFourth (0:05)", duration: 6)
        #expect(chapters.map(\.title) == ["Intro (Live)", "Second [Demo]", "(Remix) Third", "Fourth"])
    }

    @Test func listsThatDoNotAddUpAndTimesInSentencesAreRefused() {
        for text in ["0:00 One\n0:00 Two\n0:04 Three", "0:04 One\n0:02 Two\n0:05 Three",
                     "0:00 One\n0:02 Two\n0:06 Three", "0:00 One\n0:99 Two\n0:04 Three",
                     "0:00 One\n0:02 Two", "I love 0:00 so much\n0:02 Two\n0:04 Three",
                     "0:00 One to 0:01\n0:02 Two\n0:04 Three"] {
            #expect(CommentChapterParser.parse(text, duration: 6).isEmpty, "\(text)")
        }
        #expect(CommentChapterParser.parse(trackList, duration: .infinity).isEmpty)
        #expect(CommentChapterParser.parse(trackList, duration: 0).isEmpty)
    }

    @Test func aListThatStartsLateKeepsTheOpening() {
        let chapters = CommentChapterParser.parse("0:01 One\n0:02 Two\n0:04 Three", duration: 6)
        #expect(chapters.first == CommentChapter(title: Messages.chapterOpening, start: 0, end: 1))
        #expect(chapters.count == 4)
    }

    @Test func theLongestListComesFirstThenTheMostLiked() {
        var info = video()
        info["comments"] = [
            ["id": "b", "author": "B", "like_count": 50, "text": trackList],
            ["id": "a", "author": "A", "like_count": 3, "text": "0:00 A\n0:01 B\n0:02 C\n0:03 D"],
            ["id": "c", "author": "C", "like_count": 90, "text": trackList],
            ["id": "d", "author": "D", "like_count": 900, "text": "Great video at 0:03!"],
            ["author": "No id", "text": trackList],
        ]
        #expect(CommentChapterParser.candidates(in: info).map(\.id) == ["a", "c", "b"])
        info["duration"] = nil
        #expect(CommentChapterParser.candidates(in: info).isEmpty)
    }
}

@Suite struct CommentChaptersTests {
    private let toolchain = YtdlpCommand.Toolchain(ytdlp: "/tools/yt-dlp", ffmpeg: "/tools/ffmpeg", deno: "/tools/deno", environment: [:])

    @Test func theFetchFollowsTheRulesOfEveryCallAndReadsTheTopComments() {
        let args = CommentChapters.fetchArguments(link: "https://youtu.be/x", includeComments: true, cookiesFile: "/c.txt",
                                                  cookieBrowser: .safari, proxy: " socks5://127.0.0.1:9 ", toolchain: toolchain)
        #expect(Array(args.prefix(3)) == ["--ignore-config", "--js-runtimes", "deno:/tools/deno"])
        #expect(Array(args.suffix(2)) == ["--", "https://youtu.be/x"])
        #expect(args.contains("--skip-download") && args.contains("--dump-single-json") && args.contains("--no-playlist"))
        #expect(args.contains("--write-comments") && args.contains("youtube:comment_sort=top;max_comments=200,200,0,0"))
        // A saved sign-in wins over a browser, as everywhere.
        #expect(args.contains("/c.txt") && !args.contains("--cookies-from-browser") && args.contains("socks5://127.0.0.1:9"))
        let plain = CommentChapters.fetchArguments(link: "https://youtu.be/x", includeComments: false, cookiesFile: nil,
                                                   cookieBrowser: .none, proxy: "", toolchain: toolchain)
        #expect(plain.contains("--no-write-comments") && !plain.contains("--write-comments") && !plain.contains("--proxy"))
    }

    @Test func theSitesOwnChaptersAreKeptUnlessCommentsWereAskedFor() throws {
        let own: [[String: Any]] = [["title": "Original", "start_time": 0.0, "end_time": 6.0]]
        #expect(!CommentChapters.lacksChapters(video(chapters: own)))
        #expect(CommentChapters.lacksChapters(video()))
        let kept = try CommentChapters.prepare(video(chapters: own), source: .commentsIfMissing, keepComments: false)
        #expect(titles(kept) == ["Original"] && kept.note == Messages.commentChaptersKeptOwn)
        let replaced = try CommentChapters.prepare(video(chapters: own), source: .comments, keepComments: false)
        #expect(titles(replaced) == ["Intro", "First song", "Last song"])
        #expect(replaced.note == Messages.commentChaptersUsed(3, author: "Listener"))
        // The download makes its own choices, and comments are kept only when they were asked for.
        #expect(replaced.info["comments"] == nil && replaced.info["requested_formats"] == nil)
        #expect(try CommentChapters.prepare(video(), source: .comments, keepComments: true).info["comments"] != nil)
    }

    @Test func noListIsAProblemOnlyWhenCommentsWereAskedFor() throws {
        var bare = video()
        bare["comments"] = []
        #expect(throws: CommentChapters.Problem.noneFound) { try CommentChapters.prepare(bare, source: .comments, keepComments: false) }
        let quiet = try CommentChapters.prepare(bare, source: .commentsIfMissing, keepComments: false)
        #expect(titles(quiet).isEmpty && quiet.note == Messages.commentChaptersNoneQuiet)
    }

    @Test func aPickedCommentIsUsedAndOneThatIsGoneIsAProblem() throws {
        var info = video()
        info["comments"] = (info["comments"] as! [[String: Any]]) + [["id": "comment-two", "author": "Other", "like_count": 1, "text": "0:00 A\n0:02 B\n0:04 C"]]
        #expect(titles(try CommentChapters.prepare(info, source: .comments, selection: "comment-two", keepComments: false)) == ["A", "B", "C"])
        #expect(throws: CommentChapters.Problem.selectionGone) {
            try CommentChapters.prepare(info, source: .comments, selection: "deleted", keepComments: false)
        }
    }

    @Test func aListOfVideosIsNotPrepared() {
        #expect(throws: CommentChapters.Problem.notOneVideo) {
            try CommentChapters.prepare(["entries": [video()]], source: .comments, keepComments: false)
        }
    }
}

@Suite struct ChapterTaggerTests {
    private func line(_ titles: [String], file: String = "/w/files/Album [id].mp3") -> String {
        let chapters = titles.enumerated().map { ["title": $1, "filepath": "/w/files/Album (chapters)/00\($0 + 1) \($1).mp3"] }
        let data = try! JSONSerialization.data(withJSONObject: ["filepath": file, "chapters": chapters])
        return String(decoding: data, as: UTF8.self)
    }

    @Test func aRecordNamesTheFileAndItsTracksWithTidiedTitles() throws {
        let recipe = PresetCatalog.audioOnly.recipe
        let record = try #require(ChapterTagger.record(fromLine: line(["01. Intro (Official Audio)", "Daft Punk - 02 Aerodynamic", "7 Rings"]), recipe: recipe))
        #expect(record.file == "/w/files/Album [id].mp3")
        #expect(record.tracks.map(\.title) == ["Intro", "Aerodynamic", "7 Rings"])
        #expect(record.tracks.map(\.artist) == [nil, "Daft Punk", nil])
        #expect(record.tracks[0].path == "/w/files/Album (chapters)/001 01. Intro (Official Audio).mp3")
        // With the tidying switched off, titles are kept as the site wrote them.
        var plain = recipe
        plain.cleanTitles = false
        plain.stripTitleNumbers = false
        plain.splitArtistTitle = false
        #expect(ChapterTagger.record(fromLine: line(["01. Intro (Official Audio)"]), recipe: plain)?.tracks.map(\.title) == ["01. Intro (Official Audio)"])
    }

    @Test func aVideoWithoutChaptersAndALineThatIsNotARecordGiveNoTracks() {
        let recipe = PresetCatalog.audioOnly.recipe
        #expect(ChapterTagger.record(fromLine: #"{"filepath": "/w/files/a.mp3", "chapters": null}"#, recipe: recipe)?.tracks.isEmpty == true)
        // Chapters that were not split off have no file of their own.
        #expect(ChapterTagger.record(fromLine: #"{"filepath": "/w/files/a.mp3", "chapters": [{"title": "One", "start_time": 0}]}"#, recipe: recipe)?.tracks.isEmpty == true)
        #expect(ChapterTagger.record(fromLine: "NA", recipe: recipe) == nil)
        #expect(ChapterTagger.record(fromLine: "", recipe: recipe) == nil)
    }

    @Test func theRecordForAFileIsFoundAmongTheLines() {
        let recipe = PresetCatalog.audioOnly.recipe
        let text = line(["A"], file: "/w/files/One [1].mp3") + "\n" + line(["B", "C"], file: "/w/files/Two [2].mp3") + "\n"
        #expect(ChapterTagger.record(for: "/w/files/Two [2].mp3", inLines: text, recipe: recipe)?.tracks.map(\.title) == ["B", "C"])
        #expect(ChapterTagger.record(for: "/w/files/./One [1].mp3", inLines: text, recipe: recipe)?.tracks.map(\.title) == ["A"])
        #expect(ChapterTagger.record(for: "/w/files/Three [3].mp3", inLines: text, recipe: recipe) == nil)
    }

    @Test func trackNumbersAreRemovedAndTitlesThatStartWithANumberAreNot() {
        let numbered = ["01. One More Time", "1 - Aerodynamic", "03 Digital Love", "[04] Harder, Better, Faster, Stronger",
                        "(5) Crescendolls", "#6 - Nightvision", "Track 7 - Superheroes", "8) High Life",
                        "09: Something About Us", "10 \u{2013} Voyager", "11.Veridis Quo", "12 \u{2014} Short Circuit", "track 13: Face to Face"]
        for title in numbered {
            let stripped = ChapterTagger.stripTrackNumber(title)
            #expect(stripped != title && stripped.first?.isNumber == false, "\(title) -> \(stripped)")
        }
        #expect(ChapterTagger.stripTrackNumber("01. One More Time") == "One More Time")
        let real = ["7 Rings", "99 Luftballons", "1999", "2 Become 1", "4:44", "1-800-273-8255", "9 to 5", "21 Guns",
                    "1.5 Seconds", "50 Ways to Leave Your Lover", "22", "007 (Shanty Town)", "Notorious", "No Scrubs",
                    "10,000 Hours", "3 Libras", "1 Thing"]
        for title in real { #expect(ChapterTagger.stripTrackNumber(title) == title, "\(title)") }
    }

    @Test func aTrackIsRetaggedByCopyWithItsOwnTitleAndNumber() {
        let track = ChapterTagger.Track(path: "/w/files/a/001 Intro.mp3", title: "Intro", artist: "Band")
        let cover = ChapterTagger.Cover(path: "/w/scratch/c.img", mime: "image/jpeg")
        let args = ChapterTagger.retagArguments(track: track, index: 2, total: 9, cover: cover, pictureBlock: nil, output: "/w/scratch/o.mp3")
        #expect(args.contains("title=Intro") && args.contains("track=3/9") && args.contains("artist=Band"))
        #expect(args.contains("copy") && args.contains("attached_pic") && args.contains("/w/scratch/c.img"))
        #expect(args.last == "/w/scratch/o.mp3" && args.contains("-id3v2_version"))
        // Ogg takes no picture stream: no second input, the tags lifted off the stream, the cover as a tag.
        let ogg = ChapterTagger.Track(path: "/w/files/a/001 Intro.opus", title: "Intro", artist: nil)
        let oggArgs = ChapterTagger.retagArguments(track: ogg, index: 0, total: 1, cover: cover, pictureBlock: "QUJD", output: "/w/scratch/o.opus")
        #expect(!oggArgs.contains("/w/scratch/c.img") && !oggArgs.contains("attached_pic"))
        #expect(oggArgs.contains("0:s:a:0") && oggArgs.contains("METADATA_BLOCK_PICTURE=QUJD") && !oggArgs.contains { $0.hasPrefix("artist=") })
    }

    @Test func thePictureTagIsAFLACPictureBlock() throws {
        let image = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        let block = try #require(Data(base64Encoded: ChapterTagger.pictureBlock(image: image, mime: "image/jpeg")))
        func number(at offset: Int) -> Int { block[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) } }
        #expect(number(at: 0) == 3)                       // front cover
        #expect(number(at: 4) == 10)                      // length of "image/jpeg"
        #expect(String(decoding: block[8..<18], as: UTF8.self) == "image/jpeg")
        #expect(number(at: 18) == 0)                      // no description
        #expect(number(at: 38) == image.count)
        #expect(block.suffix(image.count) == image && block.count == 42 + image.count)
        #expect(ChapterTagger.mime(of: image) == "image/jpeg")
        #expect(ChapterTagger.mime(of: Data([0x89, 0x50, 0x4E, 0x47, 0x0D])) == "image/png")
        #expect(ChapterTagger.mime(of: Data("GIF89a".utf8)) == nil)
    }
}
