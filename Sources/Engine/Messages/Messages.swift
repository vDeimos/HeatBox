import Foundation

/// Every sentence the engine can show a person lives here (plan Rule 7), so
/// wording stays consistent and could be translated later. Each failure is
/// one plain sentence with a next step. The product is named only through
/// `Engine.productName`.
public enum Messages {
    static let app = Engine.productName

    // MARK: Tools

    public static let purposeDownloader = "Downloads the videos"
    public static let purposeConverter = "Converts and cuts files"
    public static let purposeInspector = "Reads a file's details"
    public static let purposeScriptRuntime = "Lets the download tool read YouTube"

    public static let noTool = "The download tool is missing. Open Settings > Tools to set it up."
    public static let noConverter = "The conversion tool is missing. Open Settings > Tools to set it up."

    // Installing and updating the tools (Phase 10)
    public static let installLockProblem = "\(app) could not read its list of tools. Install \(app) again, or use the Homebrew command instead."
    public static let installUnreachable = "The download did not work. Check your internet connection and try again, or use the Homebrew command instead."
    public static func installChecksum(_ tool: String) -> String {
        "The file for \(tool) was not the one \(app) expected, so it was thrown away and nothing was installed. Try again later, or use the Homebrew command instead."
    }
    public static func installBroken(_ tool: String) -> String {
        "\(tool) was downloaded but would not start on this Mac, so nothing was installed. Use the Homebrew command instead."
    }
    public static let installNoRelease = "The newest yt-dlp could not be checked. Try again in a little while."
    public static let installCannotWrite = "\(app) could not write to its own folder. Check that your disk is not full."
    public static func installing(_ tool: String) -> String { "Installing \(tool)…" }
    public static func installed(_ tool: String) -> String { "\(tool) is installed." }
    public static let installedAll = "Everything is installed."
    public static func updateAlreadyCurrent(_ version: String) -> String { "yt-dlp is already the newest version (\(version))." }
    public static func updateDone(to version: String) -> String { "yt-dlp is now \(version)." }
    public static let updateOverridden = "You chose your own yt-dlp in Settings, so that one is still used. Press Reset beside it to use the new one."
    public static let updating = "Checking for a newer yt-dlp…"

    /// True for the sentences that mean "the site changed or refused"; the
    /// screens offer an Update button beside them.
    public static func suggestsToolUpdate(_ sentence: String) -> Bool {
        sentence == toolOutOfDate || sentence == refused
    }

    // MARK: Links and lookups

    public static let unreadable = "That link could not be read."
    public static let noLink = "Paste at least one link that starts with http."
    public static let live = "This is a live stream that is still running. \(app) downloads finished videos, so try again once the stream has ended."
    public static let upcoming = "This video hasn't started yet. Try again once it has been published."
    public static let emptyPage = "That link is a page with no videos on it. Open the video itself and copy its link."
    public static let notAChannel = "That link doesn't look like a channel or a list of videos. Open the channel's page and copy its address."

    public static let lookupStopped = "The lookup was stopped before it finished. Paste the link again to retry."

    // MARK: Choices

    public static let choiceBestTitle = "Best available"
    public static let choiceBestExplanation = "Highest quality, largest file. QuickTime may not open it; IINA does."
    public static let choiceOriginalTitle = "Original file"
    public static let choiceOriginalBadge = "as offered"
    public static let choiceOriginalExplanation = "This site offers a single version, so there is nothing to choose between. Downloads it exactly as it is."
    public static let choiceCompatibleTitle = "Plays everywhere"
    public static let choiceCompatibleExplanation = "Standard MP4. Opens in QuickTime, on iPhone and on TVs."
    public static let choiceTierBadge = "smaller than best"
    public static let choiceTierFallback = "A smaller, lower-resolution version."
    public static let choiceAudioTitle = "Audio only"
    public static let choiceAudioBadge = "M4A"
    public static let choiceAudioExplanation = "Just the sound. For music, podcasts and talks."

    public static func choiceResolution(_ height: Int) -> String { "\(height)p" }
    public static func choiceCompatibleBadge(upTo height: Int) -> String { "MP4 · up to \(height)p" }
    public static func choiceUpTo(_ height: Int) -> String { "Up to \(height)p" }

