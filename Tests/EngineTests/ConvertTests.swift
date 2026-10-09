import Foundation
import Testing
@testable import Engine

/// Scripts standing in for the tools, in a scratch folder. A registry made
/// here finds only these, never the Mac's real tools.
struct StandIns {
    let root: URL

    init(_ name: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func tool(_ tool: Tool, _ body: String) throws -> String {
        let folder = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(tool.executableName)
        try Data(("#!/bin/sh\nHERE=\"\(root.path)\"\n" + body + "\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file.path
    }

    var registry: ToolRegistry {
        let prefix = root.path
        return ToolRegistry(managedFolder: root.appendingPathComponent("bin").path, isExecutable: { path in
            path.hasPrefix(prefix) && FileManager.default.isExecutableFile(atPath: path)
        })
    }

    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) }
    func touch(_ name: String) { FileManager.default.createFile(atPath: root.appendingPathComponent(name).path, contents: Data()) }
    func remove(_ name: String) { try? FileManager.default.removeItem(at: root.appendingPathComponent(name)) }
    func text(_ name: String) -> String { (try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)) ?? "" }

    func file(_ name: String, bytes: Int) throws -> String {
        let url = root.appendingPathComponent(name)
        try Data(repeating: 1, count: bytes).write(to: url)
        return url.path
    }
}

private let movie = FileFacts(duration: 600, bitRate: 4_000_000, videoCodec: "vp9", audioCodec: "opus", width: 1920, height: 1080, size: 300_000_000)
private let song = FileFacts(duration: 200, bitRate: 128_000, audioCodec: "opus", size: 3_000_000)
private let nothingThere: (String) -> Bool = { _ in false }

@Suite struct ConvertDraftTests {
    @Test func aVideoOffersAllFourJobsAndStartsOnPlayEverywhere() {
        let draft = ConvertDraft(input: "/m/Talk.webm", facts: movie)
        #expect(ConvertChoice.allCases.allSatisfy(draft.available))
        #expect(draft.choice == .mp4)
        #expect(draft.clipStart == 0 && draft.clipEnd == 600)
        #expect(draft.plan(exists: nothingThere)?.output == "/m/Talk (MP4).mp4")
        #expect(draft.blocker(exists: nothingThere) == nil)
    }

    @Test func aFileWithNoPictureCannotBeShrunkOrMadeAnMP4() {
        var draft = ConvertDraft(input: "/m/Song.opus", facts: song)
        #expect(draft.choice == .clip)
        #expect(!draft.available(.mp4) && !draft.available(.shrink) && draft.available(.audio) && draft.available(.clip))
        draft.choice = .shrink
        #expect(draft.plan(exists: nothingThere) == nil)
        #expect(draft.blocker(exists: nothingThere) == Messages.convertNoPicture)
        draft.choice = .mp4
        #expect(draft.blocker(exists: nothingThere) == Messages.convertNoPicture)
    }

    @Test func eachJobThatCannotBeDoneSaysWhy() {
        var silent = ConvertDraft(input: "/m/Silent.mp4", facts: FileFacts(duration: 60, bitRate: 2_000_000, videoCodec: "h264", size: 15_000_000))
        silent.choice = .audio
        #expect(!silent.available(.audio))
        #expect(silent.blocker(exists: nothingThere) == Messages.convertNoSound)

        var tiny = ConvertDraft(input: "/m/Tiny.mp4", facts: FileFacts(duration: 600, bitRate: 90_000, videoCodec: "h264", audioCodec: "aac", size: 6_750_000))
        tiny.choice = .shrink
        #expect(tiny.blocker(exists: nothingThere) == Messages.convertAlreadySmall)
        #expect(tiny.estimate(for: .medium) == Messages.convertNoSaving)

        var clip = ConvertDraft(input: "/m/Talk.webm", facts: movie)
        clip.choice = .clip
        clip.clipStart = 50
        clip.clipEnd = 50
        #expect(clip.blocker(exists: nothingThere) == Messages.convertClipTimes)
        let instant = ConvertDraft(input: "/m/Blip.mp4", facts: FileFacts(duration: 0.5, videoCodec: "h264", size: 1000))
        #expect(!instant.available(.clip))
    }

