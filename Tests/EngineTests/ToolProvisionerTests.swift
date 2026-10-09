import Foundation
import Testing
@testable import Engine

/// Stands in for the internet: each address maps to what it answers.
final class FakeTransport: ToolTransport, @unchecked Sendable {
    enum Reply {
        case file(Data)
        /// Writes this much, then the connection drops.
        case dropsAfter(Data)
        case fails
    }

    private let lock = NSLock()
    private var replies: [String: Reply] = [:]
    private var asked: [String] = []

    func reply(_ url: String, _ reply: Reply) { lock.lock(); replies[url] = reply; lock.unlock() }
    var requests: [String] { lock.lock(); defer { lock.unlock() }; return asked }

    private func next(_ url: URL) -> Reply {
        lock.lock(); defer { lock.unlock() }
        asked.append(url.absoluteString)
        return replies[url.absoluteString] ?? .fails
    }

    func data(from url: URL) async throws -> Data {
        switch next(url) {
        case .file(let data): return data
        default: throw ToolInstallError.unreachable
        }
    }

    func download(from url: URL, to file: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        switch next(url) {
        case .file(let data):
            try data.write(to: file)
            progress(1)
        case .dropsAfter(let data):
            try data.write(to: file)
            throw ToolInstallError.unreachable
        case .fails:
            throw ToolInstallError.unreachable
        }
    }
}

/// A scratch support folder, a fake internet and a lock that names what the fake serves.
struct InstallFixture {
    let root: URL
    let paths: AppPaths
    let transport = FakeTransport()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("provision-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = AppPaths(root: root.appendingPathComponent("support"))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    /// What the tool prints when asked its version.
    static func program(_ tool: Tool, version: String) -> Data {
        let line: String
        switch tool {
        case .ytdlp: line = version
        case .ffmpeg, .ffprobe: line = "\(tool.rawValue) version \(version) Copyright (c) the FFmpeg developers"
        case .deno: line = "deno \(version) (stable, release, arm64)"
        }
        return Data("#!/bin/sh\necho '\(line)'\n".utf8)
    }

    static let brokenProgram = Data("#!/bin/sh\nexit 1\n".utf8)

    func zip(containing files: [String: Data], links: [String: String] = [:]) throws -> Data {
        let folder = root.appendingPathComponent("zip-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, data) in files {
            let file = folder.appendingPathComponent(name)
            try data.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        for (name, target) in links {
            try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent(name).path, withDestinationPath: target)
        }
        let output = root.appendingPathComponent("\(folder.lastPathComponent).zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", folder.path, output.path]
        try ditto.run()
        ditto.waitUntilExit()
        return try Data(contentsOf: output)
    }

    static func sha256(_ data: Data) throws -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sum-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try data.write(to: file)
        return try FileDigest.sha256(of: file)
    }

    /// A lock for every tool: yt-dlp as a plain file, the others zipped, the same on both architectures.
    func lock(serving programs: [Tool: Data], zipped: Set<Tool> = [.ffmpeg, .ffprobe, .deno], claiming: [Tool: String] = [:]) throws -> ToolLock {
        var tools: [String: ToolLock.Entry] = [:]
        for tool in Tool.allCases {
            let program = programs[tool] ?? Self.program(tool, version: "1.0")
            let isZip = zipped.contains(tool)
            let served = isZip ? try zip(containing: [tool.executableName: program]) : program
            let url = "https://example.test/\(tool.rawValue)\(isZip ? ".zip" : "")"
            transport.reply(url, .file(served))
            let artifact = ToolLock.Artifact(url: url, sha256: try claiming[tool] ?? Self.sha256(served), size: served.count,
                                             kind: isZip ? .zip : .file, member: isZip ? tool.executableName : "")
            tools[tool.rawValue] = ToolLock.Entry(version: "1.0", license: "test", source: "test",
                                                  artifacts: ["arm64": artifact, "x86_64": artifact])
        }
        return ToolLock(format: 1, tools: tools)
    }