    /// What each resolution is good for.
    public static let choiceTierNotes: [Int: String] = [
        2160: "4K. Only worth it on a 4K screen or TV. Very large files.",
        1440: "Sharper than Full HD on a Retina screen. Large files.",
        1080: "Full HD. The usual sweet spot: sharp on a laptop or TV at a sensible size.",
        720: "HD. Fine on a laptop, a little soft on a TV. Roughly half the size of 1080p.",
        480: "Standard definition. Small files. Good for talks, or when the picture doesn't matter much.",
        360: "Low quality. The smallest video files. Fine when you mostly listen.",
    ]

    // The same choices when there is no single video to measure: a playlist, a channel or several links.
    public static let choiceAnyBestBadge = "highest each video has"
    public static let choiceAnyBestExplanation = "The highest quality each video offers, and the largest files. Some may use a newer format that QuickTime can't open. IINA plays them all."
    public static let choiceAnyCompatibleBadge = "MP4"
    public static let choiceAnyCompatibleExplanation = "Standard MP4 files. Open in QuickTime and on iPhones and TVs. Quality is limited to the best each site offers in that older format, usually 1080p."
    public static let choiceAnyTierBadges: [Int: String] = [1080: "Full HD", 720: "HD", 480: "small"]
    public static let choiceAnyTierNotes: [Int: String] = [
        1080: "Full HD at most. The usual sweet spot. Videos that only exist smaller download at their own best.",
        720: "HD at most. Fine on a laptop, a little soft on a TV. Roughly half the size of 1080p, which adds up over a long list.",
        480: "Standard definition at most. Small files. Good for talks, or when the picture doesn't matter much.",
    ]

    public static let sizeUnknown = "size unknown"
    public static let sizeVaries = "varies"
    public static func sizeAbout(_ size: String) -> String { "about \(size)" }

    // MARK: The format table

    public static let formatKindCombined = "A+V"
    public static let formatKindVideo = "Video"
    public static let formatKindAudio = "Audio"
    public static let formatKindUnknown = "Unknown"
    public static let untitled = "Untitled"
    public static let untitledPlaylist = "Playlist"

    // MARK: Downloads and conversions

    public static let nothingSaved = "Nothing was downloaded. The link may not point to a video."
    public static let convertFailed = "The conversion did not finish. The file may be damaged or in a format that can't be read."
    public static let unreadableFile = "That file could not be read as a video or audio file."
    public static let phoneCopyImpossible = "A phone-friendly copy could not be made from this file."
    public static let pausedBecauseClosed = "Paused when \(app) closed. Press Resume to carry on where it stopped."
    public static let missedSchedule = "This was scheduled for a time that has passed. Press Resume to start it now."

    /// Shown while a download waits to try again.
    public static func retrying(inSeconds seconds: Int, retry: Int, of total: Int) -> String {
        let wait = seconds >= 60 ? "\(seconds / 60) minute" + (seconds >= 120 ? "s" : "") : "\(seconds) second" + (seconds == 1 ? "" : "s")
        return "The connection dropped. Trying again in \(wait) (retry \(retry) of \(total))."
    }

    // MARK: The queue

    public static let waitingForSlot = "Waiting for a free slot"
    public static let lookingUp = "Reading the link…"
    public static let paused = "Paused. Press Resume to carry on where it stopped."
    public static let cancelled = "Cancelled"
    public static let downloadFailed = "The download did not finish."
    public static let lookupTimedOut = "The site took too long to answer. Check your internet connection and try again."
    public static let alreadyDownloaded = "You already have this, so nothing new was downloaded."
    public static let workspaceUnwritable = "\(app) couldn't create its working folder. Check that the disk isn't full, then try again."
    public static func destinationUnwritable(_ folder: String) -> String {
        "The files couldn't be saved to \(folder). Check that the folder exists and can be written to, then press Retry."
    }
    public static func savedTo(_ place: String) -> String { "Saved to \(place)" }
    public static func filesSavedTo(_ count: Int, _ place: String) -> String { "\(count) files saved to \(place)" }
    public static func someSavedTo(_ saved: Int, of total: Int, _ place: String) -> String {
        "\(saved) of \(total) saved to \(place). \(total - saved) could not be downloaded."
    }
    public static let toolReportedProblem = "The download tool reported a problem. The log has the details."
    /// Added to the name of a file that holds part of a video.
    public static let clipSuffix = " (clip)"

