import Foundation
import Testing
@testable import Engine

/// A library on a scratch folder, with a folder standing in for the Trash.
struct LibraryFixture {
    let root: URL
    let media: URL
    let trash: FolderTrash
    let archive: ArchiveBridge
    let library: LibraryRepository

    init(_ name: String = "library") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        media = root.appendingPathComponent("Movies", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        trash = FolderTrash(folder: root.appendingPathComponent("Trash", isDirectory: true))
        archive = ArchiveBridge(file: root.appendingPathComponent("download-archive.txt"))
        library = LibraryRepository(database: root.appendingPathComponent("library.sqlite"),
                                    thumbnails: root.appendingPathComponent("thumbnails", isDirectory: true),
                                    trash: trash, archive: archive)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes a file of `size` bytes and returns its path.
    @discardableResult
    func file(_ relative: String, size: Int = 10) throws -> String {
        let url = media.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: size).write(to: url)
        return url.path
    }

    func record(_ title: String, file relative: String? = nil, size: Int = 10, videoID: String = "", site: String = "YouTube",
                uploader: String = "", choice: String = "Best available", daysAgo: Double = 0, watched: Bool = false,
                archiveID: String? = nil) throws -> LibraryRecord {
        let path = try file(relative ?? "\(title).mp4", size: size)
        return LibraryRecord(videoID: videoID, title: title, uploader: uploader, duration: "1:00", site: site, choice: choice,
                             path: path, link: "https://example.org/\(videoID)", added: LibrarySample.day.addingTimeInterval(-daysAgo * 86_400),
                             watched: watched, bytes: Int64(size), archiveID: archiveID)
    }
}

enum LibrarySample {
    static let day = Date(timeIntervalSince1970: 1_800_000_000)
}

@Suite struct LibraryRepositoryTests {
    @Test func aRecordComesBackAsItWasSaved() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        var record = try fixture.record("A talk", videoID: "abc", uploader: "Some Channel", archiveID: "youtube abc")
        record.thumbnail = "picture.jpg"
        await fixture.library.add(record)
        #expect(await fixture.library.record(record.id) == record)
        #expect(await fixture.library.count() == 1)

