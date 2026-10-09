import Foundation

/// Builds the one yt-dlp command for a recipe (plan Rule 2: planning is
/// separate from running; this returns a value and runs nothing).
///
/// Every command carries `--ignore-config`, `--js-runtimes deno:<path>` when
/// Deno is present, and `--` before the links (plan Rule 4). Links must be
/// `http` or `https`. The arguments split in two: the *internal* ones are
/// the app's own bookkeeping (progress lines, where finished files and
/// chapters are written, the job's scratch folder) and the *visible* ones are
/// everything that decides what is downloaded. `DisplayCommand` shows only
/// the visible ones, so the preview always equals what runs.
public enum YtdlpCommand {
    /// Starts every progress line, so the line reader can tell them from log lines.
    public static let progressPrefix = "[[PROG]]"

    /// percent|speed|eta|total|estimate|playlist item|playlist size|title.
    /// The title is last because it may contain the separator.
    public static let progressTemplate = "download:" + progressPrefix
        + "%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s"
        + "|%(progress._total_bytes_str)s|%(progress._total_bytes_estimate_str)s"
        + "|%(info.playlist_index)s|%(info.n_entries)s|%(info.title)s"

    /// What one command is asked to do.
    public struct Request: Equatable, Sendable {
        public var recipe: DownloadRecipe
        public var links: [String]
        /// Where finished files go, already decided by `FolderRules`.
        public var folder: String
        /// The download-archive file, for a recipe that skips videos it already has.
        public var archiveFile: String?
        /// A saved sign-in (Netscape cookies file). It wins over a browser choice in the recipe.
        public var cookiesFile: String?
        /// The job's scratch folder, used as yt-dlp's temporary folder (plan Rule 5).
        public var workspace: String?
        /// A file that receives the final path of every finished download.
        public var outputListFile: String?
        /// A file that receives each finished download's path and chapter list.
        public var chaptersFile: String?
        /// The video's details, prepared by the app (chapters from comments).
        /// The tool downloads from these and passes the links over.
        public var infoFile: String?
        /// A file that receives what the Library records about each finished download.
        public var notesFile: String?
        /// A folder that receives each video's picture, for the Library.
        public var thumbnailFolder: String?

        public init(recipe: DownloadRecipe, links: [String], folder: String, archiveFile: String? = nil,
                    cookiesFile: String? = nil, workspace: String? = nil, outputListFile: String? = nil,
                    chaptersFile: String? = nil, infoFile: String? = nil, notesFile: String? = nil,
                    thumbnailFolder: String? = nil) {
            self.recipe = recipe
            self.links = links
            self.folder = folder
            self.archiveFile = archiveFile
            self.cookiesFile = cookiesFile
            self.workspace = workspace
            self.outputListFile = outputListFile
            self.chaptersFile = chaptersFile
            self.infoFile = infoFile
            self.notesFile = notesFile
            self.thumbnailFolder = thumbnailFolder
        }
    }

    /// The tools one command uses and the environment they run in.
    public struct Toolchain: Equatable, Sendable {
        public var ytdlp: String
        public var ffmpeg: String?
        public var deno: String?
        public var environment: [String: String]

        public init(ytdlp: String, ffmpeg: String? = nil, deno: String? = nil, environment: [String: String]) {
            self.ytdlp = ytdlp
            self.ffmpeg = ffmpeg
            self.deno = deno
            self.environment = environment
        }

        /// Taken from the registry; nil when yt-dlp itself is missing.
        public init?(registry: ToolRegistry) {
            guard let ytdlp = registry.path(.ytdlp) else { return nil }
            self.init(ytdlp: ytdlp, ffmpeg: registry.path(.ffmpeg), deno: registry.path(.deno),
                      environment: registry.environment())
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        case toolMissing
        case noLinks
        case invalidLink(String)
        case invalidRecipe([RecipeIssue])
        case archiveNeeded

        /// One plain sentence with a next step.
        public var message: String {
            switch self {
            case .toolMissing: return Messages.noTool
            case .noLinks: return Messages.commandNoLinks
            case .invalidLink(let link): return Messages.commandInvalidLink(link)
            case .invalidRecipe(let issues): return issues.first?.message ?? Messages.unreadable
            case .archiveNeeded: return Messages.recipeArchiveNeeded
            }
        }
    }

    public struct Plan: Equatable, Sendable {
        public let executable: String
        public let environment: [String: String]
        /// The app's bookkeeping arguments. Never shown in a copied command.
        public let internalArguments: [String]
        /// Everything that decides what is downloaded, ending in `--` and the links.
        public let visibleArguments: [String]
        /// Warnings from the validator; none of them stops the download.
        public let warnings: [RecipeIssue]
        /// Things the preview cannot reproduce on its own.
        public let notes: [String]