    public static let stageStarting = "Starting…"
    public static let stageDownloading = "Downloading"
    public static let stageFinishing = "Finishing…"
    public static let stageMerging = "Merging streams"
    public static let stageExtractingAudio = "Extracting audio"
    public static let stageRemuxing = "Repackaging"
    public static let stageConvertingVideo = "Converting video"
    public static let stageEmbeddingCover = "Adding the cover image"
    public static let stageWritingTags = "Writing tags"
    public static let stageSplittingChapters = "Splitting chapters"
    public static let stageSponsorBlock = "Finding sponsor segments"
    public static let stageCutting = "Cutting segments"
    public static let stageEmbeddingSubtitles = "Adding subtitles"
    public static let stageFixing = "Fixing the file"
    public static let stageConvertingCover = "Converting the cover image"
    public static let stageConvertingSubtitles = "Converting subtitles"
    public static let stageCheckingChapters = "Checking the video's chapters"
    public static let stageCommentChapters = "Looking for chapters in the comments"
    public static let stageTaggingTracks = "Tagging tracks"
    public static let stageLoudness = "Evening out the volume"
    public static func stageEncoding(percent: Int?) -> String {
        percent.map { "\(stageConvertingVideo) · \($0)%" } ?? stageConvertingVideo
    }

    // MARK: The steps after a download

    // A step that fails never costs the download: the file is saved as it
    // came, and the job ends "done, with notes" carrying one of these.
    public static let loudnessFailed = "The volume couldn't be evened out, so the audio was saved as it was downloaded."
    public static let loudnessLeft = "The volume was left as it was."
    public static let retagFailed = "Some chapter files couldn't be given their own titles, so they kept the album's tags."
    public static let encodeFailed = "The video couldn't be converted, so it was saved as it was downloaded. The log has the details."
    public static let encodeFallback = "The Mac's video hardware refused; trying again with the slower software encoder."
    public static let replaceFailed = "The original couldn't be moved to the Trash, so the converted video was saved beside it."
    public static let originalInTrash = "The original download is in the Trash."
    public static let commentChaptersNone = "No chapter list was found in the comments, so the video was saved without those chapters."
    public static let commentChaptersGone = "The comment you picked is no longer among the top comments, so the video was saved without its chapters. Pick a chapter list again to use one."
    public static let commentChaptersUnreadable = "The comments couldn't be read, so the video was saved without chapters from them."
    public static let commentChaptersOneVideoOnly = "Chapters from comments are read for one video at a time, so this list was downloaded without them."
    public static let commentChaptersKeptOwn = "Keeping the video's own chapters."
    public static let commentChaptersNoneQuiet = "No chapter list in the comments; downloading without chapters."
    public static func commentChaptersUsed(_ count: Int, author: String) -> String {
        "Using \(count) chapters from a comment by \(author)."
    }
    public static let chapterOpening = "Opening"
    public static let commentAuthorUnknown = "Unknown author"
    public static func taggedTrack(_ index: Int, of total: Int, _ title: String) -> String { "Tagged \(index) of \(total): \(title)" }
    public static func skippedTrack(_ name: String, _ reason: String) -> String { "Couldn't tag \(name): \(reason)" }

    // One word for where a download stands.
    public static let stateWaiting = "Waiting"
    public static let stateLookingUp = "Reading"
    public static let stateRunning = "Downloading"
    public static let statePaused = "Paused"
    public static let stateScheduled = "Scheduled"
    public static let stateRetrying = "Trying again"
    public static let stateDone = "Done"
    public static let stateDoneWithWarnings = "Done, with notes"
    public static let stateFailed = "Failed"
    public static let stateCancelled = "Cancelled"

    public static func timeLeft(_ time: String) -> String { "\(time) left" }
    public static func itemOf(_ item: Int, _ count: Int) -> String { "\(item) of \(count)" }
    public static func itemCount(_ count: Int) -> String { count == 1 ? "1 item" : "\(count) items" }

    public static func queueBusy(_ count: Int) -> String { "\(count) in progress or waiting" }
    public static func queuePaused(_ count: Int) -> String { "\(count) paused" }
    public static func queueScheduled(_ count: Int) -> String { "\(count) scheduled" }
    public static let queueAllFinished = "All finished"

