import Foundation

/// A job's own working folder, `jobs/<job-id>/` (plan Rule 5). The download
/// tool writes only in here: unfinished data in `partial`, finished files in
/// `files`, from where the engine moves them to their destination. Cancel
/// removes the folder; pause keeps it, so the download carries on from what
/// it has.
public struct Workspace: Equatable, Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public init(paths: AppPaths, job: UUID) {
        self.init(root: paths.workspace(forJob: job))
    }

    /// Where the tool puts each file once it is complete.
    public var staging: URL { root.appendingPathComponent("files", isDirectory: true) }
    /// The tool's scratch space: partly downloaded files and pieces not yet joined.
    public var partial: URL { root.appendingPathComponent("partial", isDirectory: true) }
    /// The tool appends the path of every finished download here.
    public var fileList: URL { root.appendingPathComponent("finished.txt") }
    /// A playlist's own record of the items it has finished, so that a
    /// resumed list does not fetch them again.
    public var archive: URL { root.appendingPathComponent("archive.txt") }
    /// The download tool notes each finished video's chapter files here.
    public var chapterList: URL { root.appendingPathComponent("chapters.txt") }
    /// The download tool notes each finished video's id, title and channel here, for the Library.
    public var noteList: URL { root.appendingPathComponent("library.txt") }
    /// Where the download tool puts each video's picture, for the Library.
    public var thumbnails: URL { root.appendingPathComponent("thumbs", isDirectory: true) }
    /// A video's details with chapters from its comments, for the download to load.
    public var infoFile: URL { root.appendingPathComponent("details.info.json") }
    /// Where the steps after a download write a new version of a file before it replaces the old one.
    public var scratch: URL { root.appendingPathComponent("scratch", isDirectory: true) }
    /// The steps that are finished for a file, so a resumed job does not repeat them.
    var stepList: URL { root.appendingPathComponent("steps.txt") }
    /// The tool that is running for this job, if any.
    var toolRecord: URL { root.appendingPathComponent("tool.json") }
    /// A tool that a step after the download is running, if any.
    var stepToolRecord: URL { root.appendingPathComponent("step-tool.json") }

    public var exists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public func create() throws {
        for folder in [root, staging, partial, scratch, thumbnails] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
    }

    public func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: The running tool

    /// Notes which process is working in this folder, so that a later launch
    /// can stop it if the app is killed while it runs.
    public func recordTool(pid: Int32) {
        record(pid, in: toolRecord)
    }

    public func clearToolRecord() {
        try? FileManager.default.removeItem(at: toolRecord)
    }

    /// The same for a tool run by a step after the download, which can be
    /// at work while the download tool is.
    func recordStepTool(pid: Int32) {
        record(pid, in: stepToolRecord)
    }

    func clearStepToolRecord() {
        try? FileManager.default.removeItem(at: stepToolRecord)
    }

    private func record(_ pid: Int32, in file: URL) {
        guard let identity = ProcessIdentity.of(pid), let data = try? JSONEncoder().encode(identity) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// Stops a tool left running in this folder by an earlier launch of the
    /// app. Returns true when one was found and stopped.
    @discardableResult
    public func stopLeftoverTool() -> Bool {
        var stopped = false
        for file in [toolRecord, stepToolRecord] {
            defer { try? FileManager.default.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file),
                  let identity = try? JSONDecoder().decode(ProcessIdentity.self, from: data) else { continue }
            if identity.stopGroup() { stopped = true }
        }
        return stopped
    }

    // MARK: Steps after the download

    /// True when `step` was finished for `file` in an earlier run.
    func isDone(_ step: String, for file: String) -> Bool {
        let line = step + "\t" + file
        return ((try? String(contentsOf: stepList, encoding: .utf8)) ?? "").split(separator: "\n").contains { $0 == line }
    }

    func markDone(_ step: String, for file: String) {
        let line = Data((step + "\t" + file + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: stepList) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: stepList)
        }
    }

    /// Empties the scratch folder: whatever a stopped step left half-written.
    func clearScratch() {
        try? FileManager.default.removeItem(at: scratch)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    // MARK: Launch

    /// Puts the working folders in order when the app starts. Any tool an
    /// earlier launch left running is stopped. A folder whose job is still in
    /// the queue is kept, so that job can carry on from it; every other one
    /// is removed. Returns the ids of the folders that were removed.
    @discardableResult
    public static func reconcile(paths: AppPaths, keeping: Set<UUID>) -> [UUID] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: paths.jobs.path) else { return [] }
        var removed: [UUID] = []
        for name in names {
            // Only folders the app made are touched.
            guard let id = UUID(uuidString: name), paths.workspace(forJob: id).lastPathComponent == name else { continue }
            let workspace = Workspace(paths: paths, job: id)
            guard workspace.exists else { continue }
            workspace.stopLeftoverTool()
            if !keeping.contains(id) {
                workspace.remove()
                removed.append(id)
            }
        }
        return removed
    }
}
