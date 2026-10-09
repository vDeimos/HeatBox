import Foundation

/// Where the app keeps its own files. Everything lives under one
/// root, `~/Library/Application Support/<App>/`; no other file builds one of
/// these paths. Tests pass a temporary root.
public struct AppPaths: Equatable, Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func standard() -> AppPaths {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppPaths(root: support.appendingPathComponent(Engine.supportFolderName, isDirectory: true))
    }

    /// Tools the app installs for itself (Phase 10). Searched before Homebrew.
    public var bin: URL { root.appendingPathComponent("bin", isDirectory: true) }
    /// One working folder per job, used as yt-dlp's temporary folder.
    public var jobs: URL { root.appendingPathComponent("jobs", isDirectory: true) }
    public var thumbnails: URL { root.appendingPathComponent("thumbnails", isDirectory: true) }

    public var settingsFile: URL { root.appendingPathComponent("settings.json") }
    public var presetsFile: URL { root.appendingPathComponent("presets.json") }
    public var queueFile: URL { root.appendingPathComponent("queue.json") }
    public var followingFile: URL { root.appendingPathComponent("following.json") }
    /// What the one-time import from the older apps did (Phase 7); its presence means it need not run again.
    public var importRecord: URL { root.appendingPathComponent("import.json") }
    public var libraryDatabase: URL { root.appendingPathComponent("library.sqlite") }
    public var transcriptsDatabase: URL { root.appendingPathComponent("transcripts.sqlite") }
    /// The saved YouTube sign-in (a cookies file), when the person made one.
    public var signInFile: URL { root.appendingPathComponent("cookies.txt") }
    /// The download tool's record of what has been downloaded, for recipes that skip those.
    public var archiveFile: URL { root.appendingPathComponent("download-archive.txt") }

    /// A job's working folder. The name is a UUID, so it can never reach outside `jobs`.
    public func workspace(forJob id: UUID) -> URL {
        jobs.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    /// Creates the folders the app writes into, readable only by the user.
    public func createFolders() throws {
        for folder in [root, bin, jobs, thumbnails] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
    }
}