        // The same id again replaces the record instead of adding a second one.
        record.title = "A better title"
        await fixture.library.add(record)
        #expect(await fixture.library.records() == [record])
    }

    @Test func theLibrarySurvivesBeingClosedAndOpened() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        let record = try fixture.record("Kept", videoID: "k1")
        await fixture.library.add(record)
        let again = LibraryRepository(database: fixture.root.appendingPathComponent("library.sqlite"),
                                      thumbnails: fixture.root.appendingPathComponent("thumbnails"))
        #expect(await again.records() == [record])
    }

    @Test func aFileThatIsNotALibraryIsSetAsideNotWrittenOver() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        let file = fixture.root.appendingPathComponent("broken.sqlite")
        try Data("this is not a database, but someone may want it".utf8).write(to: file)
        let library = LibraryRepository(database: file, thumbnails: fixture.root.appendingPathComponent("thumbnails"))
        #expect(await library.count() == 0)
        await library.add(try fixture.record("Still works"))
        #expect(await library.count() == 1)
        let aside = fixture.root.appendingPathComponent("library.unreadable.sqlite")
        #expect(try String(contentsOf: aside, encoding: .utf8) == "this is not a database, but someone may want it")
    }

    @Test func searchIgnoresCaseAndAccentsAndWantsEveryWord() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        await fixture.library.add([
            try fixture.record("Café concert in Paris", site: "Vimeo", uploader: "Les Films"),
            try fixture.record("Paris by night", site: "YouTube", uploader: "City Walks"),
            try fixture.record("Rust in an afternoon", site: "YouTube", uploader: "Conference Talks"),
        ])
        func titles(_ text: String) async -> [String] {
            await fixture.library.records(matching: LibraryQuery(text: text, sort: .title)).map(\.title)
        }
        #expect(await titles("cafe") == ["Café concert in Paris"])
        #expect(await titles("PARIS") == ["Café concert in Paris", "Paris by night"])
        #expect(await titles("paris night") == ["Paris by night"])
        // The site and the channel are searched too.
        #expect(await titles("vimeo") == ["Café concert in Paris"])
        #expect(await titles("conference") == ["Rust in an afternoon"])
        #expect(await titles("nothing like this").isEmpty)
        #expect(await titles("   ").count == 3)
        // A percent sign or a quote is just text.
        #expect(await titles("100% ' \" %").isEmpty)
    }

    @Test func filtersAndSortOrders() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        await fixture.library.add([
            try fixture.record("banana", file: "banana.mp4", site: "Vimeo", daysAgo: 3),
            try fixture.record("Apple", file: "Apple.m4a", site: "YouTube", daysAgo: 2, watched: true),
            try fixture.record("cherry", file: "cherry.webm", site: "youtube", daysAgo: 1),
        ])
        func titles(_ query: LibraryQuery) async -> [String] { await fixture.library.records(matching: query).map(\.title) }
        #expect(await titles(LibraryQuery()) == ["cherry", "Apple", "banana"])
        #expect(await titles(LibraryQuery(sort: .oldest)) == ["banana", "Apple", "cherry"])
        #expect(await titles(LibraryQuery(sort: .title)) == ["Apple", "banana", "cherry"])
        #expect(await titles(LibraryQuery(sort: .site)) == ["banana", "cherry", "Apple"])
        #expect(await titles(LibraryQuery(filter: .audio)) == ["Apple"])
        #expect(await titles(LibraryQuery(filter: .video)) == ["cherry", "banana"])
        #expect(await titles(LibraryQuery(filter: .unwatched)) == ["cherry", "banana"])
    }

    @Test func recordsAreGroupedBySiteOrByChannel() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        await fixture.library.add([
            try fixture.record("one", site: "YouTube", uploader: "Zed", daysAgo: 3),
            try fixture.record("two", site: "Vimeo", uploader: "", daysAgo: 2),
            try fixture.record("three", site: "", uploader: "alpha", daysAgo: 1),
        ])
        let bySite = await fixture.library.sections()
        #expect(bySite.map(\.name) == ["Other", "Vimeo", "YouTube"])
        #expect(bySite.map { $0.records.map(\.title) } == [["three"], ["two"], ["one"]])
        let byChannel = await fixture.library.sections(matching: LibraryQuery(byChannel: true))
        #expect(byChannel.map(\.name) == ["alpha", "Unknown channel", "Zed"])
    }

    @Test func watchedIsRememberedAndRemovingLeavesTheFile() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        let record = try fixture.record("A talk")
        await fixture.library.add(record)
        await fixture.library.setWatched(record.id, true)
        #expect(await fixture.library.record(record.id)?.watched == true)

        #expect(await fixture.library.remove(record.id)?.id == record.id)
        #expect(await fixture.library.count() == 0)
        #expect(FileManager.default.fileExists(atPath: record.path))
    }

    @Test func movingToTheTrashCanBeUndone() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        let record = try fixture.record("A talk", videoID: "abc")
        await fixture.library.add(record)

        let trashed = try await fixture.library.trash(record.id)
        #expect(await fixture.library.count() == 0)
        #expect(!FileManager.default.fileExists(atPath: record.path))
        #expect(trashed.trashedAt == fixture.trash.folder.appendingPathComponent("A talk.mp4"))
        #expect(FileManager.default.fileExists(atPath: trashed.trashedAt!.path))

        try await fixture.library.undo(trashed)
        #expect(FileManager.default.fileExists(atPath: record.path))
        #expect(await fixture.library.records() == [record])
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.folder.path).isEmpty)
    }

    @Test func undoNeverWritesOverAFileThatTookTheName() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        let record = try fixture.record("A talk")
        await fixture.library.add(record)
        let trashed = try await fixture.library.trash(record.id)
        try Data("someone else's file".utf8).write(to: URL(fileURLWithPath: record.path))

        await #expect(throws: LibraryFailure.cannotPutBack) { try await fixture.library.undo(trashed) }
        #expect(try String(contentsOfFile: record.path, encoding: .utf8) == "someone else's file")
        #expect(FileManager.default.fileExists(atPath: trashed.trashedAt!.path))
        #expect(await fixture.library.count() == 0)
    }

    @Test func aFileThatCannotBeTrashedKeepsItsRecord() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        let library = LibraryRepository(database: nil, thumbnails: fixture.root.appendingPathComponent("thumbnails"), trash: NoTrash())
        let record = try fixture.record("A talk")
        await library.add(record)
        await #expect(throws: LibraryFailure.cannotTrash) { _ = try await library.trash(record.id) }
        #expect(await library.count() == 1)
        #expect(FileManager.default.fileExists(atPath: record.path))
    }

    @Test func trashingARecordWhoseFileIsGoneJustTakesItOffTheList() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        let record = try fixture.record("A talk")
        await fixture.library.add(record)
        try FileManager.default.removeItem(atPath: record.path)
        let trashed = try await fixture.library.trash(record.id)
        #expect(trashed.trashedAt == nil)
        #expect(await fixture.library.count() == 0)
        await #expect(throws: LibraryFailure.cannotPutBack) { try await fixture.library.undo(trashed) }
    }

    @Test func earlierDownloadsOfAVideoAreFoundWhileTheirFilesExist() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        let first = try fixture.record("A talk", file: "a.mp4", videoID: "abc", choice: "Plays everywhere", daysAgo: 2)
        let second = try fixture.record("A talk", file: "a.m4a", videoID: "abc", choice: "Audio only", daysAgo: 1)
        let gone = try fixture.record("A talk", file: "gone.mp4", videoID: "abc", daysAgo: 3)
        let otherSite = try fixture.record("Another", file: "v.mp4", videoID: "abc", site: "Vimeo")
        let otherVideo = try fixture.record("Different", file: "d.mp4", videoID: "xyz")
        await fixture.library.add([first, second, gone, otherSite, otherVideo])
        await fixture.library.addCopy(of: first.path, at: try fixture.file("a small.mp4"), label: "Smaller")
        try FileManager.default.removeItem(atPath: gone.path)

        let earlier = await fixture.library.earlier(videoID: "abc", site: "YouTube")
        #expect(earlier.map(\.id) == [second.id, first.id])
        #expect(Messages.alreadyInLibrary(versions: earlier.map(\.choice))
            == "You've already downloaded this one in two versions: Audio only and Plays everywhere.")
        #expect(Messages.alreadyInLibrary(versions: ["Audio only", "Audio only"]) == "You've already downloaded this one: Audio only.")
        // A video with no id is never "the same video".
        #expect(await fixture.library.earlier(videoID: "", site: "YouTube").isEmpty)
    }

    @Test func aCopyIsRecordedBesideItsOriginal() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        var original = try fixture.record("A talk", videoID: "abc", uploader: "Channel", archiveID: "youtube abc")
        original.watched = true
        original.thumbnail = "p.jpg"
        await fixture.library.add(original)
        let path = try fixture.file("A talk (small).mp4", size: 4)

        let copy = try #require(await fixture.library.addCopy(of: original.path, at: path, label: "Smaller", now: LibrarySample.day.addingTimeInterval(60)))
        #expect(copy.isCopy && !copy.watched)
        #expect(copy.title == "A talk (small)" && copy.choice == "Smaller" && copy.path == path && copy.bytes == 4)
        #expect(copy.videoID == "abc" && copy.uploader == "Channel" && copy.thumbnail == "p.jpg" && copy.link == original.link)
        #expect(await fixture.library.records().map(\.id) == [copy.id, original.id])
        // A file that is not in the Library has no copy to record.
        #expect(await fixture.library.addCopy(of: "/nowhere/x.mp4", at: path, label: "Smaller") == nil)
    }

    @Test func picturesAreKeptUnderTheirOwnNamesAndSweptWhenUnused() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        let source = fixture.root.appendingPathComponent("abc.webp")
        try Data("picture".utf8).write(to: source)
        let name = try #require(fixture.library.storeThumbnail(from: source, moving: true))
        #expect(name.hasSuffix(".webp") && !FileManager.default.fileExists(atPath: source.path))
        #expect(fixture.library.thumbnailURL(named: name) != nil)
        #expect(fixture.library.thumbnailURL(named: "../library.sqlite") == nil)
        #expect(fixture.library.thumbnailURL(named: nil) == nil)

        var record = try fixture.record("A talk")
        record.thumbnail = name
        await fixture.library.add(record)
        try Data("stray".utf8).write(to: fixture.library.thumbnails.appendingPathComponent("stray.jpg"))
        #expect(await fixture.library.sweepThumbnails() == 1)
        #expect(fixture.library.thumbnailURL(named: name) != nil)
    }

    @Test func changesAreAnnounced() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        var iterator = await fixture.library.changes().makeAsyncIterator()
        // Once at the start, so a screen reads the list straight away.
        await iterator.next()
        await fixture.library.add(try fixture.record("A talk"))
        await iterator.next()
        #expect(await fixture.library.count() == 1)
    }

    @Test func tenThousandRecordsLoadAndSearchQuickly() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        let words = ["concert", "lecture", "tutorial", "interview", "documentary", "review", "podcast", "walkthrough"]
        let records = (0..<10_000).map { index in
            LibraryRecord(videoID: "v\(index)", title: "\(words[index % words.count].capitalized) number \(index)",
                          uploader: "Channel \(index % 50)", duration: "10:00", site: index % 3 == 0 ? "Vimeo" : "YouTube",
                          choice: "Best available", path: "/Volumes/Media/\(index).mp4", link: "https://example.org/\(index)",
                          added: LibrarySample.day.addingTimeInterval(Double(index)), bytes: Int64(index))
        }
        await fixture.library.add(records)
        #expect(await fixture.library.count() == 10_000)

        let clock = ContinuousClock()
        var all: [LibraryRecord] = []
        let load = await clock.measure { all = await fixture.library.records() }
        #expect(all.count == 10_000 && all.first?.title == "Walkthrough number 9999")
        var found: [LibraryRecord] = []
        let search = await clock.measure { found = await fixture.library.records(matching: LibraryQuery(text: "concert 99", sort: .title)) }
        #expect(!found.isEmpty && found.allSatisfy { $0.title.hasPrefix("Concert") && $0.title.contains("99") })
        var sections: [LibrarySection] = []
        let grouping = await clock.measure { sections = await fixture.library.sections(matching: LibraryQuery(byChannel: true)) }
        #expect(sections.count == 50)
        // "Without visible lag". On the development Mac each takes a few
        // hundredths of a second. The limits are far looser, because the
        // suites run side by side and a shared CI runner can be many times
        // slower; they are here to catch work that grows with the square of
        // the library, not to time the machine.
        #expect(load < .seconds(3), "loading took \(load)")
        #expect(search < .seconds(3), "searching took \(search)")
        #expect(grouping < .seconds(3), "grouping took \(grouping)")
    }
}