    @Test func theCopyIsNamedAfterWhatWasAskedFor() {
        var draft = ConvertDraft(input: "/m/Talk.webm", facts: movie)
        #expect(draft.label == "MP4 copy")
        draft.choice = .shrink
        draft.level = .small
        #expect(draft.label == "Small copy")
        #expect(draft.plan(exists: nothingThere)?.output == "/m/Talk (small).mp4")
        draft.choice = .audio
        #expect(draft.label == "Audio only")
        draft.choice = .clip
        draft.clipStart = 65
        draft.clipEnd = 125
        #expect(draft.label == "Clip 1:05 to 2:05")
        #expect(draft.kind == .clip(start: 65, end: 125))
    }

    @Test func aTakenNameGetsANumberAndTheOriginalIsNeverTheOutput() {
        let draft = ConvertDraft(input: "/m/Talk.mp4", facts: FileFacts(duration: 60, bitRate: 2_000_000, videoCodec: "h264", audioCodec: "aac", size: 15_000_000))
        let plan = draft.plan(exists: { $0 == "/m/Talk (MP4).mp4" })
        #expect(plan?.output == "/m/Talk (MP4) (2).mp4")
        #expect(plan?.output != draft.input)
    }

    @Test func theThreeSizesAreReallyDifferentAndTheLinesReadWell() {
        let draft = ConvertDraft(input: "/Users/me/Movies/YouTube/Talk.webm", facts: movie)
        let sizes = ShrinkLevel.allCases.map(draft.estimate)
        #expect(Set(sizes).count == 3 && !sizes.contains(Messages.convertNoSaving))
        #expect(ShrinkLevel.allCases.map(\.label) == ["Close to original", "Medium", "Small"])
        #expect(draft.factsLine(home: "/Users/me") == "1080p · 10:00 · 300 MB · Movies › YouTube")
        #expect(ConvertDraft(input: "/Users/me/Music/Song.opus", facts: song).factsLine(home: "/Users/me") == "Audio · 3:20 · 3 MB · Music")
        // A length is said in whole seconds.
        var odd = song
        odd.duration = 6.008
        #expect(ConvertDraft(input: "/Users/me/Music/Song.opus", facts: odd).factsLine(home: "/Users/me").contains(" · 0:06 · "))
        let plan = draft.plan(exists: nothingThere)!
        #expect(draft.summary(for: plan).hasPrefix("Saves as Talk (MP4).mp4 beside the original, about "))
        #expect(draft.summary(for: plan).hasSuffix("The original is never changed."))
        #expect(Set(ConvertChoice.allCases.map(\.title)).count == 4 && ConvertChoice.allCases.allSatisfy { !$0.explanation.isEmpty })
    }

    @Test func onBatteryOnlyRealConvertingIsAskedAbout() {
        let reencode = ConvertDraft(input: "/m/Talk.webm", facts: movie).plan(exists: nothingThere)!
        let repackage = ConvertDraft(input: "/m/Talk.mkv", facts: FileFacts(duration: 60, bitRate: 2_000_000, videoCodec: "h264", audioCodec: "aac", size: 15_000_000))
            .plan(exists: nothingThere)!
        #expect(!reencode.copiesOnly && repackage.copiesOnly)
        #expect(ConvertDraft.asksOnBattery(reencode, onBattery: true))
        #expect(!ConvertDraft.asksOnBattery(reencode, onBattery: false))
        #expect(!ConvertDraft.asksOnBattery(repackage, onBattery: true))
    }
}

@Suite struct PhoneSendTests {
    @Test func aFileThePhonePlaysIsSentAsItIs() {
        let ready = FileFacts(duration: 60, videoCodec: "h264", audioCodec: "aac", size: 1_000_000)
        #expect(PhoneSend.decide(path: "/m/a.mp4", facts: ready, exists: nothingThere) == .ready)
        #expect(PhoneSend.decide(path: "/m/a.m4a", facts: FileFacts(duration: 60, audioCodec: "aac"), exists: nothingThere) == .ready)
    }

    @Test func anyOtherFileGetsACopyBesideTheOriginal() {
        guard case .needsCopy(let video) = PhoneSend.decide(path: "/m/a.webm", facts: movie, exists: nothingThere) else {
            Issue.record("a WebM needs a copy")
            return
        }
        #expect(video.output == "/m/a (MP4).mp4" && !video.copiesOnly)
        guard case .needsCopy(let repackaged) = PhoneSend.decide(path: "/m/a.mkv", facts: FileFacts(duration: 60, videoCodec: "h264", audioCodec: "aac", size: 9),
                                                                 exists: nothingThere) else {
            Issue.record("an MKV needs a copy")
            return
        }
        #expect(repackaged.copiesOnly)
        guard case .needsCopy(let audio) = PhoneSend.decide(path: "/m/a.opus", facts: song, exists: nothingThere) else {
            Issue.record("an Opus song needs a copy")
            return
        }
        #expect(audio.output == "/m/a (audio).m4a")
    }

