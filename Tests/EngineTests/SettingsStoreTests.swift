import Foundation
import Testing
@testable import Engine

private func scratch() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

@Suite struct SettingsStoreTests {
    @Test func theDefaultsArePhoboss() {
        let settings = AppSettings()
        #expect(settings.folders == FolderRules.standard())
        #expect(settings.nameStyle == .title)
        #expect(settings.maxConcurrent == 2)
        #expect(settings.autoRetry)
        #expect(settings.speedLimitKB == 0)
        #expect(settings.finish == .notifyAndOffer)
        #expect(!settings.subtitles && !settings.coverImage && !settings.cutSponsors)
        #expect(settings.exactCut)
        #expect(settings.theme == .system && settings.accent == .ember && !settings.largeText)
        #expect(settings.toolOverrides.isEmpty)
    }

    @Test func settingsComeBackAsTheyWereSaved() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SettingsStore(paths: AppPaths(root: root.appendingPathComponent("support")))
        #expect(store.load() == AppSettings())

        var settings = AppSettings()
        settings.folders.mainFolder = "/Volumes/Big/Video"
        settings.folders.perSite["Vimeo"] = "/Volumes/Big/Vimeo"
        settings.nameStyle = .dateTitle
        settings.maxConcurrent = 4
        settings.autoRetry = false
        settings.speedLimitKB = 2048
        settings.finish = .playNow
        settings.subtitles = true
        settings.evenLoudness = true
        settings.theme = .system
        settings.accent = .teal
        settings.largeText = true
        settings.lastChoiceID = "res1080"
        settings.remember(site: "Vimeo")
        settings.setOverride("/opt/tools/ffmpeg", for: .ffmpeg)
        try store.save(settings)
        #expect(store.load() == settings)

        let text = try String(contentsOf: store.file, encoding: .utf8)
        #expect(text.contains("\"version\" : 1"))
    }

    @Test func aFileFromAnotherVersionKeepsWhatStillFits() throws {
        let saved = """
        {"version": 7, "settings": {"maxConcurrent": 3, "theme": "sepia", "nameStyle": "dateTitle",
         "somethingNew": true, "folders": 12, "knownSites": ["Vimeo"]}}
        """
        let settings = try #require(SettingsStore.decode(Data(saved.utf8)))
        #expect(settings.maxConcurrent == 3)
        #expect(settings.nameStyle == .dateTitle)
        #expect(settings.knownSites == ["Vimeo"])
        // A value that no longer makes sense takes its default; the rest is kept.
        #expect(settings.theme == .dark)
        // Folders it does not name are the ones an install from before HeatBox used.
        #expect(settings.folders == FolderRules.legacy())
        #expect(settings.accent == .blue)
    }

    @Test func onlyANewInstallGetsTheNewAudioFolder() throws {
        #expect(FolderRules.standard(home: "/Users/sam").audioFolder == "/Users/sam/Music/HeatBox")
        #expect(FolderRules.legacy(home: "/Users/sam").audioFolder == "/Users/sam/Music/Studio x Phobos")
        #expect(FolderRules.legacy(home: "/Users/sam").mainFolder == FolderRules.standard(home: "/Users/sam").mainFolder)

        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let store = SettingsStore(paths: paths)
        // Nothing here yet: a new install.
        #expect(store.load().folders == FolderRules.standard())
        #expect(store.load().accent == .ember)
        #expect(store.load().theme == .system)
        // It keeps that once it has other files, because its settings are saved.
        store.keep(store.load())
        try Data().write(to: paths.libraryDatabase)
        #expect(store.load().folders == FolderRules.standard())
        // Keeping never writes over what is saved.
        var chosen = AppSettings()
        chosen.folders.audioFolder = "/Volumes/Big/Audio"
        try store.save(chosen)
        store.keep(AppSettings())
        #expect(store.load().folders.audioFolder == "/Volumes/Big/Audio")

        // An install from before the name changed that never saved settings keeps its folder.
        try FileManager.default.removeItem(at: store.file)
        #expect(store.load().folders == FolderRules.legacy())
        #expect(store.load().accent == .blue)
        #expect(store.load().theme == .dark)
        // So does one whose saved settings name the old folder, or cannot be read.
        var old = AppSettings()
        old.folders = .legacy()
        try store.save(old)
        #expect(store.load().folders == FolderRules.legacy())
        try Data("not settings".utf8).write(to: store.file)
        #expect(store.load().folders == FolderRules.legacy())
    }

    @Test func aFileThatIsNotSettingsIsSetAsideNotWrittenOver() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SettingsStore(file: root.appendingPathComponent("settings.json"))
        try Data("not json at all".utf8).write(to: store.file)
        // The defaults, with the folders of an install that was already here.
        var expected = AppSettings()
        expected.folders = .legacy()
        expected.accent = .blue
        expected.theme = .dark
        #expect(store.load() == expected)
        #expect(!FileManager.default.fileExists(atPath: store.file.path))
        #expect(store.load() == expected)
        let aside = root.appendingPathComponent("settings.unreadable.json")
        #expect(try String(contentsOf: aside, encoding: .utf8) == "not json at all")
    }

    @Test func theQueueIsGivenTheDefaults() {
        var settings = AppSettings()
        settings.maxConcurrent = 9
        settings.speedLimitKB = -5
        settings.autoRetry = false
        settings.nameStyle = .uploaderTitle
        settings.folders.mainFolder = "/tmp/video"
        let queue = settings.queueSettings(cookiesFile: "/tmp/cookies.txt")
        #expect(queue.maxConcurrent == 4)
        #expect(queue.speedLimitKB == 0)
        #expect(!queue.autoRetry)
        #expect(queue.nameStyle == .uploaderTitle)
        #expect(queue.folders.mainFolder == "/tmp/video")
        #expect(queue.cookiesFile == "/tmp/cookies.txt")
        settings.maxConcurrent = 0
        #expect(settings.queueSettings().maxConcurrent == 1)
        #expect(settings.queueSettings().cookiesFile == nil)
    }

    @Test func aChosenToolPathReachesTheRegistry() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = root.appendingPathComponent("yt-dlp")
        try Data("#!/usr/bin/true\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        var settings = AppSettings()
        settings.setOverride("  \(tool.path) ", for: .ytdlp)
        let paths = AppPaths(root: root.appendingPathComponent("support"))
        let registry = settings.registry(paths: paths)
        #expect(registry.managedFolder == paths.bin.path)
        #expect(registry.locate(.ytdlp) == ToolLocation(path: tool.path, source: .userOverride))

        settings.setOverride("", for: .ytdlp)
        #expect(settings.toolPaths.isEmpty)
        #expect(settings.registry(paths: paths).locate(.ytdlp)?.source != .userOverride)
    }

    @Test func sitesAreRememberedOnceAndInOrder() {
        var settings = AppSettings()
        let added = [settings.remember(site: "YouTube"), settings.remember(site: "bandcamp"),
                     settings.remember(site: "YouTube"), settings.remember(site: "  ")]
        #expect(added == [true, true, false, false])
        #expect(settings.knownSites == ["bandcamp", "YouTube"])
    }
}