@Suite struct MovedFileTests {
    @Test func aFileThatIsGoneIsMarkedMissingAndOneThatIsBackIsNot() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        var record = try fixture.record("A talk", size: 123)
        record.bytes = nil
        await fixture.library.add(record)
        // The size is noted while the file is there.
        #expect(await fixture.library.refreshFiles() == LibraryRepository.FileCheck(missing: 0, found: 0))
        #expect(await fixture.library.record(record.id)?.bytes == 123)

        let away = fixture.root.appendingPathComponent("elsewhere.mp4")
        try FileManager.default.moveItem(atPath: record.path, toPath: away.path)
        #expect(await fixture.library.refreshFiles() == LibraryRepository.FileCheck(missing: 1, found: 0))
        #expect(await fixture.library.record(record.id)?.missing == true)

        try FileManager.default.moveItem(atPath: away.path, toPath: record.path)
        #expect(await fixture.library.refreshFiles().missing == 0)
        #expect(await fixture.library.record(record.id)?.missing == false)
    }

    @Test func aFileMovedToAnotherFolderIsFoundByItsNameAndSize() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        let record = try fixture.record("A talk", file: "YouTube/A talk.mp4", size: 500)
        await fixture.library.add(record)
        let moved = fixture.media.appendingPathComponent("Favourites/Deep/A talk.mp4")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: record.path, toPath: moved.path)
        // Another file of the same size but another kind is not it.
        try fixture.file("Favourites/A talk.txt", size: 500)

        #expect(await fixture.library.refreshFiles(searchIn: [fixture.media.path]) == LibraryRepository.FileCheck(missing: 0, found: 1))
        let now = try #require(await fixture.library.record(record.id))
        #expect(now.path == moved.path && !now.missing)
        // Nothing was moved or renamed to get there.
        #expect(FileManager.default.fileExists(atPath: moved.path) && !FileManager.default.fileExists(atPath: record.path))
    }

    @Test func aRenamedFileIsFoundWhenNothingElseCouldBeMeant() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        let record = try fixture.record("A talk", file: "YouTube/A talk.mp4", size: 777)
        await fixture.library.add(record)
        let renamed = fixture.media.appendingPathComponent("YouTube/Watch this later.mp4")
        try FileManager.default.moveItem(atPath: record.path, toPath: renamed.path)

        // Its own folder is looked through even when no other folder is named.
        #expect(await fixture.library.refreshFiles().found == 1)
        #expect(await fixture.library.record(record.id)?.path == renamed.path)
    }

    @Test func twoFilesThatCouldBothBeItLeaveTheRecordMissing() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        let record = try fixture.record("A talk", file: "A talk.mp4", size: 640)
        await fixture.library.add(record)
        try FileManager.default.removeItem(atPath: record.path)
        try fixture.file("one.mp4", size: 640)
        try fixture.file("two.mp4", size: 640)
        #expect(await fixture.library.refreshFiles(searchIn: [fixture.media.path]) == LibraryRepository.FileCheck(missing: 1, found: 0))
        #expect(await fixture.library.record(record.id)?.path == record.path)
    }

    @Test func theVideosIdInANameDecides() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        let record = try fixture.record("A talk", file: "A talk [abc].mp4", size: 640, videoID: "abc")
        await fixture.library.add(record)
        try FileManager.default.removeItem(atPath: record.path)
        try fixture.file("Sorted/Renamed talk [abc].mp4", size: 640)
        try fixture.file("Sorted/Other video [xyz].mp4", size: 640)
        try fixture.file("Sorted/No id at all.mp4", size: 640)
        #expect(await fixture.library.refreshFiles(searchIn: [fixture.media.path]).found == 1)
        #expect(await fixture.library.record(record.id)?.path.hasSuffix("Renamed talk [abc].mp4") == true)
    }

    @Test func aFileAnotherRecordPointsAtIsNeverTaken() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        let gone = try fixture.record("Gone", file: "gone.mp4", size: 900)
        let here = try fixture.record("Here", file: "here.mp4", size: 900)
        await fixture.library.add([gone, here])
        try FileManager.default.removeItem(atPath: gone.path)
        #expect(await fixture.library.refreshFiles(searchIn: [fixture.media.path]) == LibraryRepository.FileCheck(missing: 1, found: 0))
        #expect(await fixture.library.record(here.id)?.path == here.path)
    }

    @Test func twoMissingRecordsDoNotFightOverOneFile() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        let first = try fixture.record("First", file: "first.mp4", size: 321)
        let second = try fixture.record("Second", file: "second.mp4", size: 321)
        await fixture.library.add([first, second])
        try FileManager.default.removeItem(atPath: first.path)
        try FileManager.default.moveItem(atPath: second.path, toPath: fixture.media.appendingPathComponent("renamed.mp4").path)
        // One file, two records it could belong to, no name to go by: neither takes it.
        #expect(await fixture.library.refreshFiles(searchIn: [fixture.media.path]) == LibraryRepository.FileCheck(missing: 2, found: 0))
    }
}