        /// The exact arguments that are run.
        public var arguments: [String] { internalArguments + visibleArguments }

        public var processRequest: ProcessRequest {
            ProcessRequest(executable: executable, arguments: arguments, environment: environment)
        }

        /// The command to show and copy.
        public var displayCommand: String { DisplayCommand.string(for: self) }
    }

    public static func plan(_ request: Request, tools: ToolRegistry) throws -> Plan {
        guard let toolchain = Toolchain(registry: tools) else { throw Failure.toolMissing }
        return try plan(request, toolchain: toolchain)
    }

    public static func plan(_ request: Request, toolchain: Toolchain) throws -> Plan {
        guard !request.links.isEmpty else { throw Failure.noLinks }
        if let bad = request.links.first(where: { !Links.isWebLink($0) }) { throw Failure.invalidLink(bad) }
        let issues = RecipeValidator.validate(request.recipe)
        let errors = issues.filter { $0.severity == .error }
        guard errors.isEmpty else { throw Failure.invalidRecipe(errors) }
        let recipe = request.recipe
        if recipe.useArchive && (request.archiveFile?.isEmpty ?? true) { throw Failure.archiveNeeded }

        var notes: [String] = []
        if recipe.chapterSource != .youtube { notes.append(Messages.commentChapters) }
        return Plan(executable: toolchain.ytdlp,
                    environment: toolchain.environment,
                    internalArguments: internalArguments(for: request),
                    visibleArguments: visibleArguments(for: request, toolchain: toolchain),
                    warnings: issues.filter { issue in
                        // A saved sign-in wins, so the browser choice is not used and needs no warning.
                        issue.severity == .warning && !(issue.field == "cookieBrowser" && request.cookiesFile?.isEmpty == false)
                    },
                    notes: notes)
    }

    /// What every yt-dlp call starts with, a lookup included (plan Rule 4):
    /// no config file from the user's machine, and Deno when it is present.
    static func baseArguments(_ toolchain: Toolchain) -> [String] {
        var args = ["--ignore-config"]
        if let deno = toolchain.deno { args += ["--js-runtimes", "deno:\(deno)"] }
        return args
    }

    // MARK: Internal arguments

    private static func internalArguments(for request: Request) -> [String] {
        var args = ["--newline", "--no-colors", "--progress", "--progress-template", progressTemplate]
        // Chapter titles and the split files' paths, so each split track can be
        // tagged afterwards. Written before the list of finished files, so the
        // chapters are already there when a finished file is noticed.
        if let file = request.chaptersFile { args += ["--print-to-file", ChapterTagger.recordTemplate, file] }
        // What the Library records about a finished video; also written first.
        if let file = request.notesFile { args += ["--print-to-file", DownloadNote.template, file] }
        if let file = request.outputListFile { args += ["--print-to-file", "after_move:filepath", file] }
        // Private scratch space per job, so two jobs that resolve to the same
        // file name cannot overwrite each other's partial files.
        if let workspace = request.workspace { args += ["-P", "temp:\(workspace)"] }
        // Details the app prepared. The tool then downloads from them and
        // ignores the links, which stay in the command for the preview.
        if let file = request.infoFile { args += ["--no-clean-info-json", "--load-info-json", file] }
        // The video's picture for the Library, kept in the job's own folder
        // and named by the video's id; a list's own picture is not wanted. A
        // recipe that saves the picture beside the video decides where it
        // goes itself, and the Library takes a copy of that one.
        if let folder = request.thumbnailFolder, !request.recipe.writeThumbnail {
            args += ["--write-thumbnail", "-o", "thumbnail:\(folder)/%(id)s.%(ext)s", "-o", "pl_thumbnail:"]
        }
        return args
    }

    // MARK: Visible arguments

