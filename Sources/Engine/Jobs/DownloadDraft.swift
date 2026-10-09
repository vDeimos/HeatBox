import Foundation

/// What pasted or dropped text asks for.
public enum LinkInput: Equatable, Sendable {
    /// No web link in it.
    case none
    /// One link. When it names a video that also sits in a playlist, `link`
    /// is the video alone and `playlist` is the list, offered separately.
    case one(link: String, playlist: String?)
    case several([String])

    public static func read(_ text: String) -> LinkInput {
        let found = Links.extract(from: text)
        switch found.count {
        case 0:
            return .none
        case 1:
            let split = Links.splitYouTube(found[0])
            return .one(link: split?.video ?? found[0], playlist: split?.playlist)
        default:
            return .several(found)
        }
    }
}

/// What is on the Download screen, ready to be downloaded.
public enum DownloadTarget: Equatable, Sendable {
    case video(MediaFacts)
    case playlist(PlaylistFacts)
    /// Several links, each looked up when its turn comes.
    case links([String])

    public var count: Int {
        switch self {
        case .video: return 1
        case .playlist(let playlist): return playlist.count
        case .links(let links): return links.count
        }
    }

    /// Bulk work always asks first, with a count (plan Section 1).
    public var needsConfirmation: Bool { count > 1 }
}

/// The defaults from Settings that shape a guided download.
public struct DownloadDefaults: Equatable, Sendable {
    public var subtitles = false
    public var coverImage = false
    public var cutSponsors = false
    public var exactCut = true
    public var evenLoudness = false

    public init(subtitles: Bool = false, coverImage: Bool = false, cutSponsors: Bool = false, exactCut: Bool = true,
                evenLoudness: Bool = false) {
        self.subtitles = subtitles
        self.coverImage = coverImage
        self.cutSponsors = cutSponsors
        self.exactCut = exactCut
        self.evenLoudness = evenLoudness
    }

    public init(_ settings: AppSettings) {
        self.init(subtitles: settings.subtitles, coverImage: settings.coverImage,
                  cutSponsors: settings.cutSponsors, exactCut: settings.exactCut, evenLoudness: settings.evenLoudness)
    }
}

/// A recipe the person shaped themselves, in Customize or by picking a preset.
public struct Customization: Equatable, Sendable {
    /// What the download is called in the Queue: the preset's name, or the
    /// choice it started from with "customized" after it.
    public var name: String
    /// The preset or choice it started from, if any.
    public var presetID: String?
    public var recipe: DownloadRecipe

    public init(name: String, presetID: String? = nil, recipe: DownloadRecipe) {
        self.name = name
        self.presetID = presetID
        self.recipe = recipe
    }
}

/// The Download screen's decisions: which choices are offered, what the
/// picked one and the clip settings come to as a recipe, where the files will
/// go, and the requests handed to the queue. The screen only holds one of
/// these and draws it; it never builds a recipe or an argument.
///
/// There are two ways to say what is wanted. The guided way is a choice
/// from the list, shaped by the defaults from Settings. The other is a
/// `custom` recipe, from a preset or from Customize, which is used exactly as
/// it stands: Settings' defaults are already in it when it starts from a
/// choice, and are not laid over a preset. Picking a choice again drops it.
/// Either way there is one clip: the clip bar's, for a single video.
public struct DownloadDraft: Equatable, Sendable {
    public let target: DownloadTarget
    public let choices: [Choice]
    public private(set) var selectedID: String?
    public private(set) var custom: Customization?
    public var clipOn = false
    public var clipStart: Double = 0
    public var clipEnd: Double = 0
    public var splitChapters = false
    /// The comment whose chapter list was picked in the picker, if one was.
    public var chapterComment: String?

    public init(target: DownloadTarget) {
        self.target = target
        switch target {
        case .video(let media):
            choices = ChoiceBuilder.choices(for: media)
            clipEnd = media.seconds
        case .playlist, .links:
            choices = ChoiceBuilder.generic
        }
    }

    public init(_ result: ProbeResult) throws {
        switch result {
        case .video(let media): self.init(target: .video(media))
        case .playlist(let playlist): self.init(target: .playlist(playlist))
        case .failure(let failure): throw failure
        }
    }

    public var choice: Choice? {
        choices.first { $0.id == selectedID }
    }

    /// Something is picked: a choice, or a recipe of the person's own.
    public var isPicked: Bool { custom != nil || choice != nil }

    /// The estimated size of what will be saved, when the site says. Only a
    /// single video picked from the explained choices has one.
    public var estimatedBytes: Int64? {
        guard custom == nil, case .video = target else { return nil }
        return choice?.bytes
    }

    /// The name of what is picked, for the Queue and the summary line.
    public var pickedName: String? { custom?.name ?? choice?.title }