@Suite struct ArchiveBridgeTests {
    @Test func aLineIsTheSitesNameInSmallLettersAndTheId() {
        #expect(ArchiveBridge.entry(extractorKey: "Youtube", videoID: "aqz-KE-bpKQ") == "youtube aqz-KE-bpKQ")
        #expect(ArchiveBridge.entry(extractorKey: "", videoID: "x") == nil)
        #expect(ArchiveBridge.entry(extractorKey: "Vimeo", videoID: " ") == nil)
        #expect(ArchiveBridge.entry(extractorKey: "Two Words", videoID: "x") == nil)
    }

    @Test func linesAreTakenOutAndPutBackWithoutDisturbingTheRest() throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        let archive = fixture.archive
        try Data("youtube one\nvimeo 22\nyoutube three\n".utf8).write(to: archive.file)
        #expect(archive.contains("vimeo 22"))
        #expect(archive.forget(["vimeo 22", "never there"]) == 1)
        #expect(try String(contentsOf: archive.file, encoding: .utf8) == "youtube one\nyoutube three\n")
        archive.remember(["vimeo 22", "youtube one"])
        #expect(try String(contentsOf: archive.file, encoding: .utf8) == "youtube one\nyoutube three\nvimeo 22\n")
        #expect(archive.forget(["youtube one", "youtube three", "vimeo 22"]) == 3)
        #expect(try String(contentsOf: archive.file, encoding: .utf8).isEmpty)
    }

    @Test func noArchiveIsMadeWhenNothingAskedForOne() throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        fixture.archive.remember(["youtube one"])
        #expect(fixture.archive.forget(["youtube one"]) == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.archive.file.path))
    }

    @Test func aTrashedVideoCanBeDownloadedAgainAndUndoRemembersIt() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        try Data("youtube abc\nyoutube other\n".utf8).write(to: fixture.archive.file)
        let record = try fixture.record("A talk", videoID: "abc", archiveID: "youtube abc")
        await fixture.library.add(record)

        let trashed = try await fixture.library.trash(record.id)
        #expect(!fixture.archive.contains("youtube abc") && fixture.archive.contains("youtube other"))
        try await fixture.library.undo(trashed)
        #expect(fixture.archive.contains("youtube abc"))
    }

    @Test func theLineStaysWhileAnotherDownloadOfTheVideoIsOnDisk() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        try Data("youtube abc\n".utf8).write(to: fixture.archive.file)
        let video = try fixture.record("A talk", file: "a.mp4", videoID: "abc", archiveID: "youtube abc")
        let audio = try fixture.record("A talk", file: "a.m4a", videoID: "abc", archiveID: "youtube abc")
        await fixture.library.add([video, audio])
        _ = try await fixture.library.trash(video.id)
        #expect(fixture.archive.contains("youtube abc"))
        _ = try await fixture.library.trash(audio.id)
        #expect(!fixture.archive.contains("youtube abc"))
    }

    @Test func askingForAMissingVideoAgainClearsItsLine() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        try Data("youtube abc\n".utf8).write(to: fixture.archive.file)
        let record = try fixture.record("A talk", videoID: "abc", archiveID: "youtube abc")
        await fixture.library.forgetInArchive(record)
        #expect(!fixture.archive.contains("youtube abc"))
    }
}