    @Test func aFileWithNothingInItCannotBeSent() {
        #expect(PhoneSend.decide(path: "/m/a.bin", facts: FileFacts(), exists: nothingThere) == .impossible)
    }
}

/// A converter that writes its last argument, unless a file in the scratch folder tells it to behave otherwise.
private let converter = """
for last; do :; done
echo "$@" >> "$HERE/calls.log"
case "$*" in *h264_videotoolbox*) if [ -f "$HERE/hardware-refuses" ]; then echo "hardware said no" >&2; exit 1; fi;; esac
if [ -f "$HERE/fails" ]; then printf 'half' > "$last"; echo "Invalid data found when processing input" >&2; exit 1; fi
if [ -f "$HERE/hangs" ]; then printf 'half' > "$last"; exec sleep 30; fi
echo "out_time_us=300000000"
if [ -f "$HERE/big" ]; then head -c 5000 /dev/zero > "$last"; else printf 'converted' > "$last"; fi
"""

@Suite struct ConvertCenterTests {
    private func setUp(_ name: String) throws -> (tools: StandIns, library: LibraryFixture, center: ConvertCenter, input: String) {
        let tools = try StandIns(name)
        try tools.tool(.ffmpeg, converter)
        let library = try LibraryFixture(name)
        let registry = tools.registry
        let center = ConvertCenter(tools: { registry }, library: library.library, runner: ProcessRunner(stopGrace: 0.2))
        let input = try library.file("Talk.webm", size: 2000)
        return (tools, library, center, input)
    }

    private func plan(_ input: String, _ kind: ConvertKind = .playEverywhere) -> FFmpegPlanner.Plan {
        FFmpegPlanner.convert(kind, input: input, facts: movie)!
    }

    @Test func aConversionMakesANewFileBesideTheOriginalAndRecordsItAsACopy() async throws {
        let s = try setUp("convert-ok")
        defer { s.tools.cleanUp(); s.library.cleanUp() }
        var original = try s.library.record("Talk", file: "Talk.webm", size: 2000)
        original.videoID = "abc"
        await s.library.library.add(original)
        let plan = plan(s.input)
        let id = await s.center.start(plan, input: s.input, label: "MP4 copy")
        #expect(await s.center.result(of: id) == plan.output)
        let item = try #require(await s.center.snapshot().first)
        #expect(item.state == .done && item.progress == 1 && item.title == "Talk.webm" && item.detail == "MP4 copy" && item.announce)
        #expect(item.status == Messages.convertSaved("Talk (MP4).mp4", in: Naming.breadcrumb(s.library.media.path)))
        #expect(FileManager.default.contents(atPath: plan.output) == Data("converted".utf8))
        #expect(FileInspector.size(of: s.input) == 2000)
        let copy = try #require(await s.library.library.record(atPath: plan.output))
        #expect(copy.isCopy && copy.choice == "MP4 copy" && copy.videoID == "abc" && copy.title == "Talk (MP4)")
        #expect(!(await s.center.hasRunning))
    }

    @Test func whenTheFirstEncoderRefusesTheOtherOneTakesOver() async throws {
        let s = try setUp("convert-fallback")
        defer { s.tools.cleanUp(); s.library.cleanUp() }
        s.tools.touch("hardware-refuses")
        let plan = plan(s.input)
        #expect(plan.fallback != nil)
        let id = await s.center.start(plan, input: s.input, label: "MP4 copy")
        #expect(await s.center.result(of: id) == plan.output)
        let calls = s.tools.text("calls.log").split(separator: "\n")
        #expect(calls.count == 2 && calls[0].contains("h264_videotoolbox") && calls[1].contains("libx264"))
    }

    @Test func aFailedConversionLeavesNoHalfFileAndTheOriginalAlone() async throws {
        let s = try setUp("convert-fail")
        defer { s.tools.cleanUp(); s.library.cleanUp() }
        s.tools.touch("fails")
        let plan = plan(s.input)
        let id = await s.center.start(plan, input: s.input, label: "MP4 copy")
        #expect(await s.center.result(of: id) == nil)
        let item = try #require(await s.center.snapshot().first)
        #expect(item.state == .failed && item.status == Messages.convertFailed)
        #expect(item.toolSays == "Invalid data found when processing input")
        #expect(!FileManager.default.fileExists(atPath: plan.output))
        #expect(FileInspector.size(of: s.input) == 2000)
        #expect(await s.library.library.record(atPath: plan.output) == nil)
    }