    // MARK: The Download screen

    public static let draftPickFirst = "Pick a version above first."
    public static let draftEachSiteFolder = "Each in its own site's folder"
    public static func clipRange(from start: String, to end: String) -> String { "\(start) to \(end)" }

    public static let speedNoLimit = "No limit"
    public static func logDropped(_ count: Int) -> String { "(\(count) earlier lines are no longer kept)" }

    // MARK: Recipes and commands

    public static let recipeEncodeNeedsContainer = "Re-encoding needs a file type. Choose one in Customize > Format, such as MP4 or MKV."
    public static let recipeEncodeIgnoredForAudio = "Re-encoding is for video, so it is ignored for an audio download."
    public static let recipeLoudnessAudioOnly = "Evening out the volume is for audio downloads, so it is ignored for a video."
    public static func recipeEncoderContainer(encoder: String, container: String, suggested: String) -> String {
        "\(encoder) can't be stored in a \(container) file. Choose \(suggested), or a different encoder."
    }
    public static func recipeNumberOutOfRange(_ name: String, from low: Double, to high: Double) -> String {
        "\(name) must be between \(trimmedNumber(low)) and \(trimmedNumber(high))."
    }
    public static let recipeClipOrder = "The end of the clip must come after its start, and the start can't be negative."
    public static let recipeClipWithChapters = "A clip can't also be split into chapters. Turn one of them off."
    public static let recipePlaylistItems = "Playlist items must look like 1-5, 8 or 3:10, with commas between parts."
    public static let recipeRateLimit = "The speed limit must be a number with an optional K, M or G, such as 500K or 2M."
    public static let recipeProxy = "A proxy must start with http://, https://, socks4://, socks5:// or socks5h://."
    public static let recipeSubtitleLanguages = "Say which subtitle languages to fetch, such as en or en.*."
    public static let recipeSponsorCategories = "Choose at least one SponsorBlock category."
    public static let recipeSponsorNotRemovable = "Highlights and community chapters can be marked but not cut out. Remove them from the list or mark instead of cut."
    public static let recipeTemplateExtension = "A file name template must end in .%(ext)s, or the file would have no extension."
    public static let recipeTemplateEscapes = "A file name template can't start with /, or use .., ~ or $, because the file would leave the download folder. Use only names inside the folder."
    public static let recipeTemplateEmpty = "Type a file name template, or choose one of the ready-made names."
    public static let recipeArchiveNeeded = "To skip videos you already have, \(app) needs an archive file, and none was provided."
    public static let recipeAudioFiltersIgnored = "Volume, sample rate and channel changes don't apply when the original audio is kept. Choose an audio format to use them."
    public static let recipeThumbnailContainer = "Cover art can't be embedded in this file type, so none will be added. Choose MP4 or MKV to keep it."
    public static let recipeSubtitleContainer = "This file type can't hold subtitles, so they won't be embedded."
    public static let recipeCookiesBrowser = "Reading a browser's sign-in lets \(app) see every site's cookies. Use a saved sign-in instead when you can."
    public static func recipeExtraArguments(_ problem: ExtraArgsPolicy.Problem) -> String {
        switch problem {
        case .unfinished:
            return "The extra options have a quote that is never closed. Close it or remove it."
        case .refused(let option, let reason):
            switch reason {
            case .notAllowed:
                return "The extra option \(option) isn't allowed. Extra options can only change how a download is chosen, paced or fetched. Remove it and try again."
            case .notAnOption:
                return "\(option) in the extra options isn't an option. Links go in the Download box, not here."
            case .missingValue:
                return "The extra option \(option) needs a value after it. Add one and try again."
            case .endsOptions:
                return "The extra options can't contain \(option), because it would let them add links. Remove it and try again."
            }
        }
    }
    public static func commandInvalidLink(_ link: String) -> String {
        "\"\(link)\" isn't a web link. Links must start with http or https."
    }
    public static let commandNoLinks = noLink
    public static let commentChapters = "Chapters taken from comments need \(app) to prepare them first, so this command can't reproduce them on its own."

