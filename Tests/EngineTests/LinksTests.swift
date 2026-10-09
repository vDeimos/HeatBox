import Foundation
import Testing
@testable import Engine

// Ported from Phobos's self-check ("Links" and "Links in"), plus the rule
// that only http and https addresses are ever accepted.

@Suite struct LinksTests {
    @Test func linksAreFoundOnceEachInOrder() {
        let found = Links.extract(from: "see https://x.example/1\nhttps://y.example/2, https://x.example/1 thanks")
        #expect(found == ["https://x.example/1", "https://y.example/2"])
    }

    @Test func onlyWebLinksCount() {
        #expect(Links.isWebLink("https://example.com/v"))
        #expect(Links.isWebLink("HTTP://example.com"))
        #expect(!Links.isWebLink("httpx://example.com"))
        #expect(!Links.isWebLink("http-something"))
        #expect(!Links.isWebLink("file:///etc/passwd"))
        #expect(!Links.isWebLink("--exec"))
        #expect(!Links.isWebLink("https://"))
        #expect(Links.extract(from: "httpfoo file:///x --flag ftp://a.example https://ok.example/1") == ["https://ok.example/1"])
    }

    @Test func aVideoInsideAPlaylistMeansThatVideo() {
        let split = Links.splitYouTube("https://www.youtube.com/watch?v=abc123&list=PLxyz&index=4")
        #expect(split?.video == "https://www.youtube.com/watch?v=abc123")
        #expect(split?.playlist == "https://www.youtube.com/playlist?list=PLxyz")
    }

    @Test func shortLinksWork() {
        #expect(Links.splitYouTube("https://youtu.be/abc123")?.video == "https://www.youtube.com/watch?v=abc123")
        #expect(Links.singleVideo("https://youtu.be/abc123?t=5") == "https://www.youtube.com/watch?v=abc123")
    }

    @Test func otherSitesAreLeftAlone() {
        #expect(Links.splitYouTube("https://vimeo.com/123") == nil)
        #expect(Links.singleVideo("https://vimeo.com/123") == "https://vimeo.com/123")
        #expect(Links.splitYouTube("https://notyoutube.com/watch?v=abc123") == nil)
        #expect(Links.splitYouTube("https://evilyoutu.be/abc123") == nil)
    }

    @Test func listsYouTubeWillNotShowAreNotOffered() {
        #expect(Links.splitYouTube("https://www.youtube.com/watch?v=abc123&list=RDabc123&start_radio=1")?.playlist == nil)
        #expect(Links.splitYouTube("https://www.youtube.com/watch?v=abc123&list=LL")?.playlist == nil)
        #expect(Links.splitYouTube("https://www.youtube.com/watch?v=abc123&list=WL")?.playlist == nil)
        #expect(Links.splitYouTube("https://www.youtube.com/watch?v=abc123&list=PLxyz")?.playlist != nil)
    }

    @Test func oddIdentifiersAreNotRebuiltIntoLinks() {
        #expect(Links.splitYouTube("https://www.youtube.com/watch?v=abc%26list%3DPLx") == nil)
        #expect(Links.splitYouTube("https://www.youtube.com/watch?v=abc123&list=PL%20x")?.playlist == nil)
    }

    @Test func channelLinks() {
        #expect(Links.channelVideosURL("https://www.youtube.com/@name") == "https://www.youtube.com/@name/videos")
        #expect(Links.channelVideosURL("https://www.youtube.com/@name/featured") == "https://www.youtube.com/@name/videos")
        #expect(Links.channelVideosURL("https://www.youtube.com/channel/UCabc") == "https://www.youtube.com/channel/UCabc/videos")
        #expect(Links.channelVideosURL("https://www.youtube.com/@name/videos") == "https://www.youtube.com/@name/videos")
        #expect(Links.channelVideosURL("https://www.youtube.com/watch?v=abc") == "https://www.youtube.com/watch?v=abc")
        #expect(Links.channelVideosURL("https://vimeo.com/someone") == "https://vimeo.com/someone")
    }

    @Test func theBrowserButtonCarriesAPageAddress() throws {
        let sent = try #require(URL(string: "\(Engine.urlScheme)://open?url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3Dabc"))
        #expect(Links.linkFromAppURL(sent) == "https://www.youtube.com/watch?v=abc")
        let paste = try #require(URL(string: "\(Engine.urlScheme)://paste"))
        #expect(Links.linkFromAppURL(paste) == nil)
        let other = try #require(URL(string: "phobos://open?url=https%3A%2F%2Fexample.com"))
        #expect(Links.linkFromAppURL(other) == nil)
        let notWeb = try #require(URL(string: "\(Engine.urlScheme)://open?url=file%3A%2F%2F%2Fetc%2Fpasswd"))
        #expect(Links.linkFromAppURL(notWeb) == nil)
        #expect(Links.bookmarklet.contains("\(Engine.urlScheme)://open?url="))
    }

    @Test func aWeblocFileGivesItsAddress() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let good = folder.appendingPathComponent("page.webloc")
        #expect((["URL": "https://example.com/v"] as NSDictionary).write(to: good, atomically: true))
        #expect(Links.weblocTarget(good) == "https://example.com/v")
        let bad = folder.appendingPathComponent("local.webloc")
        #expect((["URL": "file:///etc/passwd"] as NSDictionary).write(to: bad, atomically: true))
        #expect(Links.weblocTarget(bad) == nil)
        #expect(Links.weblocTarget(folder.appendingPathComponent("page.txt")) == nil)

        // The same file, an app link and a web link, as the system hands them over.
        #expect(Links.linkFromOpened(good) == "https://example.com/v")
        #expect(Links.linkFromOpened(bad) == nil)
        #expect(Links.linkFromOpened(folder.appendingPathComponent("notes.txt")) == nil)
        let sent = try #require(URL(string: "\(Engine.urlScheme)://open?url=https%3A%2F%2Fexample.com%2Fv"))
        #expect(Links.linkFromOpened(sent) == "https://example.com/v")
        #expect(Links.linkFromOpened(try #require(URL(string: "https://example.com/watch?v=1"))) == "https://example.com/watch?v=1")
        #expect(Links.linkFromOpened(try #require(URL(string: "phobos://open?url=https%3A%2F%2Fexample.com"))) == nil)
        #expect(Links.linkFromOpened(try #require(URL(string: "mailto:someone@example.com"))) == nil)
    }
}