    @Test func cancellingStopsTheConverterAndRemovesOnlyTheNewFile() async throws {
        let s = try setUp("convert-cancel")
        defer { s.tools.cleanUp(); s.library.cleanUp() }
        s.tools.touch("hangs")
        let plan = plan(s.input)
        let id = await s.center.start(plan, input: s.input, label: "MP4 copy")
        #expect(await eventually { FileManager.default.fileExists(atPath: plan.output) })
        #expect(await s.center.hasRunning)
        await s.center.cancel(id)
        #expect(await s.center.snapshot().first?.state == .cancelled)
        await s.center.idle()
        #expect(await s.center.result(of: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: plan.output))
        #expect(FileInspector.size(of: s.input) == 2000)
        // Only one attempt: a cancelled conversion is not tried on the other encoder.
        #expect(s.tools.text("calls.log").split(separator: "\n").count == 1)
        await s.center.clearFinished()
        #expect(await s.center.snapshot().isEmpty)
    }

    @Test func aShrunkCopyThatCameOutNoSmallerIsRemoved() async throws {
        let s = try setUp("convert-nosmaller")
        defer { s.tools.cleanUp(); s.library.cleanUp() }
        s.tools.touch("big")
        let plan = plan(s.input, .shrink(.medium))
        let id = await s.center.start(plan, input: s.input, label: "Medium copy", mustBeSmaller: true)
        #expect(await s.center.result(of: id) == nil)
        #expect(await s.center.snapshot().first?.status == Messages.convertNoSmaller)
        #expect(!FileManager.default.fileExists(atPath: plan.output))
        // The same result is kept when a smaller file was not what was asked for.
        let other = await s.center.start(self.plan(s.input), input: s.input, label: "MP4 copy")
        #expect(await s.center.result(of: other) != nil)
    }

    @Test func aFileThatTookTheNameIsNeverWrittenOver() async throws {
        let s = try setUp("convert-taken")
        defer { s.tools.cleanUp(); s.library.cleanUp() }
        let plan = plan(s.input)
        try Data("someone else's".utf8).write(to: URL(fileURLWithPath: plan.output))
        let id = await s.center.start(plan, input: s.input, label: "MP4 copy")
        #expect(await s.center.result(of: id) == nil)
        #expect(await s.center.snapshot().first?.status == Messages.convertNameTaken)
        #expect(FileManager.default.contents(atPath: plan.output) == Data("someone else's".utf8))
        #expect(s.tools.text("calls.log").isEmpty)
    }

    @Test func withoutAConverterItSaysSoAndTheListIsPublished() async throws {
        let tools = try StandIns("convert-none")
        defer { tools.cleanUp() }
        let registry = tools.registry
        let center = ConvertCenter(tools: { registry })
        let input = try tools.file("a.webm", bytes: 10)
        var seen: [[Conversion.State]] = []
        let stream = await center.updates()
        let id = await center.start(plan(input), input: input, label: "MP4 copy", announce: false)
        _ = await center.result(of: id)
        for await list in stream {
            seen.append(list.map(\.state))
            if list.first?.state == .failed { break }
        }
        #expect(seen.first == [] && seen.last == [.failed])
        let item = try #require(await center.snapshot().first)
        #expect(item.status == Messages.noConverter && !item.announce)
    }

    @Test func aFilesFactsAreReadWithTheInspector() async throws {
        let tools = try StandIns("inspect")
        defer { tools.cleanUp() }
        let input = try tools.file("a.mp4", bytes: 1234)
        #expect(await FileInspector.inspect(input, tools: tools.registry) == nil)
        try tools.tool(.ffprobe, """
        echo '{"format":{"duration":"12.5","bit_rate":"800000"},"streams":[{"codec_type":"video","codec_name":"h264","width":640,"height":360},{"codec_type":"audio","codec_name":"aac","sample_rate":"44100"}]}'
        """)
        let facts = try #require(await FileInspector.inspect(input, tools: tools.registry))
        #expect(facts.videoCodec == "h264" && facts.audioCodec == "aac" && facts.duration == 12.5 && facts.size == 1234)
        try tools.tool(.ffprobe, "echo '{\"format\":{},\"streams\":[]}'")
        #expect(await FileInspector.inspect(input, tools: tools.registry) == nil)
        try tools.tool(.ffprobe, "echo 'not a media file' >&2; exit 1")
        #expect(await FileInspector.inspect(input, tools: tools.registry) == nil)
    }
}
