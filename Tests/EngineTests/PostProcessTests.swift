import Foundation
import Testing
@testable import Engine

private func scratch(_ name: String) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.resolvingSymlinksInPath()
}

/// A Trash that is a folder, and one that refuses.
struct FolderTrash: Trash {
    let folder: URL
    @discardableResult
    func trash(_ file: URL) throws -> URL? {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(file.lastPathComponent)
        try FileManager.default.moveItem(at: file, to: target)
        return target
    }
}

struct NoTrash: Trash {
    func trash(_ file: URL) throws -> URL? { throw CocoaError(.fileWriteNoPermission) }
}

@Suite struct PostProcessTests {
    @Test func aPlainDownloadHasNoSteps() {
        #expect(PostProcess.steps(for: DownloadRecipe(), file: "/w/files/a.mp4", trackCount: 0).isEmpty)
        #expect(PostProcess.steps(for: PresetCatalog.audioOnly.recipe, file: "/w/files/a.m4a", trackCount: 0).isEmpty)
    }

    @Test func theStepsFollowTheRecipeInTheirFixedOrder() {
        var audio = PresetCatalog.audioOnly.recipe
        audio.evenLoudness = true
        #expect(PostProcess.steps(for: audio, file: "/w/files/a.m4a", trackCount: 0) == [.loudness])
        audio.splitChapters = true
        #expect(PostProcess.steps(for: audio, file: "/w/files/a.m4a", trackCount: 3) == [.retag, .loudness])
        // Nothing to tag when the video had no chapters to split.
        #expect(PostProcess.steps(for: audio, file: "/w/files/a.m4a", trackCount: 0) == [.loudness])
        audio.tagChapterTracks = false
        #expect(PostProcess.steps(for: audio, file: "/w/files/a.m4a", trackCount: 3) == [.loudness])
        // A kind of audio file the step cannot write back is left alone.
        #expect(PostProcess.steps(for: audio, file: "/w/files/a.webm", trackCount: 0).isEmpty)
    }

    @Test func evenVolumeIsForAudioAndReencodingIsForVideo() {
        var video = DownloadRecipe()
        video.evenLoudness = true
        #expect(PostProcess.steps(for: video, file: "/w/files/a.mp4", trackCount: 0).isEmpty)
        video.encodeEnabled = true
        video.container = .mp4
        #expect(PostProcess.steps(for: video, file: "/w/files/a.webm", trackCount: 0) == [.encode])
        #expect(PostProcess.steps(for: video, file: "/w/files/a.jpg", trackCount: 0).isEmpty)
        video.mode = .audio
        #expect(PostProcess.steps(for: video, file: "/w/files/a.mp4", trackCount: 0).isEmpty)
    }
}

@Suite struct SafeReplaceTests {
    @Test func theResultTakesTheOriginalsPlaceAndTheOriginalGoesToTheTrash() throws {
        let root = try scratch("replace")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("files/Film [id].webm")
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("original".utf8).write(to: original)
        let result = root.appendingPathComponent("new.mp4")
        try Data("encoded".utf8).write(to: result)
        let trash = FolderTrash(folder: root.appendingPathComponent("Trash"))

        let final = try SafeReplace.replace(original: original.path, with: result.path, trash: trash)
        #expect(final == root.appendingPathComponent("files/Film [id].mp4").path)
        #expect(try String(contentsOfFile: final, encoding: .utf8) == "encoded")
        #expect(try String(contentsOf: trash.folder.appendingPathComponent("Film [id].webm"), encoding: .utf8) == "original")
        #expect(try FileManager.default.contentsOfDirectory(atPath: original.deletingLastPathComponent().path) == ["Film [id].mp4"])
        #expect(!FileManager.default.fileExists(atPath: result.path))
    }

    @Test func theSameEndingWorksToo() throws {
        let root = try scratch("replace-same")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("Film.mp4")
        try Data("original".utf8).write(to: original)
        let result = root.appendingPathComponent("scratch.mp4")
        try Data("encoded".utf8).write(to: result)
        let final = try SafeReplace.replace(original: original.path, with: result.path, trash: FolderTrash(folder: root.appendingPathComponent("Trash")))
        #expect(final == original.path)
        #expect(try String(contentsOf: original, encoding: .utf8) == "encoded")
    }

    @Test func anOriginalThatCannotBeTrashedIsLeftUntouchedAndTheResultIsKeptBesideIt() throws {
        let root = try scratch("replace-kept")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("Film.webm")
        try Data("original".utf8).write(to: original)
        let result = root.appendingPathComponent("scratch.mp4")
        try Data("encoded".utf8).write(to: result)
        let beside = root.appendingPathComponent("Film.encoded.mp4").path
        #expect(throws: SafeReplace.Failure.originalKept(result: beside)) {
            try SafeReplace.replace(original: original.path, with: result.path, trash: NoTrash())
        }
        #expect(try String(contentsOf: original, encoding: .utf8) == "original")
        #expect(try String(contentsOfFile: beside, encoding: .utf8) == "encoded")
    }

    @Test func nothingIsTouchedWithoutAFinishedResult() throws {
        let root = try scratch("replace-none")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("Film.webm")
        try Data("original".utf8).write(to: original)
        let empty = root.appendingPathComponent("scratch.mp4")
        try Data().write(to: empty)
        let trash = FolderTrash(folder: root.appendingPathComponent("Trash"))
        for missing in [empty.path, root.appendingPathComponent("nowhere.mp4").path] {
            #expect(throws: SafeReplace.Failure.noResult) { try SafeReplace.replace(original: original.path, with: missing, trash: trash) }
        }
        #expect(try String(contentsOf: original, encoding: .utf8) == "original")
        #expect(!FileManager.default.fileExists(atPath: trash.folder.path))
    }
}

@Suite struct WorkspaceStepTests {
    @Test func finishedStepsAreRememberedPerFile() throws {
        let root = try scratch("steps")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(root: root.appendingPathComponent("job"))
        try workspace.create()
        #expect(!workspace.isDone("loudness", for: "/w/a.m4a"))
        workspace.markDone("loudness", for: "/w/a.m4a")
        workspace.markDone("retag", for: "/w/b.m4a")
        #expect(workspace.isDone("loudness", for: "/w/a.m4a") && workspace.isDone("retag", for: "/w/b.m4a"))
        #expect(!workspace.isDone("retag", for: "/w/a.m4a") && !workspace.isDone("loudness", for: "/w/a.m4"))
    }

    @Test func theScratchFolderIsEmptiedAndAStepsToolIsStoppedAtLaunchToo() throws {
        let root = try scratch("scratch")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(root: root.appendingPathComponent("job"))
        try workspace.create()
        try Data("half".utf8).write(to: workspace.scratch.appendingPathComponent("half.m4a"))
        workspace.clearScratch()
        #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.scratch.path).isEmpty)
        // A record of this very process is not a tool to stop (it is no tool of the job's), and is cleared.
        workspace.recordStepTool(pid: getpid())
        #expect(FileManager.default.fileExists(atPath: workspace.stepToolRecord.path))
        workspace.clearStepToolRecord()
        #expect(!FileManager.default.fileExists(atPath: workspace.stepToolRecord.path))
        #expect(!workspace.stopLeftoverTool())
    }
}
