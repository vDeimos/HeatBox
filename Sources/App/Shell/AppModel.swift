// AppModel.swift: the one place where the app's parts are made and joined.
//
// The engine decides; these models hold copies of its state on the main
// actor for the views to draw, and forward what the person asks for (plan
// Rules 1 and 8).

import AppKit
import Engine
import SwiftUI

/// How this launch was started.
enum Launch {
    static let arguments = CommandLine.arguments

    /// The value of an option written as one word, `--name=value`. AppKit
    /// takes a word on the command line that does not start with a dash for a
    /// file to open, and an app opened "with a file" may get no ordinary
    /// window, so a value never stands alone.
    static func value(of option: String) -> String? {
        let prefix = option + "="
        guard let argument = arguments.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return String(argument.dropFirst(prefix.count))
    }

    /// `--support-folder=<path>` keeps everything the app stores in another
    /// folder, so a check or a trial run never touches the person's own data.
    static var paths: AppPaths {
        if let folder = value(of: "--support-folder"), !folder.isEmpty {
            return AppPaths(root: URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true))
        }
        return .standard()
    }

    /// `--pretend-missing=deno,ffmpeg` makes those tools look absent, to see the setup screen.
    static var pretendMissing: Set<String> {
        Set((value(of: "--pretend-missing") ?? "").split(separator: ",").map(String.init))
    }

    /// `--launch-check` opens the app, waits until its window is up and the
    /// queue is read, says so and quits. CI runs it against the built app.
    static var isLaunchCheck: Bool { arguments.contains("--launch-check") }

    /// Kept for as long as the app runs.
    nonisolated(unsafe) private static var dataFolderLock: InstanceLock?

    /// Takes the data folder for this copy. False when another running copy
    /// has it: two copies on one folder would restart each other's downloads
    /// and overwrite each other's settings, so this one must not start.
    static func claimDataFolder() -> Bool {
        switch InstanceLock.claim(paths.root) {
        case .held(let lock):
            dataFolderLock = lock
            return true
        case .taken:
            return false
        case .unavailable:
            return true
        }
    }

    /// Brings the copy that is already running to the front.
    static func showRunningCopy() {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let mine = ProcessInfo.processInfo.processIdentifier
        NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first { $0.processIdentifier != mine }?
            .activate(options: [.activateAllWindows])
    }

    /// Only an app in a bundle may post notifications; `swift run` has none.
    static var isBundled: Bool { Bundle.main.bundleIdentifier != nil }
}

/// A value several tasks read and the main actor replaces.
final class Shared<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

enum Screen: String, CaseIterable, Identifiable {
    case download, queue, library, following, convert

    var id: String { rawValue }

    var label: String {
        switch self {
        case .download: return "Download"
        case .queue: return "Queue"
        case .library: return "Library"
        case .following: return "Following"
        case .convert: return "Convert"
        }
    }

    var symbol: String {
        switch self {
        case .download: return "arrow.down.to.line"
        case .queue: return "list.bullet"
        case .library: return "square.grid.2x2"
        case .following: return "person.crop.circle.badge.checkmark"
        case .convert: return "arrow.left.arrow.right"
        }
    }
}

@MainActor
final class Navigation: ObservableObject {
    @Published var screen: Screen = .download
}

@MainActor
final class AppModel {
    static let shared = AppModel(paths: Launch.paths)

    let paths: AppPaths
    let nav = Navigation()
    let settings: SettingsModel
    let tools: ToolsModel
    let queue: QueueModel
    let download: DownloadModel
    let library: LibraryModel
    let following: FollowingModel
    let presets: PresetsModel
    let convert: ConvertModel
    let spoken: SpokenModel
    let commands = CommandCenter()
    let tour = TourCenter()
    let updates = UpdateChecker()
    private var started = false

    /// The saved YouTube sign-in, when the person switched it on and made one.
    var signInFile: String? { SignIn.file(for: settings.value, paths: paths) }