    public var media: MediaFacts? {
        if case .video(let media) = target { return media }
        return nil
    }

    // MARK: Picking

    /// Picks one of the explained choices. A recipe of the person's own is dropped.
    public mutating func pick(_ choiceID: String) {
        guard choices.contains(where: { $0.id == choiceID }) else { return }
        selectedID = choiceID
        custom = nil
        chapterComment = nil
    }

    /// Picks a preset, built in or the person's own. Its recipe is used as it
    /// stands. A clip saved in it (YT-DLP Studio's trim) moves to the clip bar
    /// when there is one video to cut.
    public mutating func apply(_ preset: Preset) {
        var recipe = preset.recipe
        if let saved = recipe.clip, let media, canClip {
            clipOn = true
            clipStart = min(max(saved.start, 0), media.seconds)
            clipEnd = min(saved.end ?? media.seconds, media.seconds)
            recipe.clip = nil
        } else if media != nil {
            recipe.clip = nil
        }
        selectedID = nil
        chapterComment = nil
        custom = Customization(name: preset.name, presetID: preset.id, recipe: recipe)
    }

    /// Opens what is picked for changing in Customize: the picked choice with
    /// the defaults from Settings already in it, or the first choice when
    /// nothing is picked yet. A recipe of the person's own is left as it is.
    public mutating func customize(defaults: DownloadDefaults) {
        guard custom == nil else { return }
        if choice == nil { selectedID = choices.first?.id }
        guard let choice, var recipe = guidedRecipe(defaults: defaults) else { return }
        // The clip stays on the clip bar; the recipe keeps how it is cut.
        if !recipe.cutsVideoSegments { recipe.exactCut = defaults.exactCut }
        if media != nil { recipe.clip = nil }
        custom = Customization(name: Messages.customName(of: choice.preset.name), presetID: choice.id, recipe: recipe)
        selectedID = nil
    }

    /// Goes back to the explained choices: the one the recipe started from, when it started from one.
    public mutating func dropCustom() {
        guard let started = custom?.presetID else { custom = nil; return }
        custom = nil
        chapterComment = nil
        if choices.contains(where: { $0.id == started }) { selectedID = started }
    }

    /// Replaces the recipe being customized. Nothing happens without one.
    public mutating func edit(_ change: (inout DownloadRecipe) -> Void) {
        guard var current = custom else { return }
        change(&current.recipe)
        if current.recipe.chapterSource == .youtube { chapterComment = nil }
        custom = current
    }

    /// The format choice from the "All formats" table, for the rows picked there.
    public mutating func useFormats(_ picked: Set<String>, defaults: DownloadDefaults) {
        guard let media, let selector = FormatCatalog(media).selector(for: picked) else { return }
        customize(defaults: defaults)
        edit { $0.customFormat = selector }
    }

    // MARK: Clip and chapters

    /// A clip can be chosen for a single video of known length.
    public var canClip: Bool { (media?.seconds ?? 0) > 2 }

    /// One file per chapter is offered when the video has chapters and no clip is being cut.
    public var canSplitChapters: Bool { (media?.chapters.count ?? 0) > 1 && !clipOn }

    /// The guided switches for chapters and exact cuts belong to a choice; a
    /// recipe of the person's own has them in Customize.
    public var showsGuidedSwitches: Bool { custom == nil }

    /// The part to download, or nil for the whole video.
    public var clip: Clip? {
        guard let media, canClip, clipOn, clipEnd > clipStart else { return nil }
        if clipStart <= 0 && clipEnd >= media.seconds { return nil }
        return Clip(start: max(clipStart, 0), end: clipEnd >= media.seconds ? nil : clipEnd)
    }

    // MARK: The recipe

    /// The picked choice's recipe with the clip, chapters and the defaults from Settings applied.
    private func guidedRecipe(defaults: DownloadDefaults) -> DownloadRecipe? {
        guard let choice else { return nil }
        var recipe = choice.recipe
        let video = recipe.mode != .audio
        if video && defaults.subtitles { recipe = recipe.withSubtitles() }
        if video && defaults.coverImage { recipe.embedThumbnail = true }
        if !video && defaults.evenLoudness { recipe.evenLoudness = true }
        if let clip {
            recipe.clip = clip
            recipe.exactCut = defaults.exactCut
        } else if canSplitChapters && splitChapters {
            recipe.splitChapters = true
        }
        // After the clip: cut segments must be cut exactly, or sound and picture drift apart.
        if defaults.cutSponsors { recipe = recipe.cuttingSponsors() }
        return recipe
    }

    /// What will be downloaded: the person's own recipe as it stands, with
    /// the clip bar's clip for a single video, or the guided one.
    public func recipe(defaults: DownloadDefaults) -> DownloadRecipe? {
        guard let custom else { return guidedRecipe(defaults: defaults) }
        var recipe = custom.recipe
        if media != nil {
            recipe.clip = clip
            // A clip cannot also be split into chapters; the clip wins, as in the guided flow.
            if clip != nil { recipe.splitChapters = false }
        }
        return recipe
    }

