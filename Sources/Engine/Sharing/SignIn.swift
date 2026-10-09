import Foundation

/// A saved YouTube sign-in (Phobos): the YouTube and Google entries of one
/// browser's cookies, copied once, when the person asks, into a private file
/// of the app's own. Nothing reads a browser at any other time.
public enum SignIn {
    /// The browsers offered in Settings.
    public static let browsers: [CookieBrowser] = [.firefox, .chrome, .safari, .brave, .edge]

    /// The page asked for while the browser's cookies are read. Nothing is downloaded.
    static let probeLink = "https://www.youtube.com/watch?v=jNQXAC9IVRw"

    /// Keeps only YouTube and Google entries from a browser's cookie list, so
    /// nothing from other websites is saved.
    public static func keepYouTubeAndGoogle(_ text: String) -> String {
        var kept: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let row = String(line)
            if row.hasPrefix("# ") {
                kept.append(row)
                continue
            }
            var domain = row.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            if domain.hasPrefix("#HttpOnly_") { domain.removeFirst("#HttpOnly_".count) }
            if domain.hasPrefix(".") { domain.removeFirst() }
            domain = domain.lowercased()
            if ["youtube.com", "google.com"].contains(where: { domain == $0 || domain.hasSuffix("." + $0) }) {
                kept.append(row)
            }
        }
        return kept.joined(separator: "\n") + "\n"
    }

    /// The command that writes a browser's cookies to `jar` (plan Rule 4).
    public static func captureArguments(browser: CookieBrowser, jar: String, toolchain: YtdlpCommand.Toolchain) -> [String] {
        YtdlpCommand.baseArguments(toolchain)
            + ["--cookies-from-browser", browser.rawValue, "--cookies", jar, "--simulate", "--print", "title", "--", probeLink]
    }

    /// Copies the browser's YouTube sign-in into `destination`, readable only
    /// by the person. Nil on success, or one sentence saying what went wrong.
    public static func capture(browser: CookieBrowser, to destination: URL, tools: ToolRegistry,
                               runner: ProcessRunner = ProcessRunner()) async -> String? {
        guard browsers.contains(browser) else { return Messages.signInChooseBrowser }
        guard let toolchain = YtdlpCommand.Toolchain(registry: tools) else { return Messages.noTool }
        let fm = FileManager.default
        let folder = destination.deletingLastPathComponent()
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Every site's cookies pass through this file for a moment. It is the
        // app's own, made here, private, and removed whatever happens.
        let jar = folder.appendingPathComponent(".cookies-all-\(UUID().uuidString).tmp")
        fm.createFile(atPath: jar.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? fm.removeItem(at: jar) }
        let request = ProcessRequest(executable: toolchain.ytdlp, arguments: captureArguments(browser: browser, jar: jar.path, toolchain: toolchain),
                                     environment: toolchain.environment)
        let ran = try? await runner.run(request)
        guard let ran, ran.outcome.succeeded, let raw = try? String(contentsOf: jar, encoding: .utf8) else {
            return Messages.signInFailure(ran?.standardError ?? "")
        }
        let kept = keepYouTubeAndGoogle(raw)
        guard kept.split(separator: "\n").contains(where: { !$0.hasPrefix("# ") }) else { return Messages.signInNotFound }
        do {
            try Data(kept.utf8).write(to: destination, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            return Messages.signInCannotSave
        }
        return nil
    }

    /// The saved sign-in to hand the download tool: only when the person
    /// switched it on and one has been saved.
    public static func file(for settings: AppSettings, paths: AppPaths) -> String? {
        guard settings.useSignIn, FileManager.default.fileExists(atPath: paths.signInFile.path) else { return nil }
        return paths.signInFile.path
    }

    /// When the sign-in was last saved; nil when there is none.
    public static func savedDate(paths: AppPaths) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: paths.signInFile.path))?[.modificationDate] as? Date
    }
}
