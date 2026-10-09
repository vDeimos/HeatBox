import Foundation

/// Asking the download tool what a link is. Planning is separate from running
/// (plan Rule 2): `plan` returns the command, `interpret` reads an answer,
/// and `lookUp` does both through the one `ProcessRunner`. Nothing is
/// downloaded.
public enum Probe {
    public struct Request: Equatable, Sendable {
        public var link: String
        /// A saved sign-in (Netscape cookies file). It wins over a browser choice.
        public var cookiesFile: String?
        public var cookieBrowser: CookieBrowser
        public var proxy: String

        public init(link: String, cookiesFile: String? = nil, cookieBrowser: CookieBrowser = .none, proxy: String = "") {
            self.link = link
            self.cookiesFile = cookiesFile
            self.cookieBrowser = cookieBrowser
            self.proxy = proxy
        }
    }

    public struct Plan: Equatable, Sendable {
        public let executable: String
        public let environment: [String: String]
        public let arguments: [String]

        public var processRequest: ProcessRequest {
            ProcessRequest(executable: executable, arguments: arguments, environment: environment)
        }
    }

    /// The lookup command. Like every yt-dlp call it ignores the user's
    /// config file, uses Deno when present and puts `--` before the link
    /// (plan Rule 4). `--flat-playlist` lists a playlist without opening each
    /// video; `--no-playlist` reads a video link that also names a list as
    /// the video.
    public static func plan(_ request: Request, toolchain: YtdlpCommand.Toolchain) throws -> Plan {
        let link = request.link.trimmed
        guard Links.isWebLink(link) else { throw ProbeFailure.invalidLink(link) }
        var args = YtdlpCommand.baseArguments(toolchain)
        args += ["-J", "--flat-playlist", "--no-playlist", "--no-warnings"]
        let proxy = request.proxy.trimmed
        if !proxy.isEmpty { args += ["--proxy", proxy] }
        if let cookies = request.cookiesFile, !cookies.isEmpty {
            args += ["--cookies", cookies]
        } else if request.cookieBrowser != .none {
            args += ["--cookies-from-browser", request.cookieBrowser.rawValue]
        }
        args += ["--", link]
        return Plan(executable: toolchain.ytdlp, environment: toolchain.environment, arguments: args)
    }

    // MARK: Running

    public static func lookUp(_ request: Request, tools: ToolRegistry, runner: ProcessRunner = ProcessRunner()) async -> ProbeResult {
        guard let toolchain = YtdlpCommand.Toolchain(registry: tools) else { return .failure(.toolMissing) }
        return await lookUp(request, toolchain: toolchain, runner: runner)
    }

    /// Looks a link up and waits for the answer. Cancelling the task stops the tool.
    public static func lookUp(_ request: Request, toolchain: YtdlpCommand.Toolchain,
                              runner: ProcessRunner = ProcessRunner()) async -> ProbeResult {
        let plan: Plan
        do {
            plan = try Self.plan(request, toolchain: toolchain)
        } catch let failure as ProbeFailure {
            return .failure(failure)
        } catch {
            return .failure(.unreadable)
        }
        guard let output = try? await runner.run(plan.processRequest) else { return .failure(.toolMissing) }
        if Task.isCancelled || output.outcome.stopRequested { return .failure(.stopped) }
        return interpret(output: output.standardOutput, errors: output.standardError, link: request.link.trimmed)
    }

    // MARK: Reading the answer

    /// Reads what the tool printed. A JSON object is the answer whatever the
    /// exit status; otherwise the tool's last error says why there is none.
    public static func interpret(output: String, errors: String, link: String) -> ProbeResult {
        if let object = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any] {
            return interpret(object, link: link)
        }
        return .failure(failure(fromErrors: errors))
    }

    static func failure(fromErrors errors: String) -> ProbeFailure {
        let lines = errors.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard var line = lines.last(where: { $0.contains("ERROR:") }) ?? lines.last else { return .unreadable }
        // The tool sometimes prints the label alone and the reason on the next line.
        if line.replacingOccurrences(of: "ERROR:", with: "").trimmed.isEmpty,
           let index = lines.lastIndex(of: line), index + 1 < lines.count {
            line = lines[index + 1]
        }
        let translated = ErrorTranslator.translate(line)
        if translated.kind == .upcoming { return .upcoming }
        return ProbeFailure(kind: .tool(translated.kind), message: translated.message.isEmpty ? Messages.unreadable : translated.message)
    }

    public static func interpret(_ info: [String: Any], link: String) -> ProbeResult {
        let extractor = (info["extractor_key"] as? String) ?? ""
        // A direct link to a file is often answered from a mirror whose
        // address does not last, so for a site the tool has no name for, the
        // link that was given is the one to go by.
        let direct = extractor == "Generic"
        let domain = direct ? (host(of: link) ?? info["webpage_url_domain"] as? String) : info["webpage_url_domain"] as? String
        let site = Naming.siteName(extractorKey: extractor, domain: domain)
        let uploader = text(info["uploader"]) ?? text(info["channel"]) ?? ""

        if (info["_type"] as? String) == "playlist" || info["entries"] != nil {
            let entries = ((info["entries"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }.map { entry in
                PlaylistEntry(id: text(entry["id"]) ?? "",
                              title: text(entry["title"]) ?? text(entry["url"]) ?? Messages.untitled,
                              link: text(entry["url"]).flatMap { Links.isWebLink($0) ? $0 : nil },
                              seconds: number(entry["duration"]))
            }
            let listed = ((info["entries"] as? [Any]) ?? []).count
            let count = max(listed, Int(number(info["playlist_count"]) ?? 0))
            if count == 0 { return .failure(.emptyPage) }
            return .playlist(PlaylistFacts(title: text(info["title"]) ?? Messages.untitledPlaylist, uploader: uploader,
                                           site: site, count: count, link: webLink(info["webpage_url"]) ?? link,
                                           entries: entries))
        }

        let liveStatus = (info["live_status"] as? String) ?? ""
        if liveStatus == "is_live" || (info["is_live"] as? Bool) == true { return .failure(.live) }
        if liveStatus == "is_upcoming" { return .failure(.upcoming) }

        let rawChapters = ((info["chapters"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }
        let chapters: [MediaChapter] = rawChapters.compactMap { chapter in
            guard let start = number(chapter["start_time"]) else { return nil }
            return MediaChapter(start: start, end: number(chapter["end_time"]), title: text(chapter["title"]) ?? "")
        }
        let formats = ((info["formats"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }.compactMap(MediaFormat.init)

        let seconds = number(info["duration"]) ?? 0
        let duration = text(info["duration_string"]) ?? (seconds > 0 ? TimeText.clock(seconds.rounded()) : "")
        let address = direct ? link : (webLink(info["webpage_url"]) ?? link)
        return .video(MediaFacts(
            facts: VideoFacts(id: text(info["id"]) ?? "", title: text(info["title"]) ?? Messages.untitled,
                              uploader: uploader, uploadDate: text(info["upload_date"])),
            site: site, link: address, seconds: seconds, duration: duration,
            thumbnail: webLink(info["thumbnail"]).flatMap { URL(string: $0) },
            chapters: chapters, formats: formats))
    }

    // MARK: Helpers

    /// A JSON number, and not `true` or `false` (which Foundation also reads as numbers).
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    private static func text(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    /// "example.org" for "https://www.example.org/a".
    private static func host(of link: String) -> String? {
        guard Links.isWebLink(link), let host = URLComponents(string: link)?.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func webLink(_ value: Any?) -> String? {
        text(value).flatMap { Links.isWebLink($0) ? $0 : nil }
    }
}
