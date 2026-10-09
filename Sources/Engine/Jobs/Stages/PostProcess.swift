import Foundation

/// A step taken on a finished download before it is delivered (plan Section
/// 3.4): give each chapter file its own tags, even out the volume, re-encode
/// the video. In that order.
public enum PostStep: String, Equatable, Sendable {
    case retag, loudness, encode
}

public enum PostProcess {
    /// Which steps a recipe asks for on one finished file. `trackCount` is
    /// how many files were split off it by chapter.
    public static func steps(for recipe: DownloadRecipe, file: String, trackCount: Int) -> [PostStep] {
        let ext = (file as NSString).pathExtension.lowercased()
        var steps: [PostStep] = []
        if recipe.retagsChapters && trackCount > 0 { steps.append(.retag) }
        if recipe.evenLoudness && recipe.mode == .audio && (Loudness.extensions.contains(ext) || trackCount > 0) { steps.append(.loudness) }
        if recipe.encodeEnabled && recipe.mode != .audio && FFmpegPlanner.videoExtensions.contains(ext) { steps.append(.encode) }
        return steps
    }
}

/// The tools the steps run, and how.
struct StepTools: Sendable {
    var ffmpeg: String?
    var ffprobe: String?
    var environment: [String: String]
    var runner: ProcessRunner
}

/// Takes one finished download through its steps, inside the job's
/// workspace. A new version of a file is written to the scratch folder and
/// takes the old one's place only when it is complete, so a step that fails
/// or is stopped leaves the file exactly as it was downloaded. A failed step
/// is a warning, never a failed job (plan Phase 6).
struct FileFinisher: Sendable {
    let recipe: DownloadRecipe
    let workspace: Workspace
    let tools: StepTools
    let trash: any Trash
    let report: @Sendable (JobEvent) -> Void

    struct Finished: Equatable, Sendable {
        /// Where the main file is now; a re-encode can change its ending.
        var file: String
        var warnings: [String] = []
    }

    /// Whether this file has steps to go through.
    func hasSteps(_ file: String) -> Bool {
        guard FileManager.default.fileExists(atPath: file) else { return false }
        return !PostProcess.steps(for: recipe, file: file, trackCount: tracks(of: file).count).isEmpty
    }

