import Foundation
import Testing
@testable import Engine

@Suite struct AppPathsTests {
    @Test func theStandardRootIsTheAppsOwnSupportFolder() {
        let root = AppPaths.standard().root.path
        #expect(root.hasSuffix("/Library/Application Support/\(Engine.supportFolderName)"))
    }

    @Test func everythingLivesUnderTheRoot() {
        let paths = AppPaths(root: URL(fileURLWithPath: "/r"))
        #expect(paths.bin.path == "/r/bin")
        #expect(paths.jobs.path == "/r/jobs")
        #expect(paths.thumbnails.path == "/r/thumbnails")
        #expect(paths.settingsFile.path == "/r/settings.json")
        #expect(paths.presetsFile.path == "/r/presets.json")
        #expect(paths.queueFile.path == "/r/queue.json")
        #expect(paths.libraryDatabase.path == "/r/library.sqlite")
        #expect(paths.transcriptsDatabase.path == "/r/transcripts.sqlite")
    }

    @Test func aJobsWorkspaceIsNamedByItsIdentifier() throws {
        let paths = AppPaths(root: URL(fileURLWithPath: "/r"))
        let id = try #require(UUID(uuidString: "0A1B2C3D-0000-4000-8000-000000000001"))
        #expect(paths.workspace(forJob: id).path == "/r/jobs/0a1b2c3d-0000-4000-8000-000000000001")
    }

    @Test func foldersAreCreatedPrivate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        try paths.createFolders()
        try paths.createFolders()
        for folder in [paths.root, paths.bin, paths.jobs, paths.thumbnails] {
            let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
            #expect(attributes[.type] as? FileAttributeType == .typeDirectory)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        }
    }
}