    /// True when the clip bar's clip switched off the recipe's own chapter split.
    public var clipOverridesChapters: Bool {
        clip != nil && (custom?.recipe.splitChapters ?? false)
    }

    /// What the validator says about the recipe as it will run. An error
    /// stops the download; a warning is only shown.
    public func issues(defaults: DownloadDefaults) -> [RecipeIssue] {
        recipe(defaults: defaults).map(RecipeValidator.validate) ?? []
    }

    /// Download can be pressed: something is picked and nothing in it is an error.
    public func isReady(defaults: DownloadDefaults) -> Bool {
        isPicked && !issues(defaults: defaults).contains { $0.severity == .error }
    }

    /// What the queue is handed when Download is pressed. Empty until something is picked.
    public func requests(defaults: DownloadDefaults, startAfter: Date? = nil) -> [JobRequest] {
        guard let name = custom?.name ?? choice?.preset.name, let recipe = recipe(defaults: defaults) else { return [] }
        switch target {
        case .video(let media):
            let comment = recipe.chapterSource == .youtube ? nil : chapterComment
            return [JobRequest(resolution: JobResolution(media), recipe: recipe, label: name, startAfter: startAfter,
                               chapterComment: comment)]
        case .playlist(let playlist):
            return [JobRequest(resolution: JobResolution(playlist), recipe: recipe, label: name, startAfter: startAfter)]
        case .links(let links):
            return links.map { original in
                JobRequest(resolution: JobResolution(source: .link, link: Links.singleVideo(original), title: original, site: ""),
                           recipe: recipe, label: name, startAfter: startAfter)
            }
        }
    }

    private var audioOnly: Bool {
        if let custom { return custom.recipe.mode == .audio }
        return choice?.audioOnly ?? false
    }

    /// Where the files will go, or nil when each link decides for itself.
    public func folder(rules: FolderRules) -> String? {
        switch target {
        case .video(let media):
            return rules.folder(site: media.site, audioOnly: audioOnly, playlistTitle: nil)
        case .playlist(let playlist):
            return rules.folder(site: playlist.site, audioOnly: audioOnly, playlistTitle: playlist.title)
        case .links:
            return nil
        }
    }

    /// The folder as a person would say it: "Movies › YouTube".
    public func destination(rules: FolderRules, home: String = NSHomeDirectory()) -> String {
        folder(rules: rules).map { Naming.breadcrumb($0, home: home) } ?? Messages.draftEachSiteFolder
    }

    /// One line saying what the Download button will do.
    public func summary(rules: FolderRules, home: String = NSHomeDirectory()) -> String {
        guard let name = pickedName else { return Messages.draftPickFirst }
        var parts = [name]
        if let clip {
            parts.append(Messages.clipRange(from: TimeText.clock(clip.start),
                                            to: TimeText.clock(clip.end ?? media?.seconds ?? clipEnd)))
        }
        parts.append(destination(rules: rules, home: home))
        return parts.joined(separator: " · ")
    }
}

// MARK: - The command preview

/// The command a person can read and copy for what is on the Download screen.
public struct CommandPreview: Equatable, Sendable {
    /// Empty when there is no command to show; `problem` then says why.
    public var command = ""
    /// One sentence when the recipe cannot run or nothing is picked.
    public var problem: String?
    /// Warnings from the validator; none of them stops the download.
    public var warnings: [String] = []
    /// What a copied command does differently from the app.
    public var notes: [String] = []

    public init(command: String = "", problem: String? = nil, warnings: [String] = [], notes: [String] = []) {
        self.command = command
        self.problem = problem
        self.warnings = warnings
        self.notes = notes
    }
}

extension DownloadDraft {
    /// The command for what is picked, exactly as the job will run it except
    /// for where it saves: the preview names the real destination, while the
    /// job downloads into its working folder and the engine moves the files
    /// on (plan Rule 5 and Section 3.3.7). Both come from `Job.commandRequest`.
    public func preview(defaults: DownloadDefaults, rules: FolderRules, speedLimitKB: Int = 0, archiveFile: String,
                        cookiesFile: String? = nil, toolchain: YtdlpCommand.Toolchain?) -> CommandPreview {
        let requests = self.requests(defaults: defaults)
        guard let first = requests.first else { return CommandPreview(problem: Messages.previewNeedsChoice) }
        guard let toolchain else { return CommandPreview(problem: Messages.noTool) }
        let job = Job(createdAt: Date(timeIntervalSince1970: 0), request: first)
        let folder = self.folder(rules: rules) ?? rules.mainFolder
        var request = job.commandRequest(folder: folder, archiveFile: job.recipe.useArchive ? archiveFile : nil,
                                         cookiesFile: cookiesFile, speedLimitKB: speedLimitKB)
        request.links = requests.map(\.resolution.link)
        do {
            let plan = try YtdlpCommand.plan(request, toolchain: toolchain)
            var notes = [Messages.previewDestination] + plan.notes
            if case .links = target { notes.append(Messages.previewEachSite) }
            if job.isPlaylist && !job.recipe.useArchive { notes.append(Messages.previewPrivateArchive) }
            return CommandPreview(command: plan.displayCommand, warnings: plan.warnings.map(\.message), notes: notes)
        } catch let failure as YtdlpCommand.Failure {
            return CommandPreview(problem: failure.message)
        } catch {
            return CommandPreview(problem: Messages.unreadable)
        }
    }
}

