import Foundation
import Testing
@testable import Engine

private func scratch() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString.prefix(8))", isDirectory: true)
}

private func held(_ claim: InstanceLock.Claim) -> InstanceLock? {
    if case .held(let lock) = claim { return lock }
    return nil
}

private func taken(_ claim: InstanceLock.Claim) -> Bool {
    if case .taken = claim { return true }
    return false
}

@Suite struct InstanceLockTests {
    @Test func theFirstCopyGetsTheFolderAndTheSecondDoesNot() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try #require(held(InstanceLock.claim(root)))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".lock").path))
        #expect(taken(InstanceLock.claim(root)))
        #expect(taken(InstanceLock.claim(root)))
        first.release()
    }

    @Test func theFolderIsFreeAgainWhenTheCopyLetsGo() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try #require(held(InstanceLock.claim(root)))
        first.release()
        first.release()
        let second = try #require(held(InstanceLock.claim(root)))
        #expect(taken(InstanceLock.claim(root)))
        second.release()
    }

    @Test func aLockThatIsForgottenLetsGoByItself() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let short = try #require(held(InstanceLock.claim(root)))
            _ = short
        }
        #expect(held(InstanceLock.claim(root)) != nil)
    }

    @Test func twoDataFoldersDoNotGetInEachOthersWay() throws {
        let one = scratch()
        let two = scratch()
        defer {
            try? FileManager.default.removeItem(at: one)
            try? FileManager.default.removeItem(at: two)
        }
        let first = try #require(held(InstanceLock.claim(one)))
        let second = try #require(held(InstanceLock.claim(two)))
        first.release()
        second.release()
    }

    @Test func aFolderThatCannotBeWrittenIsNoReasonToRefuse() throws {
        let root = scratch()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o500])
        if case .unavailable = InstanceLock.claim(root) {} else { Issue.record("expected the lock to be unavailable") }
    }

    // A tool the app started must not keep the folder locked after the app is gone.
    @Test func aStartedProgramDoesNotInheritTheLock() async throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try #require(held(InstanceLock.claim(root)))
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { sleeper.terminate() }
        first.release()
        #expect(held(InstanceLock.claim(root)) != nil)
    }
}
