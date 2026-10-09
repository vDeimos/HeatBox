import Foundation

/// The last step of a job: giving finished files their names and moving them
/// from the job's working folder to their destination (plan Rule 5).
///
/// A user's file is never overwritten: a name that is taken gets a number.
/// Files are moved one by one and folders are merged, so a template that
/// sorts files into folders ("Uploader/Title.mp4") keeps doing so.
public enum Delivery {
    /// How a job wants its files named.
    public struct NameRule: Equatable, Sendable {
        /// The recipe uses the guided template, whose names carry the video's
        /// id so nothing collides while downloading. Those names are tidied
        /// here. Any other template is the person's own choice and is kept.
        public var guided: Bool
        /// One video, as opposed to a playlist.
        public var single: Bool
        public var style: NameStyle
        public var facts: VideoFacts?
        public var clip: Bool

        public init(guided: Bool, single: Bool, style: NameStyle = .title, facts: VideoFacts? = nil, clip: Bool = false) {
            self.guided = guided
            self.single = single
            self.style = style
            self.facts = facts
            self.clip = clip
        }

        public init(job: Job, style: NameStyle) {
            self.init(guided: job.recipe.filenameTemplate == .guided, single: job.source == .video,
                      style: style, facts: job.facts, clip: job.recipe.clip != nil)
        }
    }

    /// The clean name, without extension, for a finished file whose name
    /// without extension is `stem`. A single video takes the name style from
    /// Settings; a playlist item keeps its number and title and loses the id.
    public static func cleanStem(for stem: String, rule: NameRule) -> String {
        guard rule.guided else { return stem }
        if rule.single, let facts = rule.facts {
            let base = Naming.fileStem(style: rule.style, facts: facts)
            return rule.clip ? base + Messages.clipSuffix : base
        }
        return stemWithoutID(stem)
    }

    /// "Title [abc123]" without the trailing " [abc123]".
    static func stemWithoutID(_ stem: String) -> String {
        guard stem.hasSuffix("]"), let open = stem.lastIndex(of: "[") else { return stem }
        let trimmed = String(stem[..<open]).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? stem : trimmed
    }

    /// Moves one finished download out of `staging` into `folder`, together
    /// with the files that belong to it (subtitles, a picture, a
    /// description: anything named like it), and returns where the main file
    /// ended up. Nil when the file is not in `staging` (it was moved before).
    public static func deliver(mainFile: String, staging: URL, folder: String, rule: NameRule) throws -> String? {
        let stagingPath = staging.standardizedFileURL.path
        let main = URL(fileURLWithPath: mainFile).standardizedFileURL
        guard main.path.hasPrefix(stagingPath + "/"), FileManager.default.fileExists(atPath: main.path) else { return nil }

        let sourceFolder = main.deletingLastPathComponent()
        let relative = String(sourceFolder.path.dropFirst(stagingPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let targetFolder = relative.isEmpty ? folder : (folder as NSString).appendingPathComponent(relative)
        try FileManager.default.createDirectory(atPath: targetFolder, withIntermediateDirectories: true)

        let name = main.lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        // Everything named "<stem>.<something>" travels with the main file and keeps its ending.
        let siblings = ((try? FileManager.default.contentsOfDirectory(atPath: sourceFolder.path)) ?? [])
            .filter { $0 != name && $0.hasPrefix(stem + ".") && !isDirectory(sourceFolder.appendingPathComponent($0).path) }
        let endings = [String(name.dropFirst(stem.count))] + siblings.map { String($0.dropFirst(stem.count)) }

        // One number for the whole group, so the files still belong together by name.
        // Short enough that the longest of them is still a name the disk takes.
        let longest = endings.max { Naming.size($0) < Naming.size($1) } ?? ""
        let clean = Naming.stem(cleanStem(for: stem, rule: rule), fitting: longest)
        var number = 1
        var chosen = clean
        while number < 10_000 {
            chosen = number == 1 ? clean : "\(clean) (\(number))"
            let taken = endings.contains { FileManager.default.fileExists(atPath: (targetFolder as NSString).appendingPathComponent(chosen + $0)) }
            if !taken { break }
            number += 1
        }
        var delivered = ""
        for (index, ending) in endings.enumerated() {
            let source = sourceFolder.appendingPathComponent(stem + ending).path
            let target = try move(source, toFolder: targetFolder, stem: chosen, ending: ending)
            if index == 0 { delivered = target }
        }
        return delivered
    }

    /// Moves everything still in `staging` into `folder`, keeping names and
    /// folders: what a download leaves beside its main files (chapter files,
    /// a playlist's picture). Returns the new paths.
    @discardableResult
    public static func deliverRest(staging: URL, folder: String) throws -> [String] {
        let stagingPath = staging.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(atPath: stagingPath) else { return [] }
        var files: [String] = []
        for case let relative as String in walker where !isDirectory((stagingPath as NSString).appendingPathComponent(relative)) {
            files.append(relative)
        }
        var delivered: [String] = []
        for relative in files.sorted() {
            let subfolder = (relative as NSString).deletingLastPathComponent
            let targetFolder = subfolder.isEmpty ? folder : (folder as NSString).appendingPathComponent(subfolder)
            try FileManager.default.createDirectory(atPath: targetFolder, withIntermediateDirectories: true)
            let name = (relative as NSString).lastPathComponent
            let stem = (name as NSString).deletingPathExtension
            delivered.append(try move((stagingPath as NSString).appendingPathComponent(relative), toFolder: targetFolder,
                                      stem: stem, ending: String(name.dropFirst(stem.count))))
        }
        return delivered
    }

    // MARK: Moving

    /// Moves a file to `folder` as `stem + ending`, numbering the name when it
    /// is taken. The move never replaces a file: the system refuses a name
    /// that exists, even one that appeared a moment ago.
    static func move(_ source: String, toFolder folder: String, stem: String, ending: String) throws -> String {
        let stem = Naming.stem(stem, fitting: ending)
        var number = 1
        while number < 10_000 {
            let name = (number == 1 ? stem : "\(stem) (\(number))") + ending
            let target = (folder as NSString).appendingPathComponent(name)
            if try moveExclusive(source, to: target) { return target }
            number += 1
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// True when the file was moved; false when the name is taken.
    private static func moveExclusive(_ source: String, to target: String) throws -> Bool {
        if renamex_np(source, target, UInt32(RENAME_EXCL)) == 0 { return true }
        switch errno {
        case EEXIST:
            return false
        case EXDEV:
            // Another disk: copy beside the destination under a hidden name,
            // then give it its name in one step, so a half-copied file never
            // carries the final name.
            let folder = (target as NSString).deletingLastPathComponent
            let hidden = (folder as NSString).appendingPathComponent(".\(UUID().uuidString).partial")
            try FileManager.default.copyItem(atPath: source, toPath: hidden)
            if renamex_np(hidden, target, UInt32(RENAME_EXCL)) == 0 {
                try? FileManager.default.removeItem(atPath: source)
                return true
            }
            let code = errno
            if code == EEXIST {
                try? FileManager.default.removeItem(atPath: hidden)
                return false
            }
            // A disk that cannot refuse a taken name: check, then move.
            if FileManager.default.fileExists(atPath: target) {
                try? FileManager.default.removeItem(atPath: hidden)
                return false
            }
            try FileManager.default.moveItem(atPath: hidden, toPath: target)
            try? FileManager.default.removeItem(atPath: source)
            return true
        default:
            if FileManager.default.fileExists(atPath: target) { return false }
            try FileManager.default.moveItem(atPath: source, toPath: target)
            return true
        }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
