import Foundation
import Testing
@testable import Engine

@Suite struct VersioningTests {
    @Test func aLaterVersionIsNewer() {
        #expect(Versioning.isNewer("2.2", than: "2.1"))
        #expect(!Versioning.isNewer("2.1", than: "2.1"))
        #expect(Versioning.isNewer("2.10", than: "2.9"))
        #expect(Versioning.isNewer("2.0.1", than: "2.0"))
        #expect(!Versioning.isNewer("1.9", than: "2.0"))
        #expect(Versioning.isNewer("v1.0", than: "0.0.0"))
        #expect(!Versioning.isNewer("", than: "0.0.0"))
    }

    @Test func theNoticeFileIsReadAndOnlyAWebLinkIsKept() throws {
        let notice = try #require(Versioning.parseNotice(Data("{\"version\":\"2.2\",\"url\":\"https://example.com/p\",\"note\":\"Fixes things\"}".utf8)))
        #expect(notice == Versioning.Notice(version: "2.2", url: "https://example.com/p", note: "Fixes things"))
        #expect(Versioning.parseNotice(Data("nonsense".utf8)) == nil)
        #expect(Versioning.parseNotice(Data("{\"version\":\"  \"}".utf8)) == nil)
        // The button can only ever open a web page.
        #expect(Versioning.parseNotice(Data("{\"version\":\"3\",\"url\":\"file:///Applications/Evil.app\"}".utf8))?.url == "")
        #expect(Versioning.parseNotice(Data("{\"version\":\"3\",\"url\":\"studioxphobos://open?url=x\"}".utf8))?.url == "")
    }

    @Test func onlyALaterVersionIsShown() {
        let data = Data("{\"version\":\"1.2\"}".utf8)
        #expect(Versioning.notice(in: data, current: "1.1")?.version == "1.2")
        #expect(Versioning.notice(in: data, current: "1.2") == nil)
        #expect(Versioning.notice(in: data, current: "2.0") == nil)
    }

    @Test func withNoAddressNothingIsAskedAndOnlyASecureOneCounts() {
        #expect(Versioning.noticeAddress(nil) == nil)
        #expect(Versioning.noticeAddress("") == nil)
        #expect(Versioning.noticeAddress("   ") == nil)
        #expect(Versioning.noticeAddress("http://example.com/latest.json") == nil)
        #expect(Versioning.noticeAddress("file:///tmp/latest.json") == nil)
        #expect(Versioning.noticeAddress(" https://example.com/latest.json ")?.absoluteString == "https://example.com/latest.json")
    }
}

@Suite struct TourTests {
    @Test func theTourHasFourStepsAndEnds() {
        #expect(Tour.steps.count == 4)
        #expect(Tour.steps.allSatisfy { !$0.symbol.isEmpty && !$0.title.isEmpty && !$0.text.isEmpty })
        #expect(Set(Tour.steps.map(\.title)).count == 4)
        #expect(Tour.next(after: 0) == 1 && Tour.next(after: 2) == 3 && Tour.next(after: 3) == nil)
        #expect(Tour.back(from: 2) == 1 && Tour.back(from: 0) == 0)
        #expect(Tour.steps.last?.text.contains(Engine.productName) == true)
    }
}

@Suite struct SignInTests {
    private let jar = "# Netscape HTTP Cookie File\n\n.youtube.com\tTRUE\t/\tTRUE\t0\tSID\tabc\n#HttpOnly_.google.com\tTRUE\t/\tTRUE\t0\tHSID\tdef\n.example.com\tTRUE\t/\tFALSE\t0\tx\ty\n.notyoutube.com\tTRUE\t/\tFALSE\t0\tfake\tz\naccounts.google.com\tFALSE\t/\tTRUE\t0\tLSID\tghi\n"

    @Test func onlyYouTubeAndGoogleEntriesAreKept() {
        let kept = SignIn.keepYouTubeAndGoogle(jar)
        #expect(kept.contains("SID\tabc") && kept.contains("HSID\tdef") && kept.contains("LSID\tghi"))
        #expect(kept.hasPrefix("# Netscape HTTP Cookie File\n"))
        #expect(!kept.contains("example.com"))
        // A site whose name merely ends the same way is not YouTube.
        #expect(!kept.contains("notyoutube.com"))
        #expect(SignIn.browsers.count == 5 && !SignIn.browsers.contains(.none))
    }

    @Test func theCommandReadsOneBrowserAndDownloadsNothing() {
        let toolchain = YtdlpCommand.Toolchain(ytdlp: "/tools/yt-dlp", deno: "/tools/deno", environment: [:])
        let args = SignIn.captureArguments(browser: .firefox, jar: "/private/jar.tmp", toolchain: toolchain)
        #expect(args.first == "--ignore-config" && args.contains("--simulate"))
        #expect(args.contains("--cookies-from-browser") && args.contains("firefox") && args.contains("/private/jar.tmp"))
        #expect(args.dropLast().last == "--" && Links.isWebLink(args.last ?? ""))
    }

    private func setUp(_ name: String, _ body: String) throws -> (tools: StandIns, destination: URL) {
        let tools = try StandIns(name)
        try tools.tool(.ytdlp, body)
        return (tools, tools.root.appendingPathComponent("support/cookies.txt"))
    }

    /// Writes the cookie list above into whatever file follows --cookies.
    private var writesJar: String {
        """
        echo "$@" >> "$HERE/calls.log"
        prev=""
        for arg; do if [ "$prev" = "--cookies" ]; then jar="$arg"; fi; prev="$arg"; done
        printf '\(jar.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t"))' > "$jar"
        echo "Me at the zoo"
        """
    }

