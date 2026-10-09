import Foundation
import Testing
@testable import Engine

/// Collects lines from the runner's queue.
private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ProcessLine] = []

    func add(_ line: ProcessLine) {
        lock.lock()
        stored.append(line)
        lock.unlock()
    }

    var all: [ProcessLine] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func text(_ source: OutputSource) -> [String] {
        all.filter { $0.source == source }.map(\.text)
    }
}

private let environment = ToolRegistry(managedFolder: "/nonexistent/bin").environment()

/// The tests use `/bin/sh` only as a stand-in for a tool that misbehaves.
/// Product code never runs a shell.
private func request(_ executable: String, _ arguments: [String]) -> ProcessRequest {
    ProcessRequest(executable: executable, arguments: arguments, environment: environment)
}

@Suite struct ProcessRunnerTests {
    @Test func linesAreSplitOnCarriageReturnsToo() async throws {
        let lines = Lines()
        let running = try ProcessRunner().start(request("/usr/bin/printf", ["10%%\\r20%%\\rdone\\nlast"])) { lines.add($0) }
        let outcome = await running.waitUntilExit()
        #expect(outcome.succeeded)
        #expect(lines.text(.standardOutput) == ["10%", "20%", "done", "last"])
    }

    @Test func allOutputIsDeliveredBeforeTheExitIsReported() async throws {
        let lines = Lines()
        let script = "i=0; while [ $i -lt 20000 ]; do i=$((i+1)); echo $i; done; echo tail >&2; printf unfinished"
        let running = try ProcessRunner().start(request("/bin/sh", ["-c", script])) { lines.add($0) }
        let outcome = await running.waitUntilExit()
        // Read once, straight after the exit: nothing may arrive later.
        let out = lines.text(.standardOutput)
        #expect(outcome.succeeded)
        #expect(out.count == 20001)
        #expect(out.first == "1")
        #expect(out[19999] == "20000")
        #expect(out.last == "unfinished")
        #expect(lines.text(.standardError) == ["tail"])
    }

