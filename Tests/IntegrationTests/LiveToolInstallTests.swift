import Foundation
import Testing
@testable import Engine

/// The one test that uses the real internet: it installs the pinned tools
/// from their real addresses into a scratch folder, checks each against the
/// lock and runs it. Opt-in (plan Section 5, "Live"): `LIVE_TOOLS=1 scripts/test.sh --filter LiveToolInstall`.
@Suite struct LiveToolInstallTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVE_TOOLS"] == "1"))
    func thePinnedToolsInstallFromTheirRealAddressesAndRun() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("live-tools-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let provisioner = ToolProvisioner(paths: paths)
        try await provisioner.install(Tool.allCases)
        let registry = ToolRegistry(managedFolder: paths.bin.path)
        for tool in Tool.allCases {
            #expect(registry.locate(tool)?.source == .managed, "\(tool.rawValue)")
            #expect(await registry.version(of: tool) == ToolLock.bundled.version(of: tool), "\(tool.rawValue)")
        }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: paths.bin.path)) ?? []).sorted() == ["deno", "ffmpeg", "ffprobe", "yt-dlp"])
        // The update check against the real release list: the pinned version is never "newer than itself".
        let outcome = try await provisioner.updateYtdlp(current: "9999.01.01")
        #expect(outcome == .alreadyCurrent(version: "9999.01.01"))
    }
}