    func provisioner(_ lock: ToolLock) -> ToolProvisioner {
        ToolProvisioner(paths: paths, lock: lock, transport: transport, arch: .arm64)
    }

    var binFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: paths.bin.path)) ?? []).sorted()
    }

    func installed(_ tool: Tool) -> String? {
        let path = paths.bin.appendingPathComponent(tool.executableName).path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}

@Suite struct ToolLockTests {
    @Test func theLockCompiledIntoTheAppIsTheOneInTheRepository() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools.lock.json")
        let onDisk = try ToolLock.parse(Data(contentsOf: file))
        #expect(onDisk == ToolLock.bundled)
    }

    @Test func everyToolHasAnHttpsAddressAndAChecksumForBothKindsOfMac() {
        let lock = ToolLock.bundled
        for tool in Tool.allCases {
            for arch in ToolArch.allCases {
                let artifact = lock.artifact(for: tool, arch: arch)
                #expect(artifact != nil, "\(tool.rawValue) \(arch.rawValue)")
                #expect(artifact?.problem() == nil, "\(tool.rawValue) \(arch.rawValue)")
                #expect(artifact?.url.hasPrefix("https://") == true)
            }
        }
        #expect(lock.version(of: .ffmpeg) == lock.version(of: .ffprobe))
    }

    @Test func aLockWithAPlainHttpAddressOrABadChecksumIsRefused() throws {
        var lock = ToolLock.bundled
        lock.tools["deno"]?.artifacts["arm64"]?.url = "http://example.com/deno.zip"
        #expect(lock.problem() != nil)
        lock = ToolLock.bundled
        lock.tools["deno"]?.artifacts["arm64"]?.sha256 = "ABC"
        #expect(lock.problem() != nil)
        lock = ToolLock.bundled
        lock.tools["ffmpeg"]?.artifacts["x86_64"]?.member = "../ffmpeg"
        #expect(lock.problem() != nil)
        lock = ToolLock.bundled
        lock.tools["ffprobe"] = nil
        #expect(lock.problem() != nil)
        #expect(throws: ToolInstallError.self) { try ToolLock.parse(Data("{\"format\":1,\"tools\":{}}".utf8)) }
    }

    @Test func aChecksumIsLowercaseHexOfTheRightLength() {
        #expect(FileDigest.isSHA256(String(repeating: "a", count: 64)))
        #expect(!FileDigest.isSHA256(String(repeating: "A", count: 64)))
        #expect(!FileDigest.isSHA256(String(repeating: "a", count: 63)))
        #expect(!FileDigest.isSHA256(String(repeating: "g", count: 64)))
    }
}

