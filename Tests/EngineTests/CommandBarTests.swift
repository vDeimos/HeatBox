import Foundation
import Testing
@testable import Engine

private func entry(_ title: String, detail: String = "", keywords: [String] = []) -> CommandEntry {
    CommandEntry(id: title, title: title, detail: detail, group: "Action", keywords: keywords)
}

@Suite struct CommandSearchTests {
    private let commands = [
        entry("Library", detail: "Go to Library", keywords: ["go", "videos"]),
        entry("Settings", keywords: ["preferences", "folders"]),
        entry("Pause All"),
        entry("Check Channels"),
        entry("Sample café video", detail: "YouTube · Some Channel"),
    ]

    private func top(_ query: String) -> String? { CommandSearch.rank(commands, query: query).first?.title }

    @Test func whatIsTypedFindsTheRightCommand() {
        #expect(top("lib") == "Library")
        #expect(top("PAUSE") == "Pause All")
        #expect(top("pause a") == "Pause All")
        #expect(top("preferences") == "Settings")
        #expect(top("chn") == "Check Channels")
        #expect(top("cafe") == "Sample café video")
        #expect(top("some channel") == "Sample café video")
        #expect(top("all pause") == "Pause All")
        #expect(CommandSearch.rank(commands, query: "zzzq").isEmpty)
    }

    @Test func orderIsByHowWellItMatchesThenAsGiven() {
        #expect(CommandSearch.rank(commands, query: "").map(\.title) == commands.map(\.title))
        #expect(CommandSearch.rank([entry("Other", keywords: ["settings"]), entry("Settings")], query: "settings").first?.title == "Settings")
        #expect(CommandSearch.rank([entry("Alpha one"), entry("Alpha two")], query: "alpha").map(\.title) == ["Alpha one", "Alpha two"])
        #expect(CommandSearch.score(entry("Queue"), query: "queue") == 1000)
        #expect(CommandSearch.score(entry("Queue"), query: "x") == nil)
    }
}

@Suite struct CommandBarTests {
    private let screens: [CommandBar.ScreenEntry] = [("download", "Download", "arrow.down.to.line"), ("queue", "Queue", "list.bullet"),
                                                     ("library", "Library", "square.grid.2x2"), ("following", "Following", "person"),
                                                     ("convert", "Convert", "arrow.left.arrow.right")]

    private func record(_ title: String, missing: Bool = false) -> LibraryRecord {
        LibraryRecord(title: title, uploader: "Some Channel", site: "YouTube", path: "/m/\(title).mp4", added: Date(timeIntervalSince1970: 0), missing: missing)
    }

    @Test func theFixedCommandsAreTheScreensSettingsAndWhatMakesSenseNow() {
        let idle = CommandBar.fixed(screens: screens, situation: .init())
        #expect(idle.prefix(5).map(\.id) == ["go.download", "go.queue", "go.library", "go.following", "go.convert"])
        #expect(idle.map(\.id).contains(CommandBar.settingsID) && idle.map(\.id).contains(CommandBar.tourID))
        #expect(!idle.map(\.id).contains(CommandBar.pauseAllID) && !idle.map(\.id).contains(CommandBar.resumeAllID))
        let busy = CommandBar.fixed(screens: screens, situation: .init(hasBusy: true, hasPaused: true))
        #expect(busy.map(\.id).contains(CommandBar.pauseAllID) && busy.map(\.id).contains(CommandBar.resumeAllID))
        // Every command has its own id and words to show.
        #expect(Set(busy.map(\.id)).count == busy.count)
        #expect(busy.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty && !$0.group.isEmpty && !$0.symbol.isEmpty })
        // Other words find them.
        #expect(CommandSearch.rank(idle, query: "shrink").first?.id == "go.convert")
        #expect(CommandSearch.rank(idle, query: "preferences").first?.id == CommandBar.settingsID)
        #expect(CommandSearch.rank(idle, query: "help").first?.id == CommandBar.tourID)
    }

    @Test func nothingTypedListsTheCommandsAndNoVideos() {
        let fixed = CommandBar.fixed(screens: screens, situation: .init())
        let shown = CommandBar.results(query: "  ", fixed: fixed, records: [record("A talk")], spokenSearch: true)
        #expect(shown == fixed)
    }

    @Test func aPastedLinkIsOfferedFirstAndOnlyFillsInTheDownloadScreen() {
        let fixed = CommandBar.fixed(screens: screens, situation: .init())
        let one = CommandBar.results(query: "https://example.com/watch?v=1", fixed: fixed, records: [], spokenSearch: true)
        #expect(one.first?.id == CommandBar.linkID && one.first?.title == "Look up this link" && one.first?.detail == "https://example.com/watch?v=1")
        // A link is not searched for among spoken words.
        #expect(!one.map(\.id).contains(CommandBar.spokenID))
        let two = CommandBar.results(query: "https://example.com/a https://example.com/b", fixed: fixed, records: [], spokenSearch: false)
        #expect(two.first?.title == "Look up 2 links")
    }

    @Test func libraryVideosThatCanBePlayedAreOfferedButNeverMoreThanSix() {
        let fixed = CommandBar.fixed(screens: screens, situation: .init())
        let records = (1...9).map { record("Lecture \($0)") } + [record("Lecture lost", missing: true)]
        let shown = CommandBar.results(query: "lecture", fixed: fixed, records: records, spokenSearch: false)
        let videos = shown.filter { $0.id.hasPrefix(CommandBar.videoPrefix) }
        #expect(videos.count == CommandBar.videoLimit)
        #expect(videos.map(\.title) == (1...6).map { "Lecture \($0)" })
        #expect(videos.allSatisfy { $0.detail == "YouTube · Some Channel" && $0.group == Messages.commandGroupPlay })
        #expect(videos.first?.id == CommandBar.videoID(records[0]))
        // A screen whose name matches still comes before a video that only contains the word.
        let mixed = CommandBar.results(query: "library", fixed: fixed, records: [record("My library tour")], spokenSearch: false)
        #expect(mixed.first?.id == "go.library" && mixed.contains { $0.title == "My library tour" })
    }

    @Test func spokenWordsAreOfferedOnlyWhenSwitchedOnAndThreeLettersLong() {
        let fixed = CommandBar.fixed(screens: screens, situation: .init())
        #expect(CommandBar.results(query: "gardening", fixed: fixed, records: [], spokenSearch: true).last?.id == CommandBar.spokenID)
        #expect(CommandBar.results(query: "gardening", fixed: fixed, records: [], spokenSearch: true).last?.title == "Find \u{201C}gardening\u{201D} in words spoken")
        #expect(!CommandBar.results(query: "gardening", fixed: fixed, records: [], spokenSearch: false).map(\.id).contains(CommandBar.spokenID))
        #expect(!CommandBar.results(query: "ga", fixed: fixed, records: [], spokenSearch: true).map(\.id).contains(CommandBar.spokenID))
        // Something nobody has: only the spoken search is left, or nothing at all.
        #expect(CommandBar.results(query: "zzzq", fixed: fixed, records: [], spokenSearch: true).map(\.id) == [CommandBar.spokenID])
        #expect(CommandBar.results(query: "zzzq", fixed: fixed, records: [], spokenSearch: false).isEmpty)
    }
}
