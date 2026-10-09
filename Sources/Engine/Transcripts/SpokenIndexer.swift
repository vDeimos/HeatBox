import Foundation

/// What Settings says about searching by spoken words.
public struct SpokenSettings: Equatable, Sendable {
    /// Find words said in the videos. Nothing here runs while this is off.
    public var enabled = false
    /// Listen to videos that have no captions, on this Mac.
    public var listen = true
    /// A saved sign-in, when the person uses one.
    public var cookiesFile: String?
    /// The caption languages to ask a site for ("fr,en").
    public var languages = "en"

    public init(enabled: Bool = false, listen: Bool = true, cookiesFile: String? = nil, languages: String = "en") {
        self.enabled = enabled
        self.listen = listen
        self.cookiesFile = cookiesFile
        self.languages = languages
    }
}

/// How far along the reading is, for Settings and the Library.
public struct SpokenStatus: Equatable, Sendable {
    public var enabled = false
    /// Videos that can be searched by what was said.
    public var searchable = 0
    /// Downloads in the Library (copies not counted).
    public var total = 0
    public var isWorking = false
    public var message = ""
    public var speechNotAllowed = false

    public init() {}

    /// One line: "12 of 40 videos searchable. Reading “…”…"
    public var line: String {
        var line = Messages.spokenCount(searchable, of: total)
        if speechNotAllowed { line += ". " + Messages.spokenSpeechOff }
        if !message.isEmpty { line += (line.hasSuffix(".") ? " " : ". ") + message }
        return line
    }
}

/// A moment in a Library video where the searched words were said.
public struct SpokenResult: Identifiable, Equatable, Sendable {
    public let record: LibraryRecord
    public let start: Double
    public let pieces: [SpokenPiece]
    public var id: String { "\(record.id.uuidString)@\(start)" }
}