    private static func visibleArguments(for request: Request, toolchain: Toolchain) -> [String] {
        let r = request.recipe
        var a = baseArguments(toolchain)
        if let ffmpeg = toolchain.ffmpeg { a += ["--ffmpeg-location", ffmpeg] }

        // Format
        let custom = r.customFormat.trimmed
        switch r.mode {
        case .audio:
            a += ["-f", custom.isEmpty ? "ba/b" : custom]
            if let sort = sortString(r) { a += ["-S", sort] }
            a += ["-x", "--audio-format", r.audioFormat.rawValue]
            if !r.audioFormat.isLossless, r.audioFormat != .best, let quality = r.audioQuality.argument { a += ["--audio-quality", quality] }
            let filters = audioFilterArguments(r)
            if !filters.isEmpty && r.audioFormat != .best {
                a += ["--postprocessor-args", "ExtractAudio+ffmpeg_o:" + filters.joined(separator: " ")]
            }
        case .video, .videoOnly:
            if !custom.isEmpty {
                a += ["-f", custom]
            } else if r.mode == .videoOnly {
                // Falls back to the combined stream on sites that offer no separate video track.
                a += ["-f", "bv/bv*"]
            }
            if let sort = sortString(r) { a += ["-S", sort] }
            if r.mode == .video && r.container != .automatic { a += ["--merge-output-format", r.container.rawValue] }
            if r.forceRemux, let rule = r.container.remuxRule { a += ["--remux-video", rule] }
            if r.remuxesToMKVForCover { a += ["--remux-video", "mkv"] }
            if r.preferFreeFormats { a.append("--prefer-free-formats") }
        }
        if r.keepIntermediateFiles { a.append("-k") }

        // Part of a video
        if let clip = r.clip {
            let end = clip.end.map(TimeText.clock) ?? "inf"
            a += ["--download-sections", "*\(TimeText.clock(clip.start))-\(end)"]
        }
        if r.forcesKeyframes { a.append("--force-keyframes-at-cuts") }

        // Chapters
        if r.embedChapters { a.append("--embed-chapters") }
        if r.splitChapters {
            a.append("--split-chapters")
            // Ogg cannot hold a picture stream, so splitting a file that already
            // has cover art fails. Drop the picture while splitting; it is added back per track.
            if r.mode == .audio && r.embedThumbnail && r.audioFormat.isOggFamily {
                a += ["--postprocessor-args", "SplitChapters+ffmpeg_o:-map -0:v?"]
            }
        }
        if !r.removeChaptersPattern.trimmed.isEmpty { a += ["--remove-chapters", r.removeChaptersPattern.trimmed] }

        // SponsorBlock
        switch r.sponsorBlock {
        case .off: break
        case .mark:
            a += ["--sponsorblock-mark", r.sponsorCategories.map(\.rawValue).joined(separator: ",")]
        case .remove:
            a += ["--sponsorblock-remove", r.sponsorCategories.filter(\.removable).map(\.rawValue).joined(separator: ",")]
        }

        // Subtitles
        if r.writeSubtitles { a.append("--write-subs") }
        if r.writeAutoSubtitles { a.append("--write-auto-subs") }
        if r.writeSubtitles || r.writeAutoSubtitles || r.embedSubtitles {
            a += ["--sub-langs", r.subtitleLanguages.trimmed]
            if r.subtitleFormat != .best {
                a += ["--sub-format", "\(r.subtitleFormat.rawValue)/best", "--convert-subs", r.subtitleFormat.rawValue]
            }
            if r.subtitleSleep > 0 { a += ["--sleep-subtitles", "\(r.subtitleSleep)"] }
        }
        if r.embedSubtitles && r.mode != .audio {
            a.append("--embed-subs")
            // The tool's own switch for not leaving the loose files behind.
            if !r.keepSubtitleFiles { a += ["--compat-options", "no-keep-subs"] }
        }

        // Metadata and thumbnails
        if r.embedMetadata {
            a.append("--embed-metadata")
            a += MusicTags.arguments(for: r)
            var metadata: [String] = []
            // Ogg keeps tags per stream; stale tags from the source would override the new ones.
            if r.mode == .audio { metadata += ["-map_metadata:s:a", "-1"] }
            if r.musicTagsActive && !r.genre.trimmed.isEmpty { metadata += ["-metadata", "genre=\(r.genre.trimmed)"] }
            if !metadata.isEmpty {
                a += ["--postprocessor-args", "Metadata+ffmpeg_o:" + metadata.map(DisplayCommand.shellQuote).joined(separator: " ")]
            }
        }
        let embedsCover = r.embedThumbnail && r.thumbnailEmbeddable
        if embedsCover { a.append("--embed-thumbnail") }
        if r.writeThumbnail { a.append("--write-thumbnail") }
        if r.musicTagsActive && r.squareCover && r.mode == .audio && (embedsCover || r.writeThumbnail) {
            // Crop the 16:9 video picture to a centred square, like a real album cover.
            // JPEG sources become PNG because yt-dlp skips conversion when the format already matches.
            a += ["--convert-thumbnails", "jpg>png/jpg",
                  "--postprocessor-args", "ThumbnailsConvertor+ffmpeg_o:-q:v 2 -vf crop=\"'min(iw,ih)':'min(iw,ih)'\""]
        } else if r.thumbnailFormat != .original && (r.writeThumbnail || embedsCover) {
            a += ["--convert-thumbnails", r.thumbnailFormat.rawValue]
        }
        if r.writeDescription { a.append("--write-description") }
        if r.writeInfoJSON { a.append("--write-info-json") }
        if r.writeComments { a.append("--write-comments") }

        // Playlist
        switch r.playlistMode {
        case .auto: break
        case .single: a.append("--no-playlist")
        case .full: a.append("--yes-playlist")
        }
        if r.continueOnErrors { a.append("--ignore-errors") }
        let items = r.playlistItems.trimmed
        if !items.isEmpty { a += ["-I", items] }
        if r.useArchive, let archive = request.archiveFile { a += ["--download-archive", archive] }

        // Network
        let rate = r.rateLimit.trimmed
        if !rate.isEmpty { a += ["--limit-rate", rate] }
        if r.concurrentFragments > 1 { a += ["-N", "\(r.concurrentFragments)"] }
        if r.retries != 10 { a += ["-R", "\(r.retries)"] }
        let proxy = r.proxy.trimmed
        if !proxy.isEmpty { a += ["--proxy", proxy] }
        if let cookies = request.cookiesFile, !cookies.isEmpty {
            a += ["--cookies", cookies]
        } else if r.cookieBrowser != .none {
            a += ["--cookies-from-browser", r.cookieBrowser.rawValue]
        }
        if r.sleepInterval > 0 { a += ["--sleep-interval", "\(r.sleepInterval)"] }
        if r.maxSleepInterval > 0 { a += ["--max-sleep-interval", "\(r.maxSleepInterval)"] }

        // Output
        a += ["-P", request.folder, "-o", outputTemplate(r)]
        if r.splitChapters && r.chaptersInFolder {
            a += ["-o", "chapter:%(title).100B (chapters)/%(section_number)03d %(section_title).100B.%(ext)s"]
        }
        if r.restrictFilenames { a.append("--restrict-filenames") }
        if r.noOverwrites { a.append("--no-overwrites") }
        if r.noMtime { a.append("--no-mtime") }

        // Anything else the user typed (already checked by the validator)
        a += ExtraArgsPolicy.tokenize(r.extraArguments) ?? []

        a.append("--")
        a += request.links
        return a
    }