    private static func trimmedNumber(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    // MARK: Sign-in

    public static let signInBlocked = "macOS is stopping \(app) from reading that browser's data. In System Settings, open Privacy & Security > Full Disk Access and switch \(app) on. Then quit and reopen \(app) and try again."
    public static let signInNotFound = "\(app) could not read a sign-in from that browser. Make sure you are signed in to YouTube there, then try again."

    /// Explains why reading a browser's sign-in failed.
    public static func signInFailure(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("operation not permitted") || lower.contains("permission")
            || lower.contains("could not find") || lower.contains("cookies database") {
            return signInBlocked
        }
        return signInNotFound
    }

    // MARK: What the download tool's errors mean

    static let unviewablePlaylist = "YouTube won't show this kind of playlist. Auto-generated Mixes and some personal lists can't be read. Open the video itself, or use a playlist that has its own page."
    static let protected = "This site protects its videos against copying, so they can't be downloaded."
    static let signInExpired = "Your saved sign-in has expired. In Settings, press 'Copy my sign-in' again, then try again."
    static let membersOnly = "This video is for channel members. In Settings, turn on 'Use my saved YouTube sign-in'. If you haven't saved one yet, press 'Copy my sign-in' there."
    static let signInRequired = "The site wants a signed-in account for this video. In Settings, turn on 'Use my saved YouTube sign-in' (save one first with 'Copy my sign-in'), or try again later."
    static let privateVideo = "This video is private, so it can't be downloaded."
    static let regionBlocked = "This video isn't available in your region."
    static let unavailable = "This video is no longer available."
    static let notFound = "Nothing was found at that link. Check the address and try again."
    static let refused = "The site refused the request. If the video needs an account, turn on your saved sign-in in Settings; otherwise update the download tool in Settings > Tools."
    static let rateLimited = "The site is limiting requests from you right now, usually after many downloads in a short time. Wait 15 to 30 minutes and try again."
    static let unsupportedSite = "This site isn't supported, or the link doesn't point to a video page."
    static let diskFull = "The disk is full. Free some space and try again."
    static let toolOutOfDate = "The site has changed and the download tool may be out of date. Press Update yt-dlp (it is in Settings > Tools too), then try again."
    static let unreachable = "The site couldn't be reached. Check your internet connection and try again."
}

// MARK: - Library, Following and what was brought over (Phase 7)

extension Messages {
    // MARK: Library

    public static let libraryUnknownChannel = "Unknown channel"
    public static let libraryOtherSite = "Other"
    public static let librarySortNewest = "Newest first"
    public static let librarySortOldest = "Oldest first"
    public static let librarySortTitle = "Title"
    public static let librarySortSite = "Site"
    public static let libraryFilterAll = "All"
    public static let libraryFilterVideo = "Video"
    public static let libraryFilterAudio = "Audio"
    public static let libraryFilterUnwatched = "Unwatched"
    public static let libraryEmpty = "Nothing here yet. Every video you download appears on this screen with its picture. Click one to see its details, or double-click to play it."
    public static let libraryNoMatches = "No downloads match."
    public static let libraryFileMissing = "File moved or deleted"
    public static let libraryFileMissingDetail = "This file has been moved or deleted."
    public static let libraryCannotTrash = "That file could not be moved to the Trash. It may be on a disk that is read-only."
    public static let libraryCannotPutBack = "To bring it back, open the Trash, select the file and choose Put Back."
    public static func libraryMovedToTrash(_ title: String) -> String { "Moved \"\(title)\" to the Trash." }
    public static func libraryTakenOffList(_ title: String) -> String { "\"\(title)\" was taken off the list. Its file was already gone." }
    /// The version name of a re-encoded file saved beside its download.
    public static let libraryConvertedCopy = "Converted copy"
    public static func libraryFilesFound(_ count: Int) -> String {
        count == 1 ? "1 file that had been moved was found again." : "\(count) files that had been moved were found again."
    }