@Suite struct ToolProvisionerTests {
    @Test func everyToolIsInstalledRunnableAndTheFolderHoldsNothingElse() async throws {
        let fixture = try InstallFixture()
        defer { fixture.cleanUp() }
        let provisioner = fixture.provisioner(try fixture.lock(serving: [:]))
        try await provisioner.install(Tool.allCases)
        #expect(fixture.binFiles == ["deno", "ffmpeg", "ffprobe", "yt-dlp"])
        for tool in Tool.allCases { #expect(fixture.installed(tool) != nil) }
        // The registry finds them, as the app's own, ahead of Homebrew.
        let registry = ToolRegistry(managedFolder: fixture.paths.bin.path)
        #expect(registry.locate(.ytdlp) == ToolLocation(path: fixture.paths.bin.appendingPathComponent("yt-dlp").path, source: .managed))
        #expect(await registry.version(of: .ytdlp) == "1.0")
        #expect(await registry.version(of: .deno) == "1.0")
    }

    @Test func aFileWithTheWrongChecksumIsRefusedAndNothingIsInstalled() async throws {
        let fixture = try InstallFixture()
        defer { fixture.cleanUp() }
        let wrong = String(repeating: "0", count: 64)
        let lock = try fixture.lock(serving: [:], claiming: [.ytdlp: wrong, .deno: wrong])
        let provisioner = fixture.provisioner(lock)
        await #expect(throws: ToolInstallError.checksumMismatch(.ytdlp)) { try await provisioner.install(.ytdlp) }
        await #expect(throws: ToolInstallError.checksumMismatch(.deno)) { try await provisioner.install(.deno) }
        #expect(fixture.binFiles.isEmpty)
        #expect(ToolInstallError.checksumMismatch(.ytdlp).message.contains("nothing was installed"))
    }

    @Test func aMismatchLeavesAnInstalledToolExactlyAsItWas() async throws {
        let fixture = try InstallFixture()
        defer { fixture.cleanUp() }
        try await fixture.provisioner(try fixture.lock(serving: [.ytdlp: InstallFixture.program(.ytdlp, version: "1.0")])).install(.ytdlp)
        let before = try Data(contentsOf: URL(fileURLWithPath: try #require(fixture.installed(.ytdlp))))
        let wrong = String(repeating: "f", count: 64)
        let tampered = try fixture.lock(serving: [.ytdlp: InstallFixture.program(.ytdlp, version: "9.9")], claiming: [.ytdlp: wrong])
        await #expect(throws: ToolInstallError.checksumMismatch(.ytdlp)) { try await fixture.provisioner(tampered).install(.ytdlp) }
        #expect(try Data(contentsOf: URL(fileURLWithPath: try #require(fixture.installed(.ytdlp)))) == before)
        #expect(fixture.binFiles == ["yt-dlp"])
    }

    @Test func aDownloadThatIsCutOffInstallsNothing() async throws {
        let fixture = try InstallFixture()
        defer { fixture.cleanUp() }
        let lock = try fixture.lock(serving: [:])
        let url = try #require(lock.artifact(for: .ytdlp, arch: .arm64)).url
        fixture.transport.reply(url, .dropsAfter(Data("#!/bin/sh\necho 1.".utf8)))
        await #expect(throws: ToolInstallError.unreachable) { try await fixture.provisioner(lock).install(.ytdlp) }
        #expect(fixture.binFiles.isEmpty, "nothing, not even a staging folder")
        #expect(ToolInstallError.unreachable.message.contains("Homebrew"))
    }

    @Test func aFailureOnALaterToolLeavesNoStagingFolderBehind() async throws {
        let fixture = try InstallFixture()
        defer { fixture.cleanUp() }
        let lock = try fixture.lock(serving: [:])
        let url = try #require(lock.artifact(for: .deno, arch: .arm64)).url
        fixture.transport.reply(url, .fails)
        await #expect(throws: (any Error).self) { try await fixture.provisioner(lock).install([.deno, .ffmpeg]) }
        #expect(fixture.binFiles.isEmpty)
    }

    @Test func theDownloadedMarkMacOSAddsIsRemoved() async throws {
        let fixture = try InstallFixture()
        defer { fixture.cleanUp() }
        // A transport that writes its file already marked, as a browser's download would be.
        final class Marking: ToolTransport, @unchecked Sendable {
            let inner: FakeTransport
            init(_ inner: FakeTransport) { self.inner = inner }
            func data(from url: URL) async throws -> Data { try await inner.data(from: url) }
            func download(from url: URL, to file: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
                try await inner.download(from: url, to: file, progress: progress)
                let value = "0081;00000000;Safari;"
                setxattr(file.path, "com.apple.quarantine", value, value.utf8.count, 0, 0)
            }
        }
        let lock = try fixture.lock(serving: [:], zipped: [.ffmpeg, .ffprobe, .deno])
        let provisioner = ToolProvisioner(paths: fixture.paths, lock: lock, transport: Marking(fixture.transport), arch: .arm64)
        try await provisioner.install(.ytdlp)
        let path = try #require(fixture.installed(.ytdlp))
        #expect(getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) < 0)
        #expect(FileManager.default.isExecutableFile(atPath: path))
    }

    @Test func aProgramThatWillNotStartIsRefusedAndTheOldOneStays() async throws {
        let fixture = try InstallFixture()
        defer { fixture.cleanUp() }
        try await fixture.provisioner(try fixture.lock(serving: [.ytdlp: InstallFixture.program(.ytdlp, version: "1.0")])).install(.ytdlp)
        let before = try Data(contentsOf: URL(fileURLWithPath: try #require(fixture.installed(.ytdlp))))
        let broken = try fixture.lock(serving: [.ytdlp: InstallFixture.brokenProgram])
        await #expect(throws: ToolInstallError.notRunnable(.ytdlp)) { try await fixture.provisioner(broken).install(.ytdlp) }
        #expect(try Data(contentsOf: URL(fileURLWithPath: try #require(fixture.installed(.ytdlp)))) == before)
        #expect(fixture.binFiles == ["yt-dlp"])
    }

    @Test func aZipWithoutTheProgramOrWithALinkInsteadIsRefused() async throws {
        let fixture = try InstallFixture()
        defer { fixture.cleanUp() }
        var lock = try fixture.lock(serving: [:])
        // The zip holds a different file than the lock names.
        let empty = try fixture.zip(containing: ["other": InstallFixture.program(.deno, version: "1.0")])
        fixture.transport.reply("https://example.test/deno.zip", .file(empty))
        lock.tools["deno"]?.artifacts["arm64"]?.sha256 = try InstallFixture.sha256(empty)
        await #expect(throws: ToolInstallError.cannotUnpack(.deno)) { try await fixture.provisioner(lock).install(.deno) }
        // The "program" is a link to something else on the Mac.
        let linked = try fixture.zip(containing: [:], links: ["deno": "/bin/sh"])
        fixture.transport.reply("https://example.test/deno.zip", .file(linked))
        lock.tools["deno"]?.artifacts["arm64"]?.sha256 = try InstallFixture.sha256(linked)
        await #expect(throws: ToolInstallError.cannotUnpack(.deno)) { try await fixture.provisioner(lock).install(.deno) }
        // A file that is not a zip at all.
        let junk = Data("not a zip".utf8)
        fixture.transport.reply("https://example.test/deno.zip", .file(junk))
        lock.tools["deno"]?.artifacts["arm64"]?.sha256 = try InstallFixture.sha256(junk)
        await #expect(throws: ToolInstallError.cannotUnpack(.deno)) { try await fixture.provisioner(lock).install(.deno) }
        #expect(fixture.binFiles.isEmpty)
    }

    @Test func leftoversOfAnEarlierInterruptedInstallAreNotTrusted() async throws {
        let fixture = try InstallFixture()
        defer { fixture.cleanUp() }
        let stale = fixture.paths.bin.appendingPathComponent(".staging", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho planted\n".utf8).write(to: stale.appendingPathComponent("yt-dlp"))
        try await fixture.provisioner(try fixture.lock(serving: [:])).install(.ytdlp)
        #expect(fixture.binFiles == ["yt-dlp"])
        let text = try String(contentsOfFile: try #require(fixture.installed(.ytdlp)), encoding: .utf8)
        #expect(!text.contains("planted"))
    }

    @Test func theArchitectureChoosesTheFile() async throws {
        let fixture = try InstallFixture()
        defer { fixture.cleanUp() }
        var lock = try fixture.lock(serving: [:], zipped: [.ffmpeg, .ffprobe, .deno])
        let intel = InstallFixture.program(.ytdlp, version: "7.7")
        fixture.transport.reply("https://example.test/intel", .file(intel))
        lock.tools["yt-dlp"]?.artifacts["x86_64"] = ToolLock.Artifact(url: "https://example.test/intel", sha256: try InstallFixture.sha256(intel), size: intel.count, kind: .file)
        let provisioner = ToolProvisioner(paths: fixture.paths, lock: lock, transport: fixture.transport, arch: .x86_64)
        try await provisioner.install(.ytdlp)
        #expect(fixture.transport.requests == ["https://example.test/intel"])
        #expect(await ToolRegistry(managedFolder: fixture.paths.bin.path).version(of: .ytdlp) == "7.7")
    }
}

@Suite struct YtdlpUpdateTests {
    private static let api = "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest"
    private static func base(_ tag: String) -> String { "https://github.com/yt-dlp/yt-dlp/releases/download/\(tag)/" }

    private func serve(_ fixture: InstallFixture, tag: String, program: Data, sums: String? = nil) throws {
        fixture.transport.reply(Self.api, .file(Data("{\"tag_name\":\"\(tag)\"}".utf8)))
        fixture.transport.reply(Self.base(tag) + "yt-dlp_macos", .file(program))
        let line = "\(try InstallFixture.sha256(program))  yt-dlp_macos\n0000  yt-dlp.exe\n"
        fixture.transport.reply(Self.base(tag) + "SHA2-256SUMS", .file(Data((sums ?? line).utf8)))
    }

    @Test func aNewerReleaseIsDownloadedCheckedAndReplacesTheOldOne() async throws {
        let fixture = try InstallFixture()
        defer { fixture.cleanUp() }
        let provisioner = fixture.provisioner(try fixture.lock(serving: [.ytdlp: InstallFixture.program(.ytdlp, version: "2026.08.19")]))
        try await provisioner.install(.ytdlp)
        try serve(fixture, tag: "2026.10.01", program: InstallFixture.program(.ytdlp, version: "2026.10.01"))
        let outcome = try await provisioner.updateYtdlp(current: "2026.08.19")
        #expect(outcome == .updated(from: "2026.08.19", to: "2026.10.01"))
        #expect(await ToolRegistry(managedFolder: fixture.paths.bin.path).version(of: .ytdlp) == "2026.10.01")
        #expect(fixture.binFiles == ["yt-dlp"])
    }

    @Test func theNewestReleaseWhenYouHaveItDownloadsNothing() async throws {
        let fixture = try InstallFixture()
        defer { fixture.cleanUp() }
        let provisioner = fixture.provisioner(try fixture.lock(serving: [:]))
        try serve(fixture, tag: "2026.08.19", program: InstallFixture.program(.ytdlp, version: "2026.08.19"))
        #expect(try await provisioner.updateYtdlp(current: "2026.08.19") == .alreadyCurrent(version: "2026.08.19"))
        #expect(try await provisioner.updateYtdlp(current: "2026.09.30") == .alreadyCurrent(version: "2026.09.30"))
        #expect(fixture.transport.requests.allSatisfy { !$0.hasSuffix("yt-dlp_macos") })
        #expect(fixture.binFiles.isEmpty)
    }

    @Test func aFileThatDoesNotMatchTheReleasesChecksumIsNotInstalled() async throws {
        let fixture = try InstallFixture()
        defer { fixture.cleanUp() }
        let provisioner = fixture.provisioner(try fixture.lock(serving: [:]))
        let other = String(repeating: "1", count: 64)
        try serve(fixture, tag: "2026.10.01", program: InstallFixture.program(.ytdlp, version: "2026.10.01"), sums: "\(other)  yt-dlp_macos\n")
        await #expect(throws: ToolInstallError.checksumMismatch(.ytdlp)) { try await provisioner.updateYtdlp(current: "2026.08.19") }
        #expect(fixture.binFiles.isEmpty)
    }

    @Test func aReleaseWithNoChecksumForTheMacProgramIsRefused() async throws {
        let fixture = try InstallFixture()
        defer { fixture.cleanUp() }
        let provisioner = fixture.provisioner(try fixture.lock(serving: [:]))
        try serve(fixture, tag: "2026.10.01", program: InstallFixture.program(.ytdlp, version: "2026.10.01"), sums: "\(String(repeating: "2", count: 64))  yt-dlp.exe\n")
        await #expect(throws: ToolInstallError.noRelease) { try await provisioner.updateYtdlp(current: nil) }
        #expect(fixture.binFiles.isEmpty)
    }

    @Test func aStrangeTagOrNoAnswerIsRefusedBeforeAnythingIsDownloaded() async throws {
        let fixture = try InstallFixture()
        defer { fixture.cleanUp() }
        let provisioner = fixture.provisioner(try fixture.lock(serving: [:]))
        for tag in ["../../evil", "latest", "2026.10", "2026.10.01/x", ""] {
            fixture.transport.reply(Self.api, .file(Data("{\"tag_name\":\"\(tag)\"}".utf8)))
            await #expect(throws: ToolInstallError.noRelease) { try await provisioner.updateYtdlp(current: nil) }
        }
        fixture.transport.reply(Self.api, .file(Data("nonsense".utf8)))
        await #expect(throws: ToolInstallError.noRelease) { try await provisioner.updateYtdlp(current: nil) }
        fixture.transport.reply(Self.api, .fails)
        await #expect(throws: ToolInstallError.unreachable) { try await provisioner.updateYtdlp(current: nil) }
        #expect(fixture.transport.requests.allSatisfy { !$0.contains("/releases/download/") })
    }

    @Test func theChecksumListIsReadByFileName() {
        let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)
        let sums = "\(a)  yt-dlp_macos.zip\n\(b)  yt-dlp_macos\n"
        #expect(ToolProvisioner.checksum(of: "yt-dlp_macos", in: sums) == b)
        #expect(ToolProvisioner.checksum(of: "yt-dlp_macos.zip", in: sums) == a)
        #expect(ToolProvisioner.checksum(of: "yt-dlp", in: sums) == nil)
        #expect(ToolProvisioner.checksum(of: "yt-dlp_macos", in: "nothing here") == nil)
        #expect(ToolProvisioner.checksum(of: "yt-dlp_macos", in: "xyz  yt-dlp_macos") == nil)
        #expect(ToolProvisioner.isReleaseTag("2026.08.19") && ToolProvisioner.isReleaseTag("2026.08.19.1"))
        #expect(!ToolProvisioner.isReleaseTag("v2026.08.19") && !ToolProvisioner.isReleaseTag("2026.08"))
    }

    @Test func theSentencesThatOfferAnUpdateAreTheRightOnes() {
        #expect(Messages.suggestsToolUpdate(Messages.toolOutOfDate))
        #expect(Messages.suggestsToolUpdate(Messages.refused))
        #expect(!Messages.suggestsToolUpdate(Messages.membersOnly))
        #expect(!Messages.suggestsToolUpdate(""))
    }
}

@Suite struct ToolFallbackOrderTests {
    @Test func aChosenFileBeatsTheAppsOwnCopyWhichBeatsHomebrewWhichBeatsNothing() {
        let present: Set<String> = ["/custom/yt-dlp", "/managed/bin/yt-dlp", "/opt/homebrew/bin/yt-dlp", "/managed/bin/deno", "/opt/homebrew/bin/ffmpeg"]
        let registry = ToolRegistry(managedFolder: "/managed/bin", overrides: [.ytdlp: "/custom/yt-dlp"], isExecutable: { present.contains($0) })
        #expect(registry.locate(.ytdlp)?.source == .userOverride)
        #expect(registry.locate(.deno)?.source == .managed)
        #expect(registry.locate(.ffmpeg)?.source == .system)
        #expect(registry.locate(.ffprobe) == nil)
        // Taking the chosen file away falls back to the app's own copy, then to Homebrew.
        let without = ToolRegistry(managedFolder: "/managed/bin", overrides: [.ytdlp: "/custom/yt-dlp"], isExecutable: { present.subtracting(["/custom/yt-dlp"]).contains($0) })
        #expect(without.locate(.ytdlp)?.source == .managed)
        let last = ToolRegistry(managedFolder: "/managed/bin", isExecutable: { $0 == "/opt/homebrew/bin/yt-dlp" })
        #expect(last.locate(.ytdlp)?.source == .system)
    }
}
