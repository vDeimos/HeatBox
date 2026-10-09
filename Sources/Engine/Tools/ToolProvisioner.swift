import Foundation

/// Why a tool could not be installed. Each has one sentence (`message`).
public enum ToolInstallError: Error, Equatable, Sendable {
    case badLock(String)
    case notSecure
    case unreachable
    /// The file arrived but is not the one the lock (or the release) names. Nothing was installed.
    case checksumMismatch(Tool)
    case cannotUnpack(Tool)
    /// The program would not start, or did not say its version.
    case notRunnable(Tool)
    case noRelease
    case notInLock(Tool)
    case cannotWrite

    public var message: String {
        switch self {
        case .badLock, .notInLock: return Messages.installLockProblem
        case .notSecure, .unreachable: return Messages.installUnreachable
        case .checksumMismatch(let tool): return Messages.installChecksum(tool.rawValue)
        case .cannotUnpack(let tool), .notRunnable(let tool): return Messages.installBroken(tool.rawValue)
        case .noRelease: return Messages.installNoRelease
        case .cannotWrite: return Messages.installCannotWrite
        }
    }
}

public enum ToolUpdateOutcome: Equatable, Sendable {
    case alreadyCurrent(version: String)
    case updated(from: String?, to: String)
}

/// Puts the tools into the app's own folder (`AppPaths.bin`, which
/// `ToolRegistry` searches before Homebrew). Every file is checked against a
/// SHA-256 before it is unpacked, started once to see that it runs, and only
/// then moved into place, so a bad or interrupted download never leaves a
/// half-installed tool and never replaces a working one.
public actor ToolProvisioner {
    private let paths: AppPaths
    private let lock: ToolLock
    private let transport: ToolTransport
    private let arch: ToolArch
    private let runner: ProcessRunner

    public init(paths: AppPaths, lock: ToolLock = .bundled, transport: ToolTransport = URLSessionTransport(),
                arch: ToolArch = .current, runner: ProcessRunner = ProcessRunner()) {
        self.paths = paths
        self.lock = lock
        self.transport = transport
        self.arch = arch
        self.runner = runner
    }

    private var staging: URL { paths.bin.appendingPathComponent(".staging", isDirectory: true) }

    /// The version this app pins for a tool.
    public func pinnedVersion(of tool: Tool) -> String? { lock.version(of: tool) }

    // MARK: Install

    /// Installs the pinned version of one tool.
    public func install(_ tool: Tool, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard let artifact = lock.artifact(for: tool, arch: arch) else { throw ToolInstallError.notInLock(tool) }
        try await install(tool, artifact: artifact, progress: progress)
    }

    /// Installs each of these that is not in the app's folder yet, one after
    /// another, stopping at the first that fails. `step` says which is next.
    public func install(_ tools: [Tool], step: @escaping @Sendable (Tool) -> Void = { _ in },
                        progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        for tool in tools {
            step(tool)
            try await install(tool, progress: progress)
        }
    }

    private func install(_ tool: Tool, artifact: ToolLock.Artifact, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard artifact.problem() == nil, let url = URL(string: artifact.url) else { throw ToolInstallError.notSecure }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: paths.bin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Whatever an earlier, interrupted install left is not trusted.
            try? fm.removeItem(at: staging)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw ToolInstallError.cannotWrite
        }
        defer { try? fm.removeItem(at: staging) }

        let download = staging.appendingPathComponent("download")
        do {
            try await transport.download(from: url, to: download, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ToolInstallError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw ToolInstallError.unreachable
        }
        guard (try? FileDigest.sha256(of: download)) == artifact.sha256 else { throw ToolInstallError.checksumMismatch(tool) }

        let program: URL
        switch artifact.kind {
        case .file:
            program = staging.appendingPathComponent(tool.executableName)
            do { try fm.moveItem(at: download, to: program) } catch { throw ToolInstallError.cannotWrite }
        case .zip:
            program = try await unpack(download, member: artifact.member, tool: tool)
        }
        try prepare(program)
        try await requireRuns(program, tool: tool)

        let destination = paths.bin.appendingPathComponent(tool.executableName)
        do {
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: program)
            } else {
                try fm.moveItem(at: program, to: destination)
            }
        } catch {
            throw ToolInstallError.cannotWrite
        }
    }

    private func unpack(_ zip: URL, member: String, tool: Tool) async throws -> URL {
        let fm = FileManager.default
        let folder = staging.appendingPathComponent("unpacked", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let request = ProcessRequest(executable: "/usr/bin/ditto", arguments: ["-x", "-k", zip.path, folder.path],
                                     environment: ["PATH": "/usr/bin:/bin"])
        guard let ran = try? await runner.run(request), ran.outcome.succeeded else { throw ToolInstallError.cannotUnpack(tool) }
        let found = folder.appendingPathComponent(member)
        // The program must be an ordinary file inside the folder: not a link, not outside it.
        let resolved = found.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(folder.resolvingSymlinksInPath().path + "/"),
              let type = (try? fm.attributesOfItem(atPath: found.path))?[.type] as? FileAttributeType, type == .typeRegular else {
            throw ToolInstallError.cannotUnpack(tool)
        }
        let program = staging.appendingPathComponent(tool.executableName)
        do { try fm.moveItem(at: found, to: program) } catch { throw ToolInstallError.cannotWrite }
        return program
    }

    /// Makes the file a program the person can run and removes macOS's
    /// "downloaded from the internet" mark, which would block it.
    private func prepare(_ program: URL) throws {
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        } catch {
            throw ToolInstallError.cannotWrite
        }
        removexattr(program.path, "com.apple.quarantine", 0)
    }

    private func requireRuns(_ program: URL, tool: Tool) async throws {
        let request = ProcessRequest(executable: program.path, arguments: tool.versionArguments,
                                     environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory(),
                                                   "LANG": "en_US.UTF-8", "NO_COLOR": "1"])
        let ran = await Clock.limited(to: 30) { try? await self.runner.run(request) }
        guard let result = ran ?? nil, result.outcome.succeeded,
              ToolRegistry.parseVersion(of: tool, from: result.standardOutput) != nil else {
            throw ToolInstallError.notRunnable(tool)
        }
    }

    // MARK: Updating yt-dlp

    private static let releasesAPI = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!

    /// A release's tag looks like `2026.08.19`, optionally with a fourth number.
    static func isReleaseTag(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return (3...4).contains(parts.count) && parts.allSatisfy { !$0.isEmpty && $0.count <= 8 && $0.allSatisfy(\.isNumber) }
    }

    /// The checksum a release's `SHA2-256SUMS` file gives for `file`.
    static func checksum(of file: String, in sums: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let words = line.split(separator: " ", omittingEmptySubsequences: true)
            guard words.count == 2, words[1].trimmingCharacters(in: CharacterSet(charactersIn: "*")) == file else { continue }
            let sum = String(words[0]).lowercased()
            return FileDigest.isSHA256(sum) ? sum : nil
        }
        return nil
    }

    /// Installs the newest yt-dlp release when it is later than `current`
    /// (the version that runs now, if any). The file is checked against the
    /// `SHA2-256SUMS` published with that release, over https.
    public func updateYtdlp(current: String?, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> ToolUpdateOutcome {
        let tag: String
        do {
            let data = try await transport.data(from: Self.releasesAPI)
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let name = object["tag_name"] as? String, Self.isReleaseTag(name) else { throw ToolInstallError.noRelease }
            tag = name
        } catch let error as ToolInstallError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw ToolInstallError.unreachable
        }
        if let current, !Versioning.isNewer(tag, than: current) { return .alreadyCurrent(version: current) }

        let base = "https://github.com/yt-dlp/yt-dlp/releases/download/\(tag)/"
        guard let sumsURL = URL(string: base + "SHA2-256SUMS") else { throw ToolInstallError.noRelease }
        let sums: String
        do {
            sums = String(decoding: try await transport.data(from: sumsURL), as: UTF8.self)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw ToolInstallError.unreachable
        }
        guard let sum = Self.checksum(of: "yt-dlp_macos", in: sums) else { throw ToolInstallError.noRelease }
        let artifact = ToolLock.Artifact(url: base + "yt-dlp_macos", sha256: sum, size: 0, kind: .file)
        try await install(.ytdlp, artifact: artifact, progress: progress)
        return .updated(from: current, to: tag)
    }
}

private enum Clock {
    static func limited<T: Sendable>(to seconds: TimeInterval, _ work: @escaping @Sendable () async -> T) async -> T? {
        await SystemClock().limited(to: seconds, work)
    }
}