    init(paths: AppPaths) {
        self.paths = paths
        try? paths.createFolders()
        let settings = SettingsModel(store: SettingsStore(paths: paths))
        let tools = ToolsModel(paths: paths, settings: settings.value, pretendMissing: Launch.pretendMissing)
        // The worker asks for the tools at the start of every run, so a tool
        // chosen in Settings is used by the next download.
        let current = tools.current
        let repo = LibraryRepository(paths: paths)
        var worker = ToolJobWorker(tools: { current.value })
        worker.library = repo
        let engineQueue = JobQueue(paths: paths, worker: worker,
                                   settings: settings.value.queueSettings(cookiesFile: SignIn.file(for: settings.value, paths: paths)))
        let queue = QueueModel(queue: engineQueue)
        self.settings = settings
        self.tools = tools
        self.queue = queue
        let download = DownloadModel(settings: settings, tools: tools, queue: queue, nav: nav)
        download.library = repo
        self.download = download
        library = LibraryModel(repo: repo, download: { AppModel.shared.download }, folders: { [weak settings] in
            guard let folders = settings?.value.folders else { return [] }
            return [folders.mainFolder, folders.audioFolder] + folders.perSite.values
        })
        presets = PresetsModel(store: PresetStore(paths: paths))
        following = FollowingModel(store: FollowStore(paths: paths), tools: tools, settings: settings, queue: queue, nav: nav)
        convert = ConvertModel(center: ConvertCenter(tools: { current.value }, library: repo), tools: tools, settings: settings)
        spoken = SpokenModel(indexer: SpokenIndexer(database: TranscriptDB(paths: paths), library: repo, tools: { current.value },
                                                    recognizer: MacSpeechRecognizer(), power: BatteryPower()))
        library.spoken = spoken

        settings.onChange = { [weak self, weak tools] new, old in
            if new.toolPaths != old.toolPaths { tools?.use(new) }
            if new.theme != old.theme { NSApp.appearance = new.theme.appearance }
            self?.settingsChanged(from: old)
        }
        convert.onIdle = { [weak self] in self?.quitIfIdleAndHidden() }
        queue.onChange = { [weak self] old, new in
            self?.queueChanged(from: old, to: new)
        }
    }

    /// Called once, when the app has finished launching.
    func start() {
        guard !started else { return }
        started = true
        NSApp.appearance = settings.value.theme.appearance
        queue.start()
        tools.refreshVersions()
        // The one-time move from Phobos and YT-DLP Studio. It reads their data
        // and writes only here; what it brings is then read again.
        Task { [weak self] in
            guard let self else { return }
            if let summary = await Migration.runOnce(paths: paths, library: library.repo) {
                settings.reload()
                tools.use(settings.value)
                following.reload()
                presets.reload()
                library.notice = summary.sentence
            }
            // After the import, which brings settings only where none are saved.
            settings.keep()
            library.start()
            // After the import, so words Phobos already read are not read again.
            spoken.start(settings.value.spokenSettings(cookiesFile: signInFile, languageCode: Self.languageCode))
        }
        convert.start()
        updates.check()
    }

    private static var languageCode: String? { Locale.current.language.languageCode?.identifier }

    /// Hands a change in Settings, or a newly saved sign-in, to the parts that run with it.
    func settingsChanged(from old: AppSettings? = nil) {
        let new = settings.value
        let cookies = signInFile
        let queueSettings = new.queueSettings(cookiesFile: cookies)
        if old.map({ $0.queueSettings(cookiesFile: SignIn.file(for: $0, paths: paths)) }) != queueSettings {
            queue.update(queueSettings)
        }
        let spokenSettings = new.spokenSettings(cookiesFile: cookies, languageCode: Self.languageCode)
        if old.map({ $0.spokenSettings(cookiesFile: SignIn.file(for: $0, paths: paths), languageCode: Self.languageCode) }) != spokenSettings {
            spoken.apply(spokenSettings)
        }
    }

    private func queueChanged(from old: [Job], to new: [Job]) {
        for site in Set(new.map(\.site)) where !site.isEmpty && !settings.value.knownSites.contains(site) {
            settings.value.remember(site: site)
        }
        let counts = QueueCounts(new)
        SystemState.update(busy: counts.busy, active: counts.active)
        for ending in JobEnding.between(old, new) {
            switch ending {
            case .finished(let job):
                let finish = settings.value.finish
                if finish == .playNow, let first = job.files.first { Opener.play(first) }
                Notifier.finished(title: job.title, path: job.files.first, offerPlay: finish == .notifyAndOffer)
            case .failed(let job):
                Notifier.failed(title: job.title, reason: job.message)
            }
        }
        if counts.active == 0 && QueueCounts(old).active > 0 { quitIfIdleAndHidden() }
    }