@Suite struct DownloadNoteTests {
    @Test func theToolsNoteIsReadPerFinishedFile() throws {
        let lines = """
        {"filepath": "/w/files/One [a1].mp4", "id": "a1", "title": "One", "uploader": "Up", "channel": "Chan", "duration": 61.5, "extractor_key": "Youtube", "webpage_url": "https://www.youtube.com/watch?v=a1"}
        not json at all
        {"filepath": "/w/files/Two [b2].mp4", "id": "b2", "title": "Two", "uploader": null, "channel": "Chan", "duration": null, "extractor_key": "Generic", "webpage_url": "file:///etc/passwd"}
        {"filepath": "/w/files/One [a1].mp4", "id": "a1", "title": "One, again", "extractor_key": "Youtube"}
        """
        let two = try #require(DownloadNote.note(for: "/w/files/Two [b2].mp4", inLines: lines))
        #expect(two.videoID == "b2" && two.title == "Two" && two.uploader == "Chan" && two.seconds == nil)
        // Only a web address is kept as the link.
        #expect(two.link == nil && two.archiveID == "generic b2")
        // The newest note for a file wins.
        let one = try #require(DownloadNote.note(for: "/w/files/../files/One [a1].mp4", inLines: lines))
        #expect(one.title == "One, again" && one.archiveID == "youtube a1" && one.uploader.isEmpty)
        #expect(DownloadNote.note(for: "/w/files/Three.mp4", inLines: lines) == nil)
        #expect(DownloadNote.note(fromLine: #"{"id": "x"}"#) == nil)
    }
}
