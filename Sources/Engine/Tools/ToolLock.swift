import Foundation
import CryptoKit

/// Which kind of Mac this is running on, as far as the tools it needs.
public enum ToolArch: String, Sendable, CaseIterable {
    case arm64
    case x86_64

    /// The slice of the app that is running. A universal build run under
    /// Rosetta is its x86_64 slice, and takes x86_64 tools that run the same way.
    public static var current: ToolArch {
        #if arch(arm64)
        return .arm64
        #else
        return .x86_64
        #endif
    }
}

/// The tools the app installs for itself: what to fetch, from where,
/// and the SHA-256 the file must have. The file is `tools.lock.json` at the
/// repository root; `ToolLock.bundled` is the same text compiled in.
public struct ToolLock: Codable, Equatable, Sendable {
    public struct Artifact: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case file, zip }
        public var url: String
        public var sha256: String
        public var size: Int
        public var kind: Kind
        /// For a zip: the file inside it that is the program.
        public var member: String

        public init(url: String, sha256: String, size: Int, kind: Kind, member: String = "") {
            self.url = url
            self.sha256 = sha256
            self.size = size
            self.kind = kind
            self.member = member
        }
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var version: String
        public var license: String
        public var source: String
        /// By architecture name (`arm64`, `x86_64`).
        public var artifacts: [String: Artifact]
    }

    public var format: Int
    /// By tool name (`yt-dlp`, `ffmpeg`, `ffprobe`, `deno`).
    public var tools: [String: Entry]

    public func entry(for tool: Tool) -> Entry? { tools[tool.rawValue] }

    public func artifact(for tool: Tool, arch: ToolArch) -> Artifact? {
        entry(for: tool)?.artifacts[arch.rawValue]
    }

    public func version(of tool: Tool) -> String? { entry(for: tool)?.version }

    /// The lock compiled into the app.
    public static let bundled: ToolLock = {
        guard let lock = try? parse(Data(bundledJSON.utf8)) else { fatalError("tools.lock.json compiled into the app is not valid") }
        return lock
    }()

    public static func parse(_ data: Data) throws -> ToolLock {
        let lock = try JSONDecoder().decode(ToolLock.self, from: data)
        if let problem = lock.problem() { throw ToolInstallError.badLock(problem) }
        return lock
    }

    /// What is wrong with the lock, or nil. Every tool must have an artifact
    /// for every architecture, fetched over https and checked by a SHA-256.
    func problem() -> String? {
        guard format == 1 else { return "unknown format \(format)" }
        for tool in Tool.allCases {
            guard let entry = entry(for: tool) else { return "\(tool.rawValue) is missing" }
            for arch in ToolArch.allCases {
                guard let artifact = entry.artifacts[arch.rawValue] else { return "\(tool.rawValue) has nothing for \(arch.rawValue)" }
                if let reason = artifact.problem() { return "\(tool.rawValue) \(arch.rawValue): \(reason)" }
            }
        }
        return nil
    }
}

extension ToolLock.Artifact {
    func problem() -> String? {
        guard let url = URL(string: url), url.scheme == "https", url.host != nil else { return "the address is not https" }
        guard FileDigest.isSHA256(sha256) else { return "the checksum is not a SHA-256" }
        if kind == .zip, member.isEmpty || member.contains("/") || member.contains("..") { return "the file inside the zip is not a plain name" }
        return nil
    }
}

public enum FileDigest {
    public static func isSHA256(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// The SHA-256 of a file, as lowercase hex, read in pieces.
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