    /// With the window closed, downloads carry on in the background. Once the
    /// last one finishes, the app quits by itself.
    private func quitIfIdleAndHidden() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.queue.counts.active == 0, !self.convert.hasRunning else { return }
            let windowOpen = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
            if !windowOpen { Quit.request() }
        }
    }
}

// MARK: - Settings

@MainActor
final class SettingsModel: ObservableObject {
    @Published var value: AppSettings {
        didSet {
            guard value != oldValue else { return }
            try? store.save(value)
            onChange?(value, oldValue)
        }
    }

    var onChange: ((_ new: AppSettings, _ old: AppSettings) -> Void)?
    private let store: SettingsStore

    /// Reads the file again, after something outside the Settings window wrote it.
    func reload() { value = store.load() }

    /// Saves the settings in use when no file holds them yet.
    func keep() { store.keep(value) }

    init(store: SettingsStore) {
        self.store = store
        value = store.load()
    }
}

// MARK: - Tools

@MainActor
final class ToolsModel: ObservableObject {
    @Published private(set) var statuses: [ToolStatus] = []
    /// Tool path -> the version it reported. Asked once per path.
    @Published private(set) var versions: [String: String] = [:]

    /// What installing or updating is doing, for the screens that offer it.
    enum Provision: Equatable {
        case idle
        case working(String, Double?)
        case done(String)
        case failed(String)
    }
    @Published private(set) var provision = Provision.idle
    var isBusy: Bool { if case .working = provision { return true } else { return false } }

    /// The registry the next lookup or download uses.
    let current: Shared<ToolRegistry>
    private let provisioner: ToolProvisioner
    private let paths: AppPaths
    private let pretendMissing: Set<String>
    private var settings: AppSettings

    init(paths: AppPaths, settings: AppSettings, pretendMissing: Set<String>) {
        self.paths = paths
        self.provisioner = ToolProvisioner(paths: paths)
        self.settings = settings
        self.pretendMissing = pretendMissing
        current = Shared(Self.registry(paths: paths, settings: settings, pretendMissing: pretendMissing))
        statuses = current.value.status()
    }

    private static func registry(paths: AppPaths, settings: AppSettings, pretendMissing: Set<String>) -> ToolRegistry {
        guard !pretendMissing.isEmpty else { return settings.registry(paths: paths) }
        return ToolRegistry(managedFolder: paths.bin.path, overrides: settings.toolOverrides, isExecutable: { path in
            !pretendMissing.contains((path as NSString).lastPathComponent) && FileManager.default.isExecutableFile(atPath: path)
        })
    }

    var registry: ToolRegistry { current.value }

    /// The tools a download cannot do without and that this Mac lacks.
    var missing: [Tool] { registry.missingForDownloads() }

    func use(_ settings: AppSettings) {
        self.settings = settings
        refresh()
    }

    /// Looks again: after Settings changed, and whenever the app comes to the front.
    func refresh() {
        current.value = Self.registry(paths: paths, settings: settings, pretendMissing: pretendMissing)
        let found = current.value.status()
        if found != statuses { statuses = found }
        refreshVersions()
    }

    // MARK: Installing and updating (Phase 10)

    /// Installs the app's own copy of these tools, one after another. Pressed by the person, never by itself.
    func install(_ tools: [Tool], then: (() -> Void)? = nil) {
        guard !isBusy, !tools.isEmpty else { return }
        provision = .working(Messages.installing(tools[0].rawValue), nil)
        Task { [weak self, provisioner] in
            do {
                try await provisioner.install(tools, step: { tool in
                    Task { @MainActor in self?.provision = .working(Messages.installing(tool.rawValue), nil) }
                }, progress: { fraction in
                    Task { @MainActor in
                        if case .working(let text, _) = self?.provision { self?.provision = .working(text, fraction) }
                    }
                })
                self?.provision = .done(tools.count == 1 ? Messages.installed(tools[0].rawValue) : Messages.installedAll)
                self?.refresh()
                then?()
            } catch let error as ToolInstallError {
                self?.provision = .failed(error.message)
            } catch {
                self?.provision = .failed(Messages.installUnreachable)
            }
        }
    }

    /// Installs everything this Mac does not have at all.
    func installMissingTools() {
        install(statuses.filter { !$0.found }.map(\.tool))
    }

