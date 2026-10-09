import Foundation

/// The step before a download whose recipe takes chapters from the
/// comments: fetch the video's details, put the chapter list in, and write
/// them where the download will load them from (plan Section 3.4). When it
/// cannot be done the download goes ahead without those chapters and the job
/// ends with a note; it is never a reason to fail.
struct CommentChapterStage: Sendable {
    let toolchain: YtdlpCommand.Toolchain
    let runner: ProcessRunner
    let clock: any EngineClock
    /// How long one fetch may take before it is given up.
    let timeout: TimeInterval
    let report: @Sendable (JobEvent) -> Void

    enum Outcome: Equatable, Sendable {
        /// The details are in this file, ready to be loaded.
        case prepared(String)
        /// Carry on with an ordinary download, and say this at the end.
        case skipped(warning: String?)
        case stopped
    }

    func run(job: Job, cookiesFile: String?, into file: URL) async -> Outcome {
        guard !job.isPlaylist else { return .skipped(warning: Messages.commentChaptersOneVideoOnly) }
        let source = job.recipe.chapterSource
        // "Only when the video has none" looks at the video's own chapters
        // first, and reads the comments only when they are needed.
        if source == .commentsIfMissing {
            report(.stage(.processing(Messages.stageCheckingChapters)))
            guard let info = await fetch(job, comments: false, cookiesFile: cookiesFile) else {
                return Task.isCancelled ? .stopped : .skipped(warning: Messages.commentChaptersUnreadable)
            }
            if !CommentChapters.lacksChapters(info) { return write(info, source: source, job: job, to: file) }
        }
        if Task.isCancelled { return .stopped }
        report(.stage(.processing(Messages.stageCommentChapters)))
        guard let info = await fetch(job, comments: true, cookiesFile: cookiesFile) else {
            return Task.isCancelled ? .stopped : .skipped(warning: Messages.commentChaptersUnreadable)
        }
        return write(info, source: source, job: job, to: file)
    }

    private func fetch(_ job: Job, comments: Bool, cookiesFile: String?) async -> [String: Any]? {
        let arguments = CommentChapters.fetchArguments(link: job.link, includeComments: comments, cookiesFile: cookiesFile,
                                                       cookieBrowser: job.recipe.cookieBrowser, proxy: job.recipe.proxy,
                                                       toolchain: toolchain)
        let request = ProcessRequest(executable: toolchain.ytdlp, arguments: arguments, environment: toolchain.environment)
        let runner = self.runner
        let answer = await clock.limited(to: timeout) { try? await runner.run(request) }
        guard let output = answer ?? nil, !Task.isCancelled, !output.outcome.stopRequested else { return nil }
        guard let info = (try? JSONSerialization.jsonObject(with: Data(output.standardOutput.utf8))) as? [String: Any] else {
            if let last = output.standardError.split(separator: "\n").last { report(.log(String(last))) }
            return nil
        }
        return info
    }

    private func write(_ info: [String: Any], source: ChapterSource, job: Job, to file: URL) -> Outcome {
        do {
            let prepared = try CommentChapters.prepare(info, source: source, selection: job.chapterComment,
                                                        keepComments: job.recipe.writeComments)
            report(.log(prepared.note))
            try JSONSerialization.data(withJSONObject: prepared.info).write(to: file, options: .atomic)
            return .prepared(file.path)
        } catch CommentChapters.Problem.noneFound {
            return .skipped(warning: Messages.commentChaptersNone)
        } catch CommentChapters.Problem.selectionGone {
            return .skipped(warning: Messages.commentChaptersGone)
        } catch CommentChapters.Problem.notOneVideo {
            return .skipped(warning: Messages.commentChaptersOneVideoOnly)
        } catch {
            return .skipped(warning: Messages.commentChaptersUnreadable)
        }
    }
}