    // MARK: Pieces

    /// The `-o` template. The guided name carries the video's id so two
    /// videos with the same title can never overwrite each other; a video
    /// playlist also numbers its items.
    static func outputTemplate(_ r: DownloadRecipe) -> String {
        if r.filenameTemplate == .custom {
            let custom = r.customTemplate.trimmed
            return custom.isEmpty ? "%(title)s.%(ext)s" : custom
        }
        if r.filenameTemplate == .guided && r.playlistMode == .full && r.mode != .audio {
            return "%(playlist_index)03d - " + FilenameTemplate.guided.template
        }
        return r.filenameTemplate.template
    }

    /// The `-S` value: the user's own, or one built from the recipe so the
    /// container needs no re-encoding.
    static func sortString(_ r: DownloadRecipe) -> String? {
        let own = r.customSort.trimmed
        if !own.isEmpty { return own }
        var tokens: [String] = []
        if r.mode == .audio {
            if let token = r.audioFormat.preferredSourceSort { tokens.append(token) }
        } else {
            if let height = r.maxResolution.height { tokens.append("res:\(height)") }
            if let token = r.frameRateLimit.sortToken { tokens.append(token) }
            if let token = r.videoCodec.sortToken { tokens.append(token) }
            if r.mode == .video, let token = r.audioCodec.sortToken { tokens.append(token) }
            if r.preferCompatibleStreams, let token = r.container.extSort { tokens.append(token) }
        }
        return tokens.isEmpty ? nil : tokens.joined(separator: ",")
    }

    /// The volume change is left out when the volume is evened out
    /// afterwards: that step would undo it, so it applies the change itself.
    static func audioFilterArguments(_ r: DownloadRecipe) -> [String] {
        var args: [String] = []
        let evenedOutLater = r.evenLoudness && r.mode == .audio
        if r.gainDB != 0 && !evenedOutLater { args += ["-af", "volume=\(String(format: "%.1f", r.gainDB))dB"] }
        if let rate = r.sampleRate.hertz { args += ["-ar", "\(rate)"] }
        if let channels = r.channels.count { args += ["-ac", "\(channels)"] }
        return args
    }
}