    /// "You've already downloaded this one: Plays everywhere." Each version is named once.
    public static func alreadyInLibrary(versions: [String]) -> String {
        var seen: [String] = []
        for version in versions where !version.isEmpty && !seen.contains(version) { seen.append(version) }
        switch seen.count {
        case 0: return "You've already downloaded this one."
        case 1: return "You've already downloaded this one: \(seen[0])."
        default:
            let words = [2: "two", 3: "three", 4: "four", 5: "five"]
            let count = words[seen.count] ?? "\(seen.count)"
            let list = seen.dropLast().joined(separator: ", ") + " and " + seen[seen.count - 1]
            return "You've already downloaded this one in \(count) versions: \(list)."
        }
    }
}

// MARK: - Bringing over the older apps (Phase 7)

extension Messages {
    public static func importPostprocessorArgs(_ name: String) -> String {
        "\"\(name)\" had a post-processor arguments field, which \(app) no longer has. Put those arguments in Extra arguments if you still need them."
    }
    public static func importLegacyContainer(_ name: String, _ container: String) -> String {
        "\"\(name)\" used \(container), which \(app) no longer offers, so it uses the download tool's own choice."
    }
    public static func importExtraArgumentsRefused(_ name: String) -> String {
        "\"\(name)\" had extra arguments that \(app) does not allow (they can run programs or read other files), so they were left out."
    }
    public static let importPhobosQueueLeft = "Phobos had downloads that were not finished. They were not brought over; paste their links again."
    public static let importPhobosSignInLeft = "Phobos's saved YouTube sign-in was not copied. It is still where Phobos keeps it."
    public static func importSummary(records: Int, channels: Int, presets: Int, settings: Bool) -> String {
        var parts: [String] = []
        if records > 0 { parts.append(records == 1 ? "1 download" : "\(records) downloads") }
        if channels > 0 { parts.append(channels == 1 ? "1 followed channel" : "\(channels) followed channels") }
        if presets > 0 { parts.append(presets == 1 ? "1 preset" : "\(presets) presets") }
        if settings { parts.append("your settings") }
        return parts.isEmpty ? "" : "Brought over from your earlier apps: " + parts.joined(separator: ", ") + "."
    }
}

extension Messages {
    public static let followingChannelFallback = "Channel"
    public static let followingExplainer = "\(app) only looks for new videos when you press Check now. Nothing downloads until you choose it."
    public static let followingEmpty = "You aren't following any channels yet. Paste a channel's link above and press Follow. Videos it has already published count as seen, so only later ones show up as new."
    public static let followingAlready = "You are already following that channel."
    public static let followingNothingNew = "Nothing new."
    public static let followingStarted = "Following. New videos will show up here."
    public static let followingChecking = "Checking…"
    public static func followingNew(_ count: Int) -> String { "\(count) new." }
}

// MARK: - Customize and presets (Phase 8)

extension Messages {
    /// What a download is called in the Queue once its choice has been changed in Customize.
    public static func customName(of base: String) -> String { "\(base), customized" }
    public static let customPlain = "Custom"

    public static func presetsImported(_ count: Int) -> String {
        switch count {
        case 0: return "That file has no presets \(app) can use."
        case 1: return "1 preset was imported."
        default: return "\(count) presets were imported."
        }
    }
    public static func presetRefused(_ name: String, why: String) -> String {
        "\"\(name)\" was not imported: \(lowercasedStart(why))"
    }
    public static func presetNeedsAttention(_ name: String, why: String) -> String {
        "\"\(name)\" was imported but can't run as it is: \(lowercasedStart(why))"
    }
    public static let presetFileUnreadable = "That file isn't a presets file from \(app)."
    public static let presetNameTaken = "Another of your presets already has that name. Choose a different one."
    public static let presetNameEmpty = "Give the preset a name."

    private static func lowercasedStart(_ sentence: String) -> String {
        guard let first = sentence.first else { return sentence }
        return first.lowercased() + sentence.dropFirst()
    }

    // The command preview
    public static let previewDestination = "This is the command \(app) runs, with one difference: \(app) downloads into a working folder of its own and then moves the finished files to the folder shown here."
    public static let previewEachSite = "Each link is saved in its own site's folder; the main folder stands in for them here."
    public static let previewPrivateArchive = "\(app) also keeps a private list of the items it has finished, so a paused playlist carries on where it stopped."
    public static let previewNeedsChoice = "Pick a version or a preset to see its command."

    // Customize
    public static let customizeClipWinsOverChapters = "A clip is being cut, so the video is not split into chapters."
    public static let customizeFormatPicked = "Using the versions picked in All formats. Clear the box below to go back to the settings above."
    public static let customizePlaylistOnly = "These apply to a playlist or a channel."