    /// Looks for a newer yt-dlp and installs it, checked against the release's checksum. `then` runs after a success or when it is already the newest.
    func updateYtdlp(then: (() -> Void)? = nil) {
        guard !isBusy else { return }
        provision = .working(Messages.updating, nil)
        let running = version(of: .ytdlp)
        Task { [weak self, provisioner] in
            do {
                let outcome = try await provisioner.updateYtdlp(current: running, progress: { fraction in
                    Task { @MainActor in
                        if case .working(let text, _) = self?.provision { self?.provision = .working(text, fraction) }
                    }
                })
                switch outcome {
                case .alreadyCurrent(let version): self?.provision = .done(Messages.updateAlreadyCurrent(version))
                case .updated(_, let version): self?.provision = .done(Messages.updateDone(to: version))
                }
                self?.refresh()
                if let self, let location = self.registry.locate(.ytdlp), location.source == .userOverride {
                    self.provision = .done(Messages.updateOverridden)
                }
                then?()
            } catch let error as ToolInstallError {
                self?.provision = .failed(error.message)
            } catch {
                self?.provision = .failed(Messages.installUnreachable)
            }
        }
    }

    func version(of tool: Tool) -> String? {
        statuses.first { $0.tool == tool }?.location.flatMap { versions[$0.path] }
    }

    func refreshVersions() {
        let registry = self.registry
        for status in statuses {
            guard let path = status.location?.path, versions[path] == nil else { continue }
            Task { [weak self] in
                guard let version = await registry.version(of: status.tool) else { return }
                self?.versions[path] = version
            }
        }
    }
}

// MARK: - Queue

@MainActor
final class QueueModel: ObservableObject {
    @Published private(set) var jobs: [Job] = []
    /// False until the saved queue has been read at launch.
    @Published private(set) var isReady = false

    let queue: JobQueue
    var onChange: ((_ old: [Job], _ new: [Job]) -> Void)?

    init(queue: JobQueue) {
        self.queue = queue
    }

    var counts: QueueCounts { QueueCounts(jobs) }

    /// Reads the saved queue (before anything can be added) and then follows
    /// the engine's list. The engine publishes on every progress line; at most
    /// ten copies a second are drawn.
    func start() {
        Task { [weak self, queue] in
            await queue.restore()
            self?.isReady = true
            for await jobs in await queue.updates() {
                guard let self else { return }
                let old = self.jobs
                if jobs != old {
                    self.jobs = jobs
                    self.onChange?(old, jobs)
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    func add(_ requests: [JobRequest]) { Task { await queue.add(requests) } }
    func update(_ settings: QueueSettings) { Task { await queue.update(settings) } }
    func pause(_ id: UUID) { Task { await queue.pause(id) } }
    func resume(_ id: UUID) { Task { await queue.resume(id) } }
    func startNow(_ id: UUID) { Task { await queue.startNow(id) } }
    func cancel(_ id: UUID) { Task { await queue.cancel(id) } }
    func retry(_ id: UUID) { Task { await queue.retry(id) } }
    func remove(_ id: UUID) { Task { await queue.remove(id) } }
    func pauseAll() { Task { await queue.pauseAll() } }
    func resumeAll() { Task { await queue.resumeAll() } }
    func cancelAll() { Task { await queue.cancelAll() } }
    func clearFinished() { Task { await queue.clearFinished() } }
}

// MARK: - Spoken words

/// The main actor's copy of how far the reading of spoken words has got.
@MainActor
final class SpokenModel: ObservableObject {
    @Published private(set) var status = SpokenStatus()

    let indexer: SpokenIndexer
    private var timer: Timer?

    init(indexer: SpokenIndexer) {
        self.indexer = indexer
    }

    func start(_ settings: SpokenSettings) {
        Task { [weak self, indexer] in
            for await status in await indexer.updates() {
                self?.status = status
                SystemState.keepAwake(.reading, status.isWorking)
            }
        }
        apply(settings)
        // A video that is waiting for mains power is tried again once it is back.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [indexer] _ in
            Task { await indexer.powerCheck() }
        }
    }

    func apply(_ settings: SpokenSettings) { Task { await indexer.update(settings) } }
    /// A download arrived or a record left: look at what is new.
    func libraryChanged() { Task { await indexer.scan() } }
    func startOver() { Task { await indexer.startOver() } }
}
