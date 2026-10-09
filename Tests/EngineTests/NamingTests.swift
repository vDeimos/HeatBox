import Foundation
import Testing
@testable import Engine

// Ported from Phobos's self-check ("File names" and "Folders").

private let facts = VideoFacts(id: "abc123", title: "My Video", uploader: "Someone", uploadDate: "20261004")

@Suite struct NamingTests {
    @Test func slashesAndColonsAreReplaced() {
        #expect(Naming.clean("a/b: c") == "a-b- c")
    }

    @Test func anEmptyNameBecomesUntitled() {
        #expect(Naming.clean("  ..  ") == "Untitled")
        #expect(Naming.clean("") == "Untitled")
    }

    @Test func aNameCannotLeaveItsFolder() {
        #expect(Naming.clean("..") == "Untitled")
        #expect(Naming.clean("../../etc/passwd") == "-..-etc-passwd")
        #expect(!Naming.clean("a\u{0}b\nc/d").contains("/"))
    }

    @Test func longNamesAreShortened() {
        #expect(Naming.clean(String(repeating: "x", count: 300)).count == 120)
    }

    // A name is measured as a disk measures it, not in characters: macOS's
    // disks take 255 UTF-16 units, others 255 UTF-8 bytes.
    private static let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"

    @Test func aNamesSizeIsWhatADiskCounts() {
        #expect(Naming.size("abc") == 3)
        #expect(Naming.size("漢字") == 6)
        #expect(Naming.size("😀") == 4)
        #expect(Naming.size(Self.family) == 25)
        // "é" as one letter is 2 bytes; a disk that stores the accent apart still counts 2 units.
        #expect(Naming.size("\u{E9}") == 2)
        // A Korean syllable is 3 bytes, and 3 units once taken apart.
        #expect(Naming.size("한") == 3)
    }

    @Test func latinNamesAreCutByCharactersAsBefore() {
        #expect(Naming.clean(String(repeating: "x", count: 119)).count == 119)
        #expect(Naming.clean(String(repeating: "x", count: 121)).count == 120)
    }

    @Test func chineseJapaneseAndKoreanNamesAreCutBySize() {
        let cjk = Naming.clean(String(repeating: "漢", count: 120))
        #expect(cjk.count == 66)
        #expect(cjk.utf8.count == 198)
        let hangul = Naming.clean(String(repeating: "한", count: 120))
        #expect(Naming.size(hangul) <= Naming.stemLimit)
        #expect(hangul.count == 66)
        // Just inside the limit, nothing is cut.
        #expect(Naming.clean(String(repeating: "漢", count: 66)).count == 66)
        #expect(Naming.clean(String(repeating: "漢", count: 67)).count == 66)
    }

    @Test func emojiAreNeverCutInHalf() {
        let faces = Naming.clean(String(repeating: "😀", count: 120))
        #expect(faces.count == 50)
        #expect(faces.utf8.count == 200)
        // A family is one character of 25 bytes: eight fit in 200, never eight and a part.
        let families = Naming.shortened(String(repeating: Self.family, count: 120), toSize: Naming.stemLimit)
        #expect(families == String(repeating: Self.family, count: 8))
        // `clean` takes the invisible joiners out, as it always has, and still keeps to the size.
        let cleaned = Naming.clean(String(repeating: Self.family, count: 120))
        #expect(Naming.size(cleaned) <= Naming.stemLimit)
        #expect(!cleaned.unicodeScalars.contains("\u{200D}"))
        // A letter, then families: the cut falls between two of them.
        let mixed = Naming.shortened("ab" + String(repeating: Self.family, count: 3), toSize: 60)
        #expect(mixed == "ab" + String(repeating: Self.family, count: 2))
    }

    @Test func accentsWrittenSeparatelyStayWithTheirLetter() {
        // "e" followed by a combining acute accent is one character.
        let accented = String(repeating: "e\u{301}", count: 120)
        let cut = Naming.shortened(accented, toSize: 10)
        #expect(cut == String(repeating: "e\u{301}", count: 3))
        #expect(cut.unicodeScalars.last == "\u{301}")
    }

    @Test func aCutNeverLeavesASpaceOrAFullStopAtTheEnd() {
        #expect(Naming.shortened("漢字 漢字", toSize: 7) == "漢字")
        #expect(Naming.shortened("ab. cd", toSize: 4) == "ab")
        #expect(Naming.shortened("short", toSize: 200) == "short")
        #expect(Naming.clean("😀", size: 3) == "Untitled")
    }

    @Test func everyStyleKeepsTheWholeStemInsideTheLimit() {
        for title in [String(repeating: "漢", count: 300), String(repeating: "😀", count: 300),
                      String(repeating: Self.family, count: 300), String(repeating: "x", count: 300)] {
            for uploader in [String(repeating: "字", count: 100), String(repeating: Self.family, count: 60), "Someone"] {
                let long = VideoFacts(id: "abc123", title: title, uploader: uploader, uploadDate: "20261004")
                for style in NameStyle.allCases {
                    let stem = Naming.fileStem(style: style, facts: long)
                    #expect(Naming.size(stem) <= Naming.stemLimit)
                    // With the longest additions the app makes, the name still fits every disk.
                    let name = stem + " (clip) (9999).encoded.en-orig.vtt"
                    #expect(name.utf8.count <= Naming.nameLimit)
                    #expect(name.decomposedStringWithCanonicalMapping.utf16.count <= Naming.nameLimit)
                }
            }
        }
        let wide = VideoFacts(id: "a", title: String(repeating: "漢", count: 300), uploader: String(repeating: "字", count: 100))
        #expect(Naming.fileStem(style: .uploaderTitle, facts: wide).hasPrefix(String(repeating: "字", count: 20) + " - 漢"))
    }

