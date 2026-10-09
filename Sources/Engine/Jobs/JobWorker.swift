import Foundation

/// What a worker is given besides the job: the job's working folder and the
/// defaults from Settings that apply to every download (plan Rule 6).
public struct JobContext: Equatable, Sendable {
    public var workspace: Workspace
    public var folders: FolderRules
    public var nameStyle: NameStyle
    /// A saved sign-in (Netscape cookies file), when the person uses one.
    public var cookiesFile: String?
    /// Kilobytes per second; 0 means no limit.
    public var speedLimitKB: Int
    /// The download archive for recipes that skip what is already downloaded.
    public var archiveFile: String

    public init(workspace: Workspace, folders: FolderRules, nameStyle: NameStyle = .title, cookiesFile: String? = nil,
                speedLimitKB: Int = 0, archiveFile: String) {
        self.workspace = workspace
        self.folders = folders
        self.nameStyle = nameStyle
        self.cookiesFile = cookiesFile
        self.speedLimitKB = speedLimitKB
        self.archiveFile = archiveFile
    }
}

/// What a worker tells the queue while it runs a job.
public enum JobEvent: Equatable, Sendable {
    /// The look-up found out what the link is.
    case resolved(JobResolution)
    /// Where the files will go, once that is decided.
    case destination(String)
    case stage(JobStage)
    case progress(JobProgress)
    /// A finished file, at its final path.
    case file(String)
    /// A line for the job's log.
    case log(String)
}

/// How one run of a job ended.
public enum JobOutcome: Equatable, Sendable {
    /// Everything that could be downloaded was. Warnings say what could not.
    case finished(message: String, warnings: [String])
    /// One sentence with a next step, and whether waiting a little may fix it.
    case failed(message: String, retryable: Bool)
    /// The run was stopped because its task was cancelled (pause or cancel).
    case stopped
}

/// Carries a job out: look up (if needed), download, finalise. The queue
/// decides when and how often; the worker does the work once and reports.
/// Cancelling the task it runs in stops it; it then returns `.stopped`, after
/// its tool has ended. Tests give the queue a worker that runs no tool.
public protocol JobWorker: Sendable {
    func run(_ job: Job, context: JobContext, report: @escaping @Sendable (JobEvent) -> Void) async -> JobOutcome
}

extension Job {
    /// The recipe as this job runs it. The job's source decides between one
    /// video and the whole list, whatever the recipe says: a playlist gets
    /// Phobos's playlist manners and an archive, so that a resumed list does
    /// not fetch finished items again. The speed limit from Settings applies
    /// unless the recipe names its own.
    public func downloadRecipe(speedLimitKB: Int) -> DownloadRecipe {
        var result = recipe
        if source == .playlist {
            result = result.forPlaylist()
            result.useArchive = true
        } else {
            result.playlistMode = .single
        }
        if result.rateLimit.trimmed.isEmpty, let rate = SpeedLimit.rateArgument(kilobytes: speedLimitKB) {
            result.rateLimit = rate
        }
        return result
    }

    /// The download as a command request. The run and the preview both come
    /// from here, so they can differ only in what they pass in: the run names
    /// the job's working folder and, for a playlist, a private archive; the
    /// preview names the real destination (plan Section 3.3.7).
    public func commandRequest(folder: String, archiveFile: String?, cookiesFile: String?, speedLimitKB: Int) -> YtdlpCommand.Request {
        var recipe = downloadRecipe(speedLimitKB: speedLimitKB)
        if archiveFile == nil { recipe.useArchive = false }
        return YtdlpCommand.Request(recipe: recipe, links: [link], folder: folder, archiveFile: archiveFile, cookiesFile: cookiesFile)
    }
}