    @Test func aSignInIsSavedPrivatelyWithNothingFromOtherSites() async throws {
        let s = try setUp("signin-ok", writesJar)
        defer { s.tools.cleanUp() }
        #expect(await SignIn.capture(browser: .firefox, to: s.destination, tools: s.tools.registry) == nil)
        let saved = try String(contentsOf: s.destination, encoding: .utf8)
        #expect(saved.contains("SID\tabc") && saved.contains("HSID\tdef") && !saved.contains("example.com"))
        let mode = (try FileManager.default.attributesOfItem(atPath: s.destination.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
        // The list of every site's cookies is gone again.
        let left = try FileManager.default.contentsOfDirectory(atPath: s.destination.deletingLastPathComponent().path)
        #expect(left == ["cookies.txt"])
        #expect(s.tools.text("calls.log").contains("--cookies-from-browser firefox"))
    }

    @Test func aFailureIsOneSentenceAndAnEarlierSignInIsKept() async throws {
        let blocked = try setUp("signin-blocked", "echo 'ERROR: could not find firefox cookies database' >&2; exit 1")
        defer { blocked.tools.cleanUp() }
        try FileManager.default.createDirectory(at: blocked.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("earlier".utf8).write(to: blocked.destination)
        #expect(await SignIn.capture(browser: .firefox, to: blocked.destination, tools: blocked.tools.registry) == Messages.signInBlocked)
        #expect(try String(contentsOf: blocked.destination, encoding: .utf8) == "earlier")
        #expect(try FileManager.default.contentsOfDirectory(atPath: blocked.destination.deletingLastPathComponent().path) == ["cookies.txt"])

        // A browser that is not signed in to YouTube gives nothing worth saving.
        let empty = try setUp("signin-empty", """
        prev=""
        for arg; do if [ "$prev" = "--cookies" ]; then jar="$arg"; fi; prev="$arg"; done
        printf '# Netscape HTTP Cookie File\\n.example.com\\tTRUE\\t/\\tFALSE\\t0\\tx\\ty\\n' > "$jar"
        """)
        defer { empty.tools.cleanUp() }
        #expect(await SignIn.capture(browser: .safari, to: empty.destination, tools: empty.tools.registry) == Messages.signInNotFound)
        #expect(!FileManager.default.fileExists(atPath: empty.destination.path))
    }

    @Test func aBrowserThatIsNotOfferedOrAMissingToolIsRefusedBeforeAnythingRuns() async throws {
        let s = try setUp("signin-refuse", "echo ran >> \"$HERE/calls.log\"")
        defer { s.tools.cleanUp() }
        #expect(await SignIn.capture(browser: .none, to: s.destination, tools: s.tools.registry) == Messages.signInChooseBrowser)
        #expect(await SignIn.capture(browser: .opera, to: s.destination, tools: s.tools.registry) == Messages.signInChooseBrowser)
        #expect(s.tools.text("calls.log").isEmpty)
        let none = try StandIns("signin-notool")
        defer { none.cleanUp() }
        #expect(await SignIn.capture(browser: .firefox, to: s.destination, tools: none.registry) == Messages.noTool)
    }

    @Test func theSignInIsUsedOnlyWhenSwitchedOnAndSaved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("signin-use-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        try paths.createFolders()
        var settings = AppSettings()
        #expect(SignIn.file(for: settings, paths: paths) == nil && SignIn.savedDate(paths: paths) == nil)
        settings.useSignIn = true
        #expect(SignIn.file(for: settings, paths: paths) == nil)
        try Data("# Netscape HTTP Cookie File\n".utf8).write(to: paths.signInFile)
        #expect(SignIn.file(for: settings, paths: paths) == paths.signInFile.path)
        #expect(SignIn.savedDate(paths: paths) != nil)
        #expect(settings.queueSettings(cookiesFile: SignIn.file(for: settings, paths: paths)).cookiesFile == paths.signInFile.path)
        settings.useSignIn = false
        #expect(SignIn.file(for: settings, paths: paths) == nil)
    }
}

@Suite struct PhaseNineSettingsTests {
    @Test func theNewSettingsHaveSafeDefaultsAndRoundTrip() throws {
        var settings = AppSettings()
        #expect(!settings.spokenSearch && settings.transcribeLocally && !settings.useSignIn && !settings.tourSeen && settings.signInBrowser == .firefox)
        settings.spokenSearch = true
        settings.transcribeLocally = false
        settings.useSignIn = true
        settings.signInBrowser = .safari
        settings.tourSeen = true
        #expect(SettingsStore.decode(try SettingsStore.encode(settings)) == settings)
        // A file from before these existed, and one naming a browser that is not offered.
        let old = Data("{\"version\":1,\"settings\":{\"maxConcurrent\":3,\"signInBrowser\":\"opera\"}}".utf8)
        let read = try #require(SettingsStore.decode(old))
        #expect(read.maxConcurrent == 3 && !read.spokenSearch && read.transcribeLocally && read.signInBrowser == .firefox && !read.tourSeen)
    }

    @Test func phobossSpokenSearchComesOverButNotItsSignInOrItsTour() throws {
        let phobos = Data("{\"spokenSearch\":true,\"transcribeLocally\":false,\"useSignIn\":true,\"signInBrowser\":\"chrome\",\"tourSeen\":true}".utf8)
        let settings = try #require(PhobosImporter.settings(fromPreferences: phobos))
        #expect(settings.spokenSearch && !settings.transcribeLocally && settings.signInBrowser == .chrome)
        #expect(!settings.useSignIn && !settings.tourSeen)
    }
}