    @Test func aStemMakesRoomForItsEndingAndANumber() {
        let long = String(repeating: "a", count: 300)
        let cut = Naming.stem(long, fitting: ".description")
        #expect(cut.count == 255 - 7 - 12)
        #expect(Naming.stem("A Talk", fitting: ".mp4") == "A Talk")
        // A path that is free is never longer than a disk allows.
        let path = Naming.uniquePath(directory: "/tmp", stem: long + " (Small)", ext: "mp4", exists: { _ in false })
        #expect((path as NSString).lastPathComponent.utf8.count <= 255 - 7)
        let numbered = Naming.uniquePath(directory: "/tmp", stem: long, ext: "mp4", exists: { !$0.hasSuffix("(3).mp4") })
        #expect((numbered as NSString).lastPathComponent.utf8.count <= 255)
        #expect(numbered.hasSuffix(" (3).mp4"))
    }

    @Test func controlCharactersAndRunsOfSpacesCollapse() {
        #expect(Naming.clean("a\tb\n\nc") == "a b c")
    }

    @Test func styles() {
        #expect(Naming.fileStem(style: .title, facts: facts) == "My Video")
        #expect(Naming.fileStem(style: .uploaderTitle, facts: facts) == "Someone - My Video")
        #expect(Naming.fileStem(style: .dateTitle, facts: facts) == "2026-10-04 My Video")
    }

    @Test func noDateFallsBackToTheTitle() {
        var undated = facts
        undated.uploadDate = nil
        #expect(Naming.fileStem(style: .dateTitle, facts: undated) == "My Video")
        undated.uploadDate = "2026-10"
        #expect(Naming.fileStem(style: .dateTitle, facts: undated) == "My Video")
    }

    @Test func noUploaderFallsBackToTheTitle() {
        var anonymous = facts
        anonymous.uploader = ""
        #expect(Naming.fileStem(style: .uploaderTitle, facts: anonymous) == "My Video")
    }

    @Test func aTakenNameGetsTheNextNumber() {
        let taken: Set<String> = ["/t/My Video.mp4", "/t/My Video (2).mp4"]
        #expect(Naming.uniquePath(directory: "/t", stem: "My Video", ext: "mp4", exists: { taken.contains($0) }) == "/t/My Video (3).mp4")
        #expect(Naming.uniquePath(directory: "/t", stem: "Free", ext: "mp4", exists: { taken.contains($0) }) == "/t/Free.mp4")
        #expect(Naming.uniquePath(directory: "/t", stem: "Folder", ext: "", exists: { _ in false }) == "/t/Folder")
    }

    @Test func breadcrumbs() {
        #expect(Naming.breadcrumb("/Users/sam/Movies/YouTube", home: "/Users/sam") == "Movies › YouTube")
        #expect(Naming.breadcrumb("/Volumes/Big/Videos", home: "/Users/sam") == "/Volumes/Big/Videos")
        #expect(Naming.breadcrumb("/Users/sam", home: "/Users/sam") == "Home")
        #expect(Naming.breadcrumb("/Users/samuel/Movies", home: "/Users/sam") == "/Users/samuel/Movies")
    }

    @Test func siteNames() {
        #expect(Naming.siteName(extractorKey: "Youtube", domain: nil) == "YouTube")
        #expect(Naming.siteName(extractorKey: "YoutubeTab", domain: nil) == "YouTube")
        #expect(Naming.siteName(extractorKey: "Twitter", domain: nil) == "X")
        #expect(Naming.siteName(extractorKey: "Generic", domain: "example.com") == "example.com")
        #expect(Naming.siteName(extractorKey: "", domain: nil) == "Other")
    }
}

@Suite struct FolderRulesTests {
    @Test func folders() {
        var rules = FolderRules(mainFolder: "/m", audioFolder: "/a", perSite: ["Reddit": "/clips"], playlistSubfolder: true)
        #expect(rules.folder(site: "YouTube", audioOnly: false, playlistTitle: nil) == "/m/YouTube")
        #expect(rules.folder(site: "Reddit", audioOnly: false, playlistTitle: nil) == "/clips")
        #expect(rules.folder(site: "YouTube", audioOnly: true, playlistTitle: nil) == "/a")
        #expect(rules.folder(site: "YouTube", audioOnly: false, playlistTitle: "My List") == "/m/YouTube/My List")
        rules.playlistSubfolder = false
        #expect(rules.folder(site: "YouTube", audioOnly: false, playlistTitle: "My List") == "/m/YouTube")
    }

    @Test func aPlaylistTitleCannotLeaveTheFolder() {
        let rules = FolderRules(mainFolder: "/m", audioFolder: "/a")
        #expect(rules.folder(site: "YouTube", audioOnly: false, playlistTitle: "../../x") == "/m/YouTube/-..-x")
    }

    @Test func standardFoldersSitInTheHomeFolder() {
        let rules = FolderRules.standard(home: "/Users/sam")
        #expect(rules.mainFolder == "/Users/sam/Movies")
        #expect(rules.audioFolder == "/Users/sam/Music/\(Engine.productName)")
        #expect(rules.playlistSubfolder)
    }
}