    private func tracks(of file: String) -> [ChapterTagger.Track] {
        guard recipe.splitChapters, let text = try? String(contentsOf: workspace.chapterList, encoding: .utf8),
              let record = ChapterTagger.record(for: file, inLines: text, recipe: recipe) else { return [] }
        return record.tracks.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Runs the steps. Nil when the run was stopped first; the file then
    /// waits in the workspace and the steps left over run when the job resumes.
    func finish(_ mainFile: String) async -> Finished? {
        var finished = Finished(file: mainFile)
        guard FileManager.default.fileExists(atPath: mainFile) else { return finished }
        let tracks = self.tracks(of: mainFile)
        let steps = PostProcess.steps(for: recipe, file: mainFile, trackCount: tracks.count)
        guard !steps.isEmpty else { return finished }
        if Task.isCancelled { return nil }
        guard let ffmpeg = tools.ffmpeg else {
            finished.warnings.append(Messages.noConverter)
            return finished
        }
        workspace.clearScratch()
        func warn(_ sentence: String) {
            report(.log(sentence))
            if !finished.warnings.contains(sentence) { finished.warnings.append(sentence) }
        }
        for step in steps {
            if Task.isCancelled { return nil }
            switch step {
            case .retag:
                guard !workspace.isDone(step.rawValue, for: mainFile) else { continue }
                report(.stage(.processing(Messages.stageTaggingTracks)))
                let complete = await retag(tracks, mainFile: mainFile, ffmpeg: ffmpeg)
                if Task.isCancelled { return nil }
                if complete { workspace.markDone(step.rawValue, for: mainFile) } else { warn(Messages.retagFailed) }
            case .loudness:
                report(.stage(.processing(Messages.stageLoudness)))
                let files = [mainFile] + tracks.map(\.path)
                for file in files where Loudness.extensions.contains((file as NSString).pathExtension.lowercased()) {
                    guard !workspace.isDone(step.rawValue, for: file) else { continue }
                    let done = await evenOut(file, ffmpeg: ffmpeg)
                    if Task.isCancelled { return nil }
                    if done { workspace.markDone(step.rawValue, for: file) } else { warn(Messages.loudnessFailed) }
                }
            case .encode:
                report(.stage(.processing(Messages.stageEncoding(percent: nil))))
                let outcome = await encode(mainFile, ffmpeg: ffmpeg)
                if Task.isCancelled { return nil }
                switch outcome {
                case .replaced(let file):
                    finished.file = file
                    report(.log(Messages.originalInTrash))
                case .beside:
                    break
                case .besideBecauseOriginalStayed:
                    warn(Messages.replaceFailed)
                case .failed:
                    warn(Messages.encodeFailed)
                }
            }
        }
        return finished
    }

    // MARK: Running a tool

    private struct Ran {
        var outcome: ProcessOutcome
        var output: [String]
        var errors: [String]
        var succeeded: Bool { outcome.succeeded && !outcome.stopRequested }
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var out: [String] = []
        private var err: [String] = []
        func add(_ line: ProcessLine) {
            lock.lock()
            if line.source == .standardOutput { out.append(line.text) } else { err.append(line.text) }
            lock.unlock()
        }
        var all: (out: [String], err: [String]) { lock.lock(); defer { lock.unlock() }; return (out, err) }
    }

    /// Runs a tool to its end. Cancelling the task stops it. Nil when it could not be started.
    private func run(_ executable: String, _ arguments: [String], logged: Bool = true,
                     onOutput: (@Sendable (String) -> Void)? = nil) async -> Ran? {
        if logged {
            // A cover picture travels as one very long argument; the log shows where it was.
            let shown = arguments.map { $0.count > 300 ? String($0.prefix(60)) + "…" : $0 }
            report(.log("$ " + ([(executable as NSString).lastPathComponent] + shown).map(DisplayCommand.shellQuote).joined(separator: " ")))
        }
        let lines = Lines()
        let request = ProcessRequest(executable: executable, arguments: arguments, environment: tools.environment)
        guard let running = try? tools.runner.start(request, maxLineLength: JobLog.maxLineLength, onLine: { line in
            if line.source == .standardOutput, let onOutput { onOutput(line.text) } else { lines.add(line) }
        }) else { return nil }
        workspace.recordStepTool(pid: running.processIdentifier)
        let outcome = await withTaskCancellationHandler {
            await running.waitUntilExit()
        } onCancel: {
            running.stop()
        }
        workspace.clearStepToolRecord()
        let all = lines.all
        return Ran(outcome: outcome, output: all.out, errors: all.err)
    }

    private func facts(of file: String) async -> FileFacts? {
        guard let ffprobe = tools.ffprobe,
              let ran = await run(ffprobe, FileFacts.inspectArguments(file), logged: false), ran.succeeded else { return nil }
        let size = ((try? FileManager.default.attributesOfItem(atPath: file))?[.size] as? NSNumber)?.int64Value ?? 0
        return FileFacts.parse(output: ran.output.joined(separator: "\n"), size: size)
    }

    private func scratchFile(_ ext: String) -> String {
        workspace.scratch.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : "." + ext)).path
    }

    private func isUsable(_ path: String) -> Bool {
        (((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0) > 0
    }

    /// Puts a finished new version in the place of the file the tool wrote.
    /// That file is the workspace's own, not something the person had.
    private func swapIn(_ new: String, for old: String) -> Bool {
        (try? FileManager.default.replaceItemAt(URL(fileURLWithPath: old), withItemAt: URL(fileURLWithPath: new))) != nil
    }

    // MARK: Covers

    /// The cover picture inside a file, taken out untouched. Nil when it has none.
    private func cover(of file: String, ffmpeg: String) async -> ChapterTagger.Cover? {
        let raw = scratchFile("img")
        guard let ran = await run(ffmpeg, ChapterTagger.coverArguments(input: file, output: raw), logged: false), ran.succeeded,
              let head = FileHandle(forReadingAtPath: raw)?.readData(ofLength: 8), let mime = ChapterTagger.mime(of: head) else { return nil }
        return ChapterTagger.Cover(path: raw, mime: mime)
    }

    /// The cover as the tag an Ogg file carries it in, made smaller first
    /// when it is large. Nil when there is no cover or it will not fit.
    private func pictureBlock(for cover: ChapterTagger.Cover?, ffmpeg: String) async -> String? {
        guard let cover, var image = FileManager.default.contents(atPath: cover.path) else { return nil }
        var mime = cover.mime
        if image.count > 300_000 {
            let small = scratchFile("jpg")
            guard let ran = await run(ffmpeg, ChapterTagger.smallCoverArguments(input: cover.path, output: small), logged: false),
                  ran.succeeded, let data = FileManager.default.contents(atPath: small) else { return nil }
            image = data
            mime = "image/jpeg"
        }
        let block = ChapterTagger.pictureBlock(image: image, mime: mime)
        return block.count <= ChapterTagger.maxPictureBlock ? block : nil
    }

    // MARK: The steps

    /// True when every track that can be tagged was.
    private func retag(_ tracks: [ChapterTagger.Track], mainFile: String, ffmpeg: String) async -> Bool {
        let cover = await cover(of: mainFile, ffmpeg: ffmpeg)
        var block: String?
        if tracks.contains(where: { Loudness.isOgg(($0.path as NSString).pathExtension.lowercased()) }) {
            block = await pictureBlock(for: cover, ffmpeg: ffmpeg)
        }
        var complete = true
        for (index, track) in tracks.enumerated() {
            if Task.isCancelled { return false }
            let ext = (track.path as NSString).pathExtension.lowercased()
            guard ChapterTagger.taggableExtensions.contains(ext) else { continue }
            let output = scratchFile(ext)
            let arguments = ChapterTagger.retagArguments(track: track, index: index, total: tracks.count, cover: cover,
                                                         pictureBlock: block, output: output)
            let ran = await run(ffmpeg, arguments, logged: false)
            if ran?.succeeded == true, isUsable(output), swapIn(output, for: track.path) {
                report(.log(Messages.taggedTrack(index + 1, of: tracks.count, track.title)))
            } else {
                try? FileManager.default.removeItem(atPath: output)
                complete = false
                report(.log(Messages.skippedTrack((track.path as NSString).lastPathComponent, ran?.errors.last ?? Messages.noConverter)))
            }
        }
        return complete
    }

    /// True when the file now has an even volume; false when it was left as it was.
    private func evenOut(_ file: String, ffmpeg: String) async -> Bool {
        guard let facts = await facts(of: file), facts.audioCodec != nil else { return false }
        if Task.isCancelled { return false }
        // First pass: measure. Silence has nothing to measure; then one adaptive pass does it.
        var measured: Loudness.Measurement?
        if let first = await run(ffmpeg, Loudness.measureArguments(input: file), logged: false), first.succeeded {
            measured = Loudness.parse(first.errors.joined(separator: "\n"))
        }
        if Task.isCancelled { return false }
        let ext = (file as NSString).pathExtension.lowercased()
        var block: String?
        if Loudness.isOgg(ext), facts.hasCover {
            block = await pictureBlock(for: await cover(of: file, ffmpeg: ffmpeg), ffmpeg: ffmpeg)
        }
        let output = scratchFile(ext)
        guard let arguments = Loudness.normalizeArguments(input: file, output: output, measured: measured, facts: facts,
                                                          recipe: recipe, pictureBlock: block),
              let second = await run(ffmpeg, arguments), second.succeeded, isUsable(output), !Task.isCancelled,
              swapIn(output, for: file) else {
            try? FileManager.default.removeItem(atPath: output)
            return false
        }
        return true
    }

    private enum Encoded {
        /// The encoded file took the original's place; the original is in the Trash.
        case replaced(String)
        /// The encoded file sits beside the original, as asked.
        case beside
        case besideBecauseOriginalStayed
        case failed
    }

    private func encode(_ file: String, ffmpeg: String) async -> Encoded {
        let facts = await facts(of: file)
        if Task.isCancelled { return .failed }
        let ext = recipe.container.rawValue
        let output = scratchFile(ext)
        let plan = FFmpegPlanner.encode(recipe: recipe, input: file, output: output, facts: facts)
        let shown = Percent()
        let report = self.report
        let onOutput: @Sendable (String) -> Void = { line in
            guard plan.outputDuration > 0, let done = FFmpegPlanner.progressSeconds(line: line),
                  let percent = shown.changed(to: Int(min(max(done / plan.outputDuration, 0), 1) * 100)) else { return }
            report(.stage(.processing(Messages.stageEncoding(percent: percent))))
        }
        var ran = await run(ffmpeg, plan.arguments, onOutput: onOutput)
        if ran?.succeeded != true, !Task.isCancelled, let fallback = plan.fallback {
            // The Mac's video hardware refused; the software encoder takes over.
            for line in ran?.errors.suffix(5) ?? [] { report(.log(line)) }
            report(.log(Messages.encodeFallback))
            try? FileManager.default.removeItem(atPath: output)
            ran = await run(ffmpeg, fallback, onOutput: onOutput)
        }
        guard ran?.succeeded == true, isUsable(output), !Task.isCancelled else {
            for line in ran?.errors.suffix(5) ?? [] { report(.log(line)) }
            try? FileManager.default.removeItem(atPath: output)
            return .failed
        }
        let folder = (file as NSString).deletingLastPathComponent
        let stem = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        if recipe.replaceOriginal {
            do {
                return .replaced(try SafeReplace.replace(original: file, with: output, trash: trash))
            } catch SafeReplace.Failure.originalKept {
                return .besideBecauseOriginalStayed
            } catch {
                try? FileManager.default.removeItem(atPath: output)
                return .failed
            }
        }
        // Named like the original, so it is delivered with it under the same clean name.
        guard (try? Delivery.move(output, toFolder: folder, stem: stem + ".encoded", ending: "." + ext)) != nil else {
            try? FileManager.default.removeItem(atPath: output)
            return .failed
        }
        return .beside
    }

    /// The last percentage shown, so each one is reported once.
    private final class Percent: @unchecked Sendable {
        private let lock = NSLock()
        private var value = -1
        func changed(to new: Int) -> Int? {
            lock.lock(); defer { lock.unlock() }
            guard new != value else { return nil }
            value = new
            return new
        }
    }
}