/// Finds out what was said in each Library video, so the Library can search
/// it (Phobos's spoken-word search). Switched on in Settings; nothing here
/// runs otherwise. For each video, in order: captions inside the file, then
/// the site's own captions (one small request), then, if allowed, listening
/// to it with this Mac's own speech recognition, on mains power only.
/// Listening happens on the Mac and nothing is sent anywhere.
public actor SpokenIndexer {
    private let database: TranscriptDB
    private let library: LibraryRepository
    private let tools: @Sendable () -> ToolRegistry
    private let recognizer: any SpeechRecognizer
    private let power: any PowerSource
    private let scratch: URL
    private let runner: ProcessRunner
    private let clock: any EngineClock

    private var settings = SpokenSettings()
    private var pending: [UUID] = []
    private var waitingForPower: [UUID] = []
    private var current: UUID?
    private var worker: Task<Void, Never>?
    /// Raised whenever the reading is switched off, so work started before then is dropped.
    private var generation = 0
    private var state = SpokenStatus()
    private var watchers: [UUID: AsyncStream<SpokenStatus>.Continuation] = [:]

    /// How long a site is given to hand over its captions.
    static let fetchLimit: TimeInterval = 180

    public init(database: TranscriptDB, library: LibraryRepository, tools: @escaping @Sendable () -> ToolRegistry,
                recognizer: any SpeechRecognizer = NoSpeechRecognizer(), power: any PowerSource = MainsPower(),
                scratch: URL = FileManager.default.temporaryDirectory, runner: ProcessRunner = ProcessRunner(),
                clock: any EngineClock = SystemClock()) {
        self.database = database
        self.library = library
        self.tools = tools
        self.recognizer = recognizer
        self.power = power
        self.scratch = scratch
        self.runner = runner
        self.clock = clock
    }

    // MARK: What the screens read

    public func status() -> SpokenStatus { state }

    public func updates() -> AsyncStream<SpokenStatus> {
        let id = UUID()
        return AsyncStream { continuation in
            watchers[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.dropWatcher(id) }
            }
        }
    }

    private func dropWatcher(_ id: UUID) { watchers[id] = nil }

    private func publish() {
        state.enabled = settings.enabled
        state.speechNotAllowed = settings.enabled && settings.listen && recognizer.availability() == .notAllowed
        for watcher in watchers.values { watcher.yield(state) }
    }

    private func refreshCounts() async {
        state.searchable = await database.counts().searchable
        state.total = await library.records().filter { !$0.isCopy }.count
    }

    /// Moments where every word of the query was said, in videos whose files
    /// are still there. Nothing while the setting is off or under three letters.
    public func search(_ query: String, limit: Int = 30) async -> [SpokenResult] {
        let typed = query.trimmed
        guard settings.enabled, typed.count >= 3 else { return [] }
        var results: [SpokenResult] = []
        for hit in await database.search(typed, limit: limit * 2) {
            guard let id = UUID(uuidString: hit.video), let record = await library.record(id), !record.missing else { continue }
            results.append(SpokenResult(record: record, start: hit.start, pieces: TranscriptDB.pieces(of: hit.snippet)))
            if results.count >= limit { break }
        }
        return results
    }

    // MARK: Starting and stopping

    /// Called at launch and whenever one of the spoken-search settings changes.
    public func update(_ new: SpokenSettings) async {
        let old = settings
        settings = new
        if new.enabled {
            if new.listen, recognizer.availability() == .undecided { await recognizer.requestAccess() }
            await scan()
        } else if old.enabled {
            generation += 1
            worker?.cancel()
            worker = nil
            pending = []
            waitingForPower = []
            current = nil
            state.isWorking = false
            state.message = ""
        }
        publish()
    }

    /// Queues every video that has not been looked at yet, and forgets the
    /// words of videos that have left the Library.
    public func scan() async {
        guard settings.enabled else { return }
        let known = await database.indexedVideos()
        let records = await library.records()
        let present = Set(records.map { $0.id.uuidString })
        for video in known.keys where !present.contains(video) { await database.remove(video: video) }
        for record in records where !record.isCopy && !record.missing {
            let id = record.id
            if known[id.uuidString] == nil && current != id && !pending.contains(id) && !waitingForPower.contains(id) {
                pending.append(id)
            }
        }
        await refreshCounts()
        publish()
        kick()
    }

    /// Looks again at videos that were found to have no words.
    public func startOver() async {
        await database.forgetEmpty()
        await scan()
    }

    /// A video that was waiting for mains power is tried again once it is back.
    public func powerCheck() {
        guard settings.enabled, !waitingForPower.isEmpty, !power.onBattery else { return }
        pending += waitingForPower
        waitingForPower = []
        kick()
    }

    /// Returns once nothing is being read.
    public func idle() async {
        while let running = worker { await running.value }
    }

    private func kick() {
        guard settings.enabled, worker == nil, !pending.isEmpty else {
            if worker == nil, pending.isEmpty, !waitingForPower.isEmpty, state.message != Messages.spokenWaitingForPower {
                state.message = Messages.spokenWaitingForPower
                publish()
            }
            return
        }
        let mine = generation
        worker = Task { [weak self] in await self?.drain(mine) }
    }

    // MARK: One video at a time

    enum Outcome: Equatable, Sendable {
        /// What to store, and a sentence for the status line when something went wrong on the way.
        case store(TranscriptDB.Source, [Cue], note: String)
        /// Nothing can be stored now; the video is tried again at the next scan.
        case failed(String)
        case needsPower
        case stopped
    }

    /// A line about the video being read. It arrives a moment after it was
    /// said, so one about a video that has since been finished is dropped.
    private func note(_ text: String, _ mine: Int, about id: UUID) {
        guard mine == generation, current == id else { return }
        state.message = text
        publish()
    }

    private func drain(_ mine: Int) async {
        var lastNote = ""
        while mine == generation, settings.enabled, !Task.isCancelled, !pending.isEmpty {
            let id = pending.removeFirst()
            guard let record = await library.record(id), !record.isCopy, !record.missing else { continue }
            guard mine == generation else { return }
            current = id
            state.isWorking = true
            state.message = Messages.spokenReading(record.title)
            publish()
            let settings = self.settings
            let outcome = await index(record, settings: settings) { [weak self] text in
                Task { await self?.note(text, mine, about: id) }
            }
            guard mine == generation, !Task.isCancelled else { return }
            current = nil
            switch outcome {
            case .store(let source, let cues, let note):
                let stored = await database.replace(video: record.id.uuidString, source: source, cues: cues)
                lastNote = stored ? note : Messages.spokenCannotWrite
            case .failed(let why):
                lastNote = why
            case .needsPower:
                waitingForPower.append(id)
            case .stopped:
                return
            }
            await refreshCounts()
            guard mine == generation else { return }
        }
        guard mine == generation else { return }
        worker = nil
        state.isWorking = false
        state.message = waitingForPower.isEmpty ? lastNote : Messages.spokenWaitingForPower
        publish()
        // Something may have been queued while the last video was being stored.
        kick()
    }

    /// Runs a tool to its end and says whether it worked. Cancelling the task stops it.
    private nonisolated func ran(_ executable: String, _ arguments: [String], _ environment: [String: String]) async -> Bool {
        let request = ProcessRequest(executable: executable, arguments: arguments, environment: environment)
        return (try? await runner.run(request))?.outcome.succeeded == true
    }

    /// Works out what was said in one video. Stores nothing itself.
    nonisolated func index(_ record: LibraryRecord, settings: SpokenSettings,
                           report: @escaping @Sendable (String) -> Void) async -> Outcome {
        let registry = tools()
        guard let ffmpeg = registry.path(.ffmpeg) else { return .failed(Messages.noConverter) }
        let environment = registry.environment()
        let fm = FileManager.default
        let temp = scratch.appendingPathComponent("spoken-" + UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // This folder is the indexer's own scratch space, made a moment ago.
        defer { try? fm.removeItem(at: temp) }

        // 1. Captions inside the file itself.
        let embedded = temp.appendingPathComponent("inside.srt")
        if await ran(ffmpeg, Captions.embeddedArguments(input: record.path, output: embedded.path), environment),
           let text = try? String(contentsOf: embedded, encoding: .utf8) {
            let cues = Captions.chunk(Captions.parse(text))
            if !cues.isEmpty { return .store(.file, cues, note: "") }
        }
        if Task.isCancelled { return .stopped }

        // 2. The site's own captions.
        let folder = temp.appendingPathComponent("site", isDirectory: true)
        if let toolchain = YtdlpCommand.Toolchain(registry: registry),
           let arguments = Captions.fetchArguments(link: record.link, languages: settings.languages, folder: folder.path,
                                                   cookiesFile: settings.cookiesFile, toolchain: toolchain) {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            report(Messages.spokenFetching(record.title))
            _ = await clock.limited(to: Self.fetchLimit) { [self] in
                await ran(toolchain.ytdlp, arguments, toolchain.environment)
            }
            if let name = (try? fm.contentsOfDirectory(atPath: folder.path))?.sorted().first(where: { $0.lowercased().hasSuffix(".vtt") }),
               let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) {
                let cues = Captions.chunk(Captions.parse(text))
                if !cues.isEmpty { return .store(.site, cues, note: "") }
            }
        }
        if Task.isCancelled { return .stopped }

        // 3. Listening to it, on this Mac.
        guard settings.listen else { return .store(.none, [], note: "") }
        guard recognizer.availability() == .ready else { return .store(.none, [], note: Messages.spokenCannotListen) }
        if power.onBattery { return .needsPower }
        let pieces = temp.appendingPathComponent("pieces", isDirectory: true)
        try? fm.createDirectory(at: pieces, withIntermediateDirectories: true)
        guard await ran(ffmpeg, Captions.audioChunkArguments(input: record.path, folder: pieces.path), environment) else {
            return Task.isCancelled ? .stopped : .store(.none, [], note: "")
        }
        let names = ((try? fm.contentsOfDirectory(atPath: pieces.path)) ?? []).filter { $0.hasSuffix(".wav") }.sorted()
        var words: [TimedWord] = []
        for (index, name) in names.enumerated() {
            if Task.isCancelled { return .stopped }
            report(Messages.spokenListening(record.title, part: index + 1, of: names.count))
            let offset = Double(index * Captions.chunkSeconds)
            for word in await recognizer.words(in: pieces.appendingPathComponent(name)) {
                words.append(TimedWord(start: offset + word.start, text: word.text))
            }
        }
        if Task.isCancelled { return .stopped }
        return words.isEmpty ? .store(.none, [], note: "") : .store(.speech, Captions.passages(from: words), note: "")
    }
}