    // The comment-chapter picker
    public static let commentPickerNone = "No comment on this video holds a chapter list (at least three timestamps, one per line)."
    public static let commentPickerUnreadable = "The comments couldn't be read. Check the connection and try again."
    public static func commentPickerLine(chapters: Int, likes: Int) -> String {
        "\(chapters) chapters" + (likes > 0 ? " · \(likes) likes" : "")
    }
}

// MARK: - Convert, phones, spoken words, the command bar and the tour (Phase 9)

extension Messages {
    // Convert
    public static let convertMP4Title = "Make it play everywhere"
    public static let convertMP4Explanation = "Saves an MP4 that opens in QuickTime and on iPhones and TVs. Quick when the video inside is already compatible."
    public static let convertShrinkTitle = "Shrink it"
    public static let convertShrinkExplanation = "Makes a smaller copy. Smaller always means some loss of quality, so pick the largest size that suits you."
    public static let convertAudioTitle = "Take the audio out"
    public static let convertAudioExplanation = "Saves the sound only, as an M4A for the Music app or a phone."
    public static let convertClipTitle = "Cut a clip"
    public static let convertClipExplanation = "Saves part of the file as its own file, cut exactly at the times you choose."
    public static let convertNotPossible = "Not possible for this file."
    public static let shrinkClose = "Close to original"
    public static let shrinkMedium = "Medium"
    public static let shrinkSmall = "Small"
    public static let convertNoSaving = "no saving"
    public static let convertNoPicture = "This file has no picture, only sound."
    public static let convertAlreadySmall = "This file is already about as small as it can sensibly be, so shrinking would not make it smaller."
    public static let convertNoSound = "This file has no sound to take out."
    public static let convertClipTimes = "Choose an end time that is after the start time."
    public static let convertLabelMP4 = "MP4 copy"
    public static let convertLabelAudio = "Audio only"
    public static let convertLabelPhone = "Phone copy"
    public static func convertLabelShrink(_ level: String) -> String { "\(level) copy" }
    public static func convertLabelClip(_ start: String, _ end: String) -> String { "Clip \(start) to \(end)" }
    public static func convertSavesAs(_ name: String, size: String?) -> String {
        "Saves as \(name) beside the original" + (size.map { ", about \($0)" } ?? "") + ". The original is never changed."
    }
    public static func convertSaved(_ name: String, in place: String) -> String { "Saved as \(name) in \(place)" }
    public static let convertStateRunning = "Converting"
    public static let convertStateDone = "Done"
    public static let convertStateFailed = "Failed"
    public static let convertStateCancelled = "Cancelled"
    public static let convertStarting = "Converting…"
    public static let convertRepackaging = "Repackaging, no quality is lost…"
    public static let convertNameTaken = "Another file took the name the copy was going to have. Press Start again."
    public static let convertNoSmaller = "This file is already compressed about as far as it will go, so the copy came out no smaller. The copy was removed, and the original is untouched."
    public static let convertBatteryTitle = "Your Mac is on battery"
    public static let convertBatteryText = "Converting uses a lot of power. You can go ahead now, or cancel and do it when the Mac is plugged in."

    // Send to iPhone
    public static let phoneChecking = "Checking the file…"
    public static let phoneMakingCopy = "Making a phone-friendly copy. It is saved beside the original…"
    public static let phoneCopyFailed = "The phone-friendly copy could not be made. The Convert screen says why."
    public static let phoneBatteryText = "Making a phone-friendly copy uses a lot of power. You can go ahead now, or cancel and do it when the Mac is plugged in."

    // Spoken words
    public static func spokenCount(_ searchable: Int, of total: Int) -> String { "\(searchable) of \(total) videos searchable" }
    public static let spokenSpeechOff = "Speech recognition is off for \(app). Allow it in System Settings, under Privacy & Security, then Speech Recognition."
    public static let spokenWaitingForPower = "Waiting for the Mac to be plugged in to listen to videos without captions."
    public static func spokenReading(_ title: String) -> String { "Reading \u{201C}\(title)\u{201D}…" }
    public static func spokenFetching(_ title: String) -> String { "Fetching captions for \u{201C}\(title)\u{201D}…" }
    public static func spokenListening(_ title: String, part: Int, of total: Int) -> String {
        "Listening to \u{201C}\(title)\u{201D}, part \(part) of \(total)…"
    }
    public static let spokenCannotWrite = "The search index could not be written."
    public static let spokenCannotListen = "A video without captions could not be listened to. Speech recognition may be off for \(app), or this Mac cannot do it without sending sound away."
    public static func spokenOpenedFromStart(_ time: String) -> String {
        "Opened from the start. This was said at \(time). IINA can open a video at that moment."
    }
    public static let spokenHeading = "Said in your videos"