// MARK: - The list as the Queue screen sums it up

public struct QueueCounts: Equatable, Sendable {
    /// Running, or waiting for a free slot or for another try.
    public var busy = 0
    public var paused = 0
    public var scheduled = 0
    public var finished = 0

    public init(_ jobs: [Job]) {
        for job in jobs {
            switch job.state {
            case .waiting, .lookingUp, .running, .retrying: busy += 1
            case .paused: paused += 1
            case .scheduled: scheduled += 1
            case .done, .doneWithWarnings, .failed, .cancelled: finished += 1
            }
        }
    }

    /// Everything that will run without the person doing anything more.
    public var active: Int { busy + scheduled }
    public var unfinished: Int { busy + paused + scheduled }

    public var summary: String {
        var parts: [String] = []
        if busy > 0 { parts.append(Messages.queueBusy(busy)) }
        if paused > 0 { parts.append(Messages.queuePaused(paused)) }
        if scheduled > 0 { parts.append(Messages.queueScheduled(scheduled)) }
        return parts.isEmpty ? Messages.queueAllFinished : parts.joined(separator: " · ")
    }
}

/// A download that ended since the list was last looked at.
public enum JobEnding: Equatable, Sendable {
    case finished(Job)
    case failed(Job)

    /// What ended between two copies of the list: the jobs that were not
    /// finished before and are done or failed now. A cancelled job is the
    /// person's own doing and is not reported.
    public static func between(_ old: [Job], _ new: [Job]) -> [JobEnding] {
        let before = Dictionary(old.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        return new.compactMap { job in
            guard before[job.id]?.isUnfinished == true else { return nil }
            switch job.state {
            case .done, .doneWithWarnings: return .finished(job)
            case .failed: return .failed(job)
            default: return nil
            }
        }
    }
}

extension JobState {
    /// One word for the state, shown beside a download's title.
    public var label: String {
        switch self {
        case .waiting: return Messages.stateWaiting
        case .lookingUp: return Messages.stateLookingUp
        case .running: return Messages.stateRunning
        case .paused: return Messages.statePaused
        case .scheduled: return Messages.stateScheduled
        case .retrying: return Messages.stateRetrying
        case .done: return Messages.stateDone
        case .doneWithWarnings: return Messages.stateDoneWithWarnings
        case .failed: return Messages.stateFailed
        case .cancelled: return Messages.stateCancelled
        }
    }
}

extension JobProgress {
    /// "42% · 31.5MiB · 2.1MiB/s · 0:35 left · 2 of 5", with only what is known.
    public var line: String {
        var parts: [String] = []
        if let fraction { parts.append("\(Int((min(max(fraction, 0), 1) * 100).rounded(.down)))%") }
        if !size.isEmpty { parts.append(size) }
        if !speed.isEmpty { parts.append(speed) }
        if !timeLeft.isEmpty { parts.append(Messages.timeLeft(timeLeft)) }
        if itemCount > 1 { parts.append(Messages.itemOf(item, itemCount)) }
        return parts.joined(separator: " · ")
    }
}

extension Job {
    /// The line under a download's title: the choice, the site and the length.
    public var detail: String {
        var parts = [label, site, duration]
        if let itemCount, source == .playlist { parts.append(Messages.itemCount(itemCount)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// One line about where the job stands right now. A running job says
    /// what it is doing and how far it is; one waiting to try again counts
    /// down. A scheduled job has no line here: the app writes the time in
    /// the person's own format.
    public func statusLine(now: Date) -> String {
        switch state {
        case .running(let stage):
            let progress = self.progress.line
            guard case .downloading = stage, !progress.isEmpty else { return stage.label }
            return "\(stage.label) · \(progress)"
        case .retrying(let due):
            let seconds = max(Int(due.timeIntervalSince(now).rounded(.up)), 1)
            return Messages.retrying(inSeconds: seconds, retry: attempt, of: RetryPolicy.maxAttempts)
        default:
            return message
        }
    }
}