    @Test func standardOutputAndErrorAreKeptApart() async throws {
        let result = try await ProcessRunner().run(request("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"]))
        #expect(result.standardOutput == "out")
        #expect(result.standardError == "err")
        #expect(result.outcome.status == 3)
        #expect(!result.outcome.signalled)
        #expect(!result.outcome.succeeded)
        #expect(!result.outcome.stopRequested)
    }

    @Test func theInheritedPathAndEnvironmentAreIgnored() async throws {
        setenv("SXP_TEST_INHERITED", "leak", 1)
        defer { unsetenv("SXP_TEST_INHERITED") }
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let result = try await ProcessRunner().run(request("/usr/bin/env", []))
        let seen = result.standardOutput.split(separator: "\n").map(String.init)
        #expect(seen.contains("PATH=/nonexistent/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"))
        #expect(!seen.contains { $0.hasPrefix("SXP_TEST_INHERITED") })
        #expect(!inherited.isEmpty)
        #expect(!seen.contains("PATH=\(inherited)"))
    }

    @Test func standardInputIsClosed() async throws {
        // `cat` would wait for ever on an open keyboard; with stdin closed it ends at once.
        let result = try await ProcessRunner().run(request("/bin/cat", []))
        #expect(result.outcome.succeeded)
        #expect(result.standardOutput.isEmpty)
    }

    @Test func argumentsAreNeverReadByAShell() async throws {
        let odd = "$(echo no); `echo no` && rm -rf ~ 'quoted' \"double\" *"
        let result = try await ProcessRunner().run(request("/bin/echo", [odd]))
        #expect(result.standardOutput == odd)
    }

    @Test func aToolMustBeAnAbsolutePath() {
        #expect(throws: ProcessError.executableNotAbsolute("yt-dlp")) {
            _ = try ProcessRunner().start(request("yt-dlp", [])) { _ in }
        }
    }

    @Test func aToolThatCannotStartIsAnError() {
        #expect(throws: ProcessError.self) {
            _ = try ProcessRunner().start(request("/nonexistent/tool", [])) { _ in }
        }
    }

    @Test func stopInterruptsAWellBehavedTool() async throws {
        let lines = Lines()
        let running = try ProcessRunner(stopGrace: 5).start(request("/bin/sleep", ["60"])) { lines.add($0) }
        let started = Date()
        running.stop()
        let outcome = await running.waitUntilExit()
        #expect(outcome.signalled)
        #expect(outcome.status == SIGINT)
        #expect(outcome.stopRequested)
        #expect(Date().timeIntervalSince(started) < 4)
    }

    @Test func stopEscalatesToKillWhenInterruptAndTerminateAreIgnored() async throws {
        let lines = Lines()
        let script = "trap '' INT TERM; echo ready; while :; do /bin/sleep 0.1; done"
        let running = try ProcessRunner(stopGrace: 0.4, drainTimeout: 1).start(request("/bin/sh", ["-c", script])) { lines.add($0) }
        // Wait until the traps are in place.
        for _ in 0..<200 where lines.text(.standardOutput).isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(lines.text(.standardOutput) == ["ready"])
        let started = Date()
        running.stop()
        running.stop()
        let outcome = await running.waitUntilExit()
        let elapsed = Date().timeIntervalSince(started)
        #expect(outcome.signalled)
        #expect(outcome.status == SIGKILL)
        #expect(outcome.stopRequested)
        // Two grace periods pass before the kill; it must not come sooner.
        #expect(elapsed >= 0.8)
        #expect(elapsed < 6)
        #expect(!running.isRunning)
    }

    @Test func aChildLeftHoldingThePipeDoesNotHangTheRunner() async throws {
        let lines = Lines()
        let started = Date()
        let running = try ProcessRunner(drainTimeout: 0.5).start(request("/bin/sh", ["-c", "/bin/sleep 6 & echo parent done"])) { lines.add($0) }
        let outcome = await running.waitUntilExit()
        #expect(outcome.succeeded)
        #expect(lines.text(.standardOutput) == ["parent done"])
        #expect(Date().timeIntervalSince(started) < 4)
    }

    @Test func cancellingTheTaskStopsTheTool() async throws {
        let task = Task { try await ProcessRunner(stopGrace: 1).run(request("/bin/sleep", ["60"])) }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        let result = try await task.value
        #expect(result.outcome.signalled)
        #expect(result.outcome.stopRequested)
    }

    @Test func aWorkingFolderIsHonoured() async throws {
        var folderRequest = request("/bin/pwd", [])
        folderRequest.workingDirectory = "/usr"
        let result = try await ProcessRunner().run(folderRequest)
        #expect(result.standardOutput == "/usr")
    }

    // MARK: A process group of its own

    @Test func stoppingAToolAlsoStopsWhatItStarted() async throws {
        let lines = Lines()
        // The child ignores the polite signals, as FFmpeg does while it finishes a file.
        let script = "/bin/sh -c 'trap \"\" INT TERM; while :; do /bin/sleep 0.1; done' & echo $!; wait"
        let running = try ProcessRunner(stopGrace: 0.3, drainTimeout: 1).start(request("/bin/sh", ["-c", script])) { lines.add($0) }
        for _ in 0..<200 where lines.text(.standardOutput).isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let child = try #require(Int32(lines.text(.standardOutput).first ?? ""))
        #expect(kill(child, 0) == 0)
        #expect(getpgid(child) == running.processIdentifier)
        #expect(getpgid(child) != getpgrp())

        running.stop()
        let outcome = await running.waitUntilExit()
        #expect(outcome.stopRequested)
        // Gone by the time the exit is reported, not some time later.
        #expect(ProcessIdentity.of(child) == nil)
    }

    @Test func aToolThatEndsByItselfLeavesNothingRunning() async throws {
        let result = try await ProcessRunner().run(request("/bin/sh", ["-c", "/bin/sleep 30 & echo $!"]))
        #expect(result.outcome.succeeded)
        let child = try #require(Int32(result.standardOutput))
        #expect(ProcessIdentity.of(child) == nil)
    }

    @Test func aToolStartsWithOrdinarySignalHandlingWhateverTheAppIgnores() async throws {
        // A program started with the interrupt signal ignored would never stop politely.
        let previous = signal(SIGINT, SIG_IGN)
        defer { signal(SIGINT, previous) }
        let running = try ProcessRunner(stopGrace: 5).start(request("/bin/sleep", ["60"])) { _ in }
        let started = Date()
        running.stop()
        let outcome = await running.waitUntilExit()
        #expect(outcome.signalled && outcome.status == SIGINT)
        #expect(Date().timeIntervalSince(started) < 4)
    }

    @Test func aStartedToolCanCutLongLinesShort() async throws {
        let lines = Lines()
        let running = try ProcessRunner().start(request("/usr/bin/printf", ["%s\\n%s\\n", String(repeating: "a", count: 50), "short"]),
                                                maxLineLength: 20) { lines.add($0) }
        _ = await running.waitUntilExit()
        #expect(lines.text(.standardOutput) == [String(repeating: "a", count: 20) + "…", "short"])
    }

    @Test func noFileOfTheAppsIsLeftOpenInTheTool() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("runner-fd-\(UUID().uuidString.prefix(8))")
        FileManager.default.createFile(atPath: scratch.path, contents: Data("secret".utf8))
        defer { try? FileManager.default.removeItem(at: scratch) }
        let handle = try FileHandle(forReadingFrom: scratch)
        defer { try? handle.close() }
        // The tool sees its three standard streams and whatever `ls` opens for itself, nothing inherited.
        let result = try await ProcessRunner().run(request("/bin/ls", ["/dev/fd"]))
        let open = result.standardOutput.split(separator: "\n").compactMap { Int32($0) }
        #expect(!open.contains(handle.fileDescriptor), "\(open)")
        #expect(open.contains(0) && open.contains(1) && open.contains(2))
    }

    @Test func aRunningProcessCanBeToldApartFromALaterOneWithItsNumber() async throws {
        let running = try ProcessRunner(stopGrace: 0.2).start(request("/bin/sleep", ["60"])) { _ in }
        let identity = try #require(ProcessIdentity.of(running.processIdentifier))
        #expect(identity.isStillRunning)
        #expect(!ProcessIdentity(pid: identity.pid, startedAt: identity.startedAt - 100).isStillRunning)
        #expect(!ProcessIdentity(pid: identity.pid, startedAt: identity.startedAt - 100).stopGroup())
        #expect(running.isRunning)
        // Stopping by identity, as the app does at launch for a tool left behind: asked first, so it can save its work.
        #expect(identity.stopGroup())
        let outcome = await running.waitUntilExit()
        #expect(outcome.signalled && outcome.status == SIGINT)
        #expect(!identity.isStillRunning)
        #expect(ProcessIdentity.of(0) == nil)
    }

    @Test func aLeftoverToolThatWillNotGoIsMadeToWithItsChildren() async throws {
        let lines = Lines()
        let script = "trap '' INT TERM; /bin/sleep 60 & echo $!; while :; do /bin/sleep 0.1; done"
        let running = try ProcessRunner(stopGrace: 30).start(request("/bin/sh", ["-c", script])) { lines.add($0) }
        for _ in 0..<200 where lines.text(.standardOutput).isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let child = try #require(Int32(lines.text(.standardOutput).first ?? ""))
        let identity = try #require(ProcessIdentity.of(running.processIdentifier))
        let started = Date()
        #expect(identity.stopGroup(grace: 0.3))
        let outcome = await running.waitUntilExit()
        #expect(outcome.signalled && outcome.status == SIGKILL)
        #expect(Date().timeIntervalSince(started) >= 0.3)
        #expect(ProcessIdentity.of(child) == nil)
    }
}