    // The command bar
    public static let commandPlaceholder = "Type a command, a link, or a video title"
    public static let commandNothing = "Nothing matches. Paste a link to download it."
    public static let commandGroupGo = "Go to"
    public static let commandGroupAction = "Action"
    public static let commandGroupDownload = "Download"
    public static let commandGroupPlay = "Play"
    public static let commandGroupSearch = "Search"
    public static func commandGoTo(_ screen: String) -> String { "Go to \(screen)" }
    public static let commandSettings = "Settings"
    public static let commandSettingsDetail = "Folders, file names, appearance, speed limit, tools"
    public static let commandPauseAll = "Pause All"
    public static let commandPauseAllDetail = "Pause every running download"
    public static let commandResumeAll = "Resume All"
    public static let commandResumeAllDetail = "Carry on with paused downloads"
    public static let commandClearFinished = "Clear Finished"
    public static let commandClearFinishedDetail = "Remove finished downloads from the Queue"
    public static let commandCheckChannels = "Check Channels"
    public static let commandCheckChannelsDetail = "Look for new videos from channels you follow"
    public static let commandPaste = "Paste a Link"
    public static let commandPasteDetail = "Look up the link you just copied"
    public static let commandOpenFolder = "Open the Main Folder"
    public static let commandOpenFolderDetail = "Show your downloads in Finder"
    public static let commandTour = "Welcome Tour"
    public static let commandTourDetail = "A short introduction to \(app)"
    public static func commandLookUp(_ links: Int) -> String { links > 1 ? "Look up \(links) links" : "Look up this link" }
    public static func commandFindSpoken(_ words: String) -> String { "Find \u{201C}\(words)\u{201D} in words spoken" }
    public static let commandFindSpokenDetail = "Search what was said in your downloads"

    // The tour
    public static let tourWelcome = "Welcome to \(app)"
    public static let tourFinish = "Start Using \(app)"
    public static let tourPasteTitle = "Paste a link"
    public static let tourPasteText = "Copy the address of any video page, then click Paste. One video, several links, a playlist or a channel all work."
    public static let tourPickTitle = "Pick a version"
    public static let tourPickText = "\(app) lists the versions worth choosing between and explains each one in plain words, with its size. Nothing downloads until you choose. Customize opens every option when you want more control."
    public static let tourLibraryTitle = "Find it in the Library"
    public static let tourLibraryText = "Everything you download appears in the Library with its picture. Click to see details, double-click to play, or search by title, site or channel."
    public static let tourYoursTitle = "Make it yours"
    public static let tourYoursText = "\(app) collects nothing: no account, no tracking. Folders, file names and colours are in Settings, which opens with Command and comma. Press Command and K at any time to jump to anything."

    // Sign-in and the update notice
    public static let signInChooseBrowser = "Choose a browser first."
    public static let signInCannotSave = "The sign-in could not be saved. Check that the disk is not full, then try again."
    public static let signInSaved = "Saved. Turn on 'Use my saved YouTube sign-in' above to use it."
    public static let signInNone = "No saved sign-in yet. Use 'Copy my sign-in' below."
    public static func updateAvailable(_ version: String) -> String { "A new version of \(app) is available: \(version)" }
}

// MARK: - Release hardening (Phase 11)

extension Messages {
    public static func diskLow(free: String, needed: String) -> String {
        "There is only \(free) free on that disk and this download needs about \(needed) with room to work. Free some space or choose another folder in Settings, then try again."
    }
    public static let diagnosticsSaved = "Saved. It holds versions and counts only: no links, titles, file names or sign-in. Attach it to a bug report."
    public static let diagnosticsCannotSave = "The diagnostics file could not be saved. Choose another folder and try again."
}
