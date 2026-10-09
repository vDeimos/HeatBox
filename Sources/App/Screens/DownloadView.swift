// DownloadView.swift: paste a link, see what it is, choose a version.
//
// The screen holds a `DownloadDraft` and draws it. What the choices are, what
// they come to as a recipe and where the files go are the engine's decisions.

import AppKit
import Engine
import SwiftUI

/// What is shown over the Download screen.
enum DownloadPanel: String, Identifiable {
    case customize, formats, comments, presets

    var id: String { rawValue }
}

@MainActor
final class DownloadModel: ObservableObject {
    @Published var panel: DownloadPanel?
    /// The panel to go back to when the one on top is closed.
    private var returnPanel: DownloadPanel?
    /// The rows ticked in "All formats".
    @Published var formatPicks: Set<String> = []
    /// The chapter lists found in the video's comments, once they have been read.
    @Published var comments: CommentChapters.Found?
    @Published var commentsLoading = false
    private var commentsTask: Task<Void, Never>?

    @Published var input = ""
    @Published var isLoading = false
    @Published var draft: DownloadDraft?
    @Published var errorText: String?
    /// Set when the link names one video that also sits in a playlist.
    @Published var playlistAlternative: String?
    /// Earlier downloads of the video on screen whose files are still there.
    @Published var earlier: [LibraryRecord] = []
    var library: LibraryRepository?
    /// Asking "Download all 40?" before a playlist or several links start.
    @Published var confirmingMany = false
    /// The start time chosen with "Later", kept while a large batch is confirmed.
    var pendingStart: Date?

    private let settings: SettingsModel
    private let tools: ToolsModel
    private let queue: QueueModel
    private let nav: Navigation
    private var lookupTask: Task<Void, Never>?

    init(settings: SettingsModel, tools: ToolsModel, queue: QueueModel, nav: Navigation) {
        self.settings = settings
        self.tools = tools
        self.queue = queue
        self.nav = nav
    }

    /// A link that arrived from somewhere else: a browser, a drop, a file.
    /// It fills in this screen and is looked up; nothing is downloaded.
    func take(link: String) {
        // A drop does not bring the window forward by itself, so do it here.
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.isMiniaturized {
            window.deminiaturize(nil)
        }
        NSApp.windows.first(where: { $0.canBecomeMain && $0 !== SettingsWindow.shared.window })?.makeKeyAndOrderFront(nil)
        input = link
        nav.screen = .download
        lookup()
    }

    func paste() {
        if let text = NSPasteboard.general.string(forType: .string) {
            input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func reset() {
        lookupTask?.cancel()
        lookupTask = nil
        isLoading = false
        errorText = nil
        draft = nil
        playlistAlternative = nil
        earlier = []
        panel = nil
        returnPanel = nil
        formatPicks = []
        commentsTask?.cancel()
        commentsTask = nil
        comments = nil
        commentsLoading = false
    }

    func lookup() {
        reset()
        switch LinkInput.read(input) {
        case .none:
            errorText = Messages.noLink
        case .several(let links):
            draft = DownloadDraft(target: .links(links))
        case .one(let link, let playlist):
            probe(link, playlistAlternative: playlist)
        }
    }

    /// The person asked for the whole playlist a single video belongs to.
    func lookupPlaylistInstead() {
        guard let link = playlistAlternative else { return }
        reset()
        probe(link, playlistAlternative: nil)
    }

    private func probe(_ link: String, playlistAlternative alternative: String?) {
        isLoading = true
        let registry = tools.registry
        let request = Probe.Request(link: link, cookiesFile: AppModel.shared.signInFile)
        lookupTask = Task { [weak self] in
            let result = await Probe.lookUp(request, tools: registry)
            guard let self, !Task.isCancelled else { return }
            self.isLoading = false
            self.lookupTask = nil
            do {
                self.draft = try DownloadDraft(result)
                if case .video(let media) = result {
                    self.playlistAlternative = alternative
                    if let library = self.library {
                        self.earlier = await library.earlier(videoID: media.facts.id, site: media.site)
                    }
                }
            } catch let failure as ProbeFailure {
                // A tool that has gone missing shows the setup screen.
                if failure.kind == .toolMissing { self.tools.refresh() }
                if failure.kind != .stopped { self.errorText = failure.message }
            } catch {
                self.errorText = Messages.unreadable
            }
        }
    }

    func cancelLookup() {
        lookupTask?.cancel()
        lookupTask = nil
        isLoading = false
    }

    var rules: FolderRules { settings.value.folders }
    var defaults: DownloadDefaults { DownloadDefaults(settings.value) }

    // MARK: Presets and Customize

    /// The recipe that Download would hand the queue right now.
    var currentRecipe: DownloadRecipe? { draft?.recipe(defaults: defaults) }
    var issues: [RecipeIssue] { draft?.issues(defaults: defaults) ?? [] }
    var hasErrors: Bool { issues.contains { $0.severity == .error } }
    var isReady: Bool { draft?.isReady(defaults: defaults) ?? false }

    var preview: CommandPreview {
        guard let draft else { return CommandPreview(problem: Messages.previewNeedsChoice) }
        return draft.preview(defaults: defaults, rules: rules, speedLimitKB: settings.value.speedLimitKB,
                             archiveFile: AppModel.shared.paths.archiveFile.path,
                             toolchain: YtdlpCommand.Toolchain(registry: tools.registry))
    }

    func apply(_ preset: Preset) { draft?.apply(preset) }

    func customize() {
        draft?.customize(defaults: defaults)
        if draft?.custom != nil { panel = .customize }
    }

    func dropCustom() { draft?.dropCustom() }

    func showFormats(returnTo: DownloadPanel?) {
        returnPanel = returnTo
        panel = .formats
    }

    func useFormats() {
        draft?.useFormats(formatPicks, defaults: defaults)
        returnPanel = nil
        panel = .customize
    }

    func showPresets() {
        returnPanel = panel
        panel = .presets
    }

    /// Opens the comment picker and reads the comments the first time.
    func showComments() {
        returnPanel = panel
        panel = .comments
        guard comments == nil, !commentsLoading, let media = draft?.media,
              let toolchain = YtdlpCommand.Toolchain(registry: tools.registry) else { return }
        commentsLoading = true
        let recipe = currentRecipe ?? DownloadRecipe()
        commentsTask = Task { [weak self] in
            let found = await CommentChapters.find(link: media.link, cookiesFile: AppModel.shared.signInFile, cookieBrowser: recipe.cookieBrowser,
                                                   proxy: recipe.proxy, toolchain: toolchain)
            guard let self, !Task.isCancelled, self.draft?.media?.link == media.link else { return }
            self.comments = found
            self.commentsLoading = false
        }
    }

    func closePanel() {
        panel = returnPanel
        returnPanel = nil
    }

    /// Download or Later was pressed: bulk work asks first, with a count.
    func begin(startAt: Date?) {
        guard let draft, isReady else { return }
        pendingStart = startAt
        if draft.target.needsConfirmation {
            confirmingMany = true
        } else {
            download(startAt: startAt)
        }
    }

    func download(startAt: Date?) {
        guard let draft, isReady else { return }
        let requests = draft.requests(defaults: defaults, startAfter: startAt)
        guard !requests.isEmpty else { return }
        let folder = draft.folder(rules: rules) ?? rules.mainFolder
        let verdict = DiskSpace.verdict(needed: draft.estimatedBytes, available: DiskSpace.available(at: folder))
        if let sentence = DiskSpace.warning(verdict) {
            errorText = sentence
            pendingStart = nil
            return
        }
        if let choice = draft.choice { settings.value.lastChoiceID = choice.id }
        queue.add(requests)
        input = ""
        pendingStart = nil
        reset()
        nav.screen = .queue
    }
}

struct DownloadView: View {
    @ObservedObject private var model = AppModel.shared.download
    @ObservedObject private var settings = AppModel.shared.settings
    @Environment(\.palette) private var p

    private func bind<Value>(_ keyPath: WritableKeyPath<DownloadDraft, Value>, _ fallback: Value) -> Binding<Value> {
        Binding(get: { model.draft?[keyPath: keyPath] ?? fallback },
                set: { model.draft?[keyPath: keyPath] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            linkBar
            if model.isLoading {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(Messages.lookingUp)
                        .font(p.font(13))
                        .foregroundColor(p.subtext)
                    Button("Cancel") { model.cancelLookup() }
                        .buttonStyle(PillButtonStyle())
                }
            }
            if let error = model.errorText {
                Text(error)
                    .font(p.font(13))
                    .foregroundColor(p.bad)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if Messages.suggestsToolUpdate(error) {
                    HStack(spacing: 10) {
                        Button("Update yt-dlp") { AppModel.shared.tools.updateYtdlp() }
                            .buttonStyle(PillButtonStyle(kind: .primary))
                            .disabled(AppModel.shared.tools.isBusy)
                        ProvisionLine()
                    }
                }
            }
            if let draft = model.draft {
                targetGroup(draft)
                choiceList(draft)
                optionsGroup(draft)
            } else if !model.isLoading && model.errorText == nil {
                EmptyState(title: "Paste a link",
                           text: "Copy the address of a video page, then choose Paste. One video, several links, a playlist or a channel all work.")
            }
        }
        .alert("Download \(model.draft?.target.count ?? 0) videos?", isPresented: $model.confirmingMany) {
            Button(model.pendingStart == nil ? "Download all \(model.draft?.target.count ?? 0)"
                                             : "Schedule all \(model.draft?.target.count ?? 0)") {
                model.download(startAt: model.pendingStart)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This is a playlist, a channel, or several links, not a single video. Nothing downloads until you confirm.")
        }
        .sheet(item: $model.panel) { panel in
            Themed {
                switch panel {
                case .customize: CustomizeView(model: model)
                case .formats: FormatInspector(model: model)
                case .comments: CommentChapterPicker(model: model)
                case .presets: ManagePresetsView(model: model)
                }
            }
        }
    }

    /// The person's own recipe, when one is in use.
    private func customRow(_ custom: Customization) -> some View {
        HStack(spacing: 12) {
            RadioMark(on: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(custom.name)
                    .font(p.font(13, .semibold))
                    .foregroundColor(p.text)
                    .lineLimit(1)
                Text(model.issues.first(where: { $0.severity == .error })?.message
                     ?? "Your own settings. Pick a version above to go back to the explained choices.")
                    .font(p.font(12))
                    .foregroundColor(model.hasErrors ? p.bad : p.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Using \(custom.name)")
    }

    /// The ways to a recipe of the person's own: presets, the format table, Customize.
    private func moreControlRow(_ draft: DownloadDraft) -> some View {
        HStack(spacing: 10) {
            RowSymbol(name: "slider.horizontal.3")
            Text("More control")
                .font(p.font(13))
                .foregroundColor(p.text)
            Spacer(minLength: 8)
            PresetsMenu(model: model)
            if draft.media != nil {
                Button("All Formats…") { model.showFormats(returnTo: nil) }
                    .buttonStyle(PillButtonStyle())
            }
            Button("Customize…") { model.customize() }
                .buttonStyle(PillButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var linkBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Video link, or several, one per line")
                .font(p.font(12))
                .foregroundColor(p.subtext)
            HStack(alignment: .top, spacing: 8) {
                TextField("https://…", text: $model.input, axis: .vertical)
                    .lineLimit(2...6)
                    .textFieldStyle(.plain)
                    .font(p.font(13))
                    .foregroundColor(p.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .fieldChrome()
                    .onSubmit { model.lookup() }
                    .accessibilityLabel("Video link")
                Button("Paste") {
                    model.paste()
                    model.lookup()
                }
                .buttonStyle(PillButtonStyle())
                .accessibilityLabel("Paste link and look it up")
                // Once a video is on screen, Download is the main button instead.
                Button("Look Up") { model.lookup() }
                    .buttonStyle(PillButtonStyle(kind: model.draft == nil ? .primary : .plain))
                    .disabled(model.isLoading)
            }
        }
    }

    private func saveRow(_ draft: DownloadDraft) -> some View {
        HStack(spacing: 12) {
            RowSymbol(name: "folder")
            Text("Save to")
                .font(p.font(13))
                .foregroundColor(p.text)
            Spacer(minLength: 8)
            Text(draft.destination(rules: settings.value.folders))
                .font(p.font(13))
                .foregroundColor(p.subtext)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Change…") { SettingsWindow.shared.show(.folders) }
                .buttonStyle(PillButtonStyle())
                .accessibilityLabel("Change folders in Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// The video that was found: its picture with its length, its name, and
    /// whether Download can be pressed.
    private func videoHeader(_ media: MediaFacts) -> some View {
        HStack(alignment: .top, spacing: 16) {
            AsyncImage(url: media.thumbnail) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    p.surface1
                }
            }
            .frame(width: 176, height: 99)
            .clipped()
            .overlay(alignment: .bottomTrailing) { DurationBadge(text: media.duration) }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(p.outline, lineWidth: 1))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(media.facts.title)
                    .font(p.font(17, .semibold))
                    .foregroundColor(p.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text([media.facts.uploader, media.duration, media.site].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(p.font(13))
                    .foregroundColor(p.subtext)
                    .lineLimit(1)
                if model.isReady {
                    Tag(text: "Ready to download", symbol: "checkmark", fill: p.wash(p.good), foreground: p.good)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func targetGroup(_ draft: DownloadDraft) -> some View {
        switch draft.target {
        case .video(let media):
            videoHeader(media)
            if model.playlistAlternative != nil || !model.earlier.isEmpty {
                Grouped {
                    if model.playlistAlternative != nil {
                        HStack(spacing: 12) {
                            RowSymbol(name: "list.bullet.rectangle")
                            Text("This video is part of a playlist.")
                                .font(p.font(13))
                                .foregroundColor(p.text)
                            Spacer(minLength: 8)
                            Button("Get the Whole Playlist") { model.lookupPlaylistInstead() }
                                .buttonStyle(PillButtonStyle())
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                    }
                    if !model.earlier.isEmpty {
                        if model.playlistAlternative != nil { RowDivider() }
                        Text(Messages.alreadyInLibrary(versions: model.earlier.map(\.choice)))
                            .font(p.font(13))
                            .foregroundColor(p.warn)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                }
            }
        case .playlist(let playlist):
            Grouped {
                summary(symbol: "list.bullet.rectangle", title: playlist.title,
                        line: ["Playlist", playlist.site, playlist.uploader, Messages.itemCount(playlist.count)]
                            .filter { !$0.isEmpty }.joined(separator: " · "),
                        note: "This link is a list, not one video. If you wanted a single video, open that video and copy its own link.")
            }
        case .links(let links):
            Grouped {
                summary(symbol: "square.stack.3d.up", title: "\(links.count) links",
                        line: "Each one is read, then saved in its own site's folder.",
                        note: "The version you choose below applies to all of them.")
            }
        }
    }

    private func summary(symbol: String, title: String, line: String, note: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundColor(p.accent)
                .frame(width: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(p.font(15, .semibold)).foregroundColor(p.text).lineLimit(2)
                Text(line).font(p.font(12)).foregroundColor(p.subtext)
                Text(note).font(p.font(12)).foregroundColor(p.subtext).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func choiceList(_ draft: DownloadDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Grouped(title: "Version") {
                ForEach(Array(draft.choices.enumerated()), id: \.element.id) { pair in
                    if pair.offset > 0 {
                        RowDivider()
                    }
                    ChoiceRow(choice: pair.element,
                              selected: draft.selectedID == pair.element.id,
                              isLastChoice: settings.value.lastChoiceID == pair.element.id) {
                        model.draft?.pick(pair.element.id)
                    }
                }
            }
            // Tab reaches the versions; the up and down arrows pick one.
            .focusShape(radius: 10)
            .keyboardList(enabled: !draft.choices.isEmpty)
            .onMoveCommand { direction in
                let way: GridWalk.Direction
                switch direction {
                case .up: way = .up
                case .down: way = .down
                default: return
                }
                let at = draft.choices.firstIndex { $0.id == draft.selectedID }
                if let next = GridWalk.move(from: at, groups: [draft.choices.count], columns: 1, way) {
                    model.draft?.pick(draft.choices[next].id)
                }
            }
            Caption("A bigger number means a sharper picture and a bigger file.")
        }
    }

    /// Whether the files' folder is known before anything is looked up further.
    private func showsSaveRow(_ draft: DownloadDraft) -> Bool {
        if case .links = draft.target { return false }
        return true
    }

    /// Everything about this download besides its version: a clip, chapters,
    /// where it is saved, and the way to full control.
    private func optionsGroup(_ draft: DownloadDraft) -> some View {
        Grouped {
            clipRows(draft)
            if showsSaveRow(draft) {
                saveRow(draft)
                RowDivider()
            }
            if let custom = draft.custom {
                customRow(custom)
                RowDivider()
            }
            moreControlRow(draft)
        }
    }

    @ViewBuilder
    private func clipRows(_ draft: DownloadDraft) -> some View {
        if case .video(let media) = draft.target, draft.canClip {
            SwitchRow(title: "Download only part of this video", symbol: "scissors", isOn: bind(\.clipOn, false))
            RowDivider()
            if draft.clipOn {
                ClipControls(duration: media.seconds, start: bind(\.clipStart, 0), end: bind(\.clipEnd, media.seconds),
                             chapters: media.chapters.map(\.start))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                RowDivider()
                if draft.showsGuidedSwitches {
                    SwitchRow(title: "Cut exactly at these times",
                              detail: settings.value.exactCut
                                ? "Takes a little longer, because the clip is re-encoded."
                                : "A fast cut may start a second or two before the time you chose.",
                              symbol: "timer",
                              isOn: $settings.value.exactCut)
                    RowDivider()
                } else if draft.clipOverridesChapters {
                    NoteRow(text: Messages.customizeClipWinsOverChapters, warning: true)
                    RowDivider()
                }
            }
            if draft.canSplitChapters && draft.showsGuidedSwitches {
                SwitchRow(title: "Also save each chapter as its own file",
                          detail: "\(media.chapters.count) chapters, in a folder beside the video.",
                          symbol: "list.number",
                          isOn: bind(\.splitChapters, false))
                RowDivider()
            }
        }
    }
}

/// Asks for a time of day. The download starts the next time the clock shows it.
@MainActor
private func askForStartTime() -> Date? {
    let alert = NSAlert()
    alert.messageText = "Start the download at…"
    alert.informativeText = "\(Engine.productName) starts it the next time the clock shows this time. \(Engine.productName) needs to stay open until then, and the Mac needs to be awake."
    let picker = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 110, height: 24))
    picker.datePickerStyle = .textFieldAndStepper
    picker.datePickerElements = .hourMinute
    picker.dateValue = Date().addingTimeInterval(3600)
    alert.accessoryView = picker
    alert.addButton(withTitle: "Schedule")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    return Schedule.nextOccurrence(matching: picker.dateValue, after: Date())
}

/// The strip pinned to the bottom of the Download screen: what will be saved,
/// and the buttons that start it, now or later.
struct DownloadFooter: View {
    @ObservedObject private var model = AppModel.shared.download
    @ObservedObject private var settings = AppModel.shared.settings
    @Environment(\.palette) private var p

    private func atTime(_ hour: Int) -> Date {
        Schedule.nextOccurrence(hour: hour, minute: 0, after: Date())
    }

    private func timeLabel(_ hour: Int) -> String {
        "At " + atTime(hour).formatted(date: .omitted, time: .shortened)
    }

    /// Download, with the ways to start it later behind the arrow beside it.
    private func startButton(_ draft: DownloadDraft) -> some View {
        HStack(spacing: 0) {
            Button(draft.target.needsConfirmation ? "Download All \(draft.target.count)" : "Download") {
                model.begin(startAt: nil)
            }
            // Return in the link box looks the link up; Cmd-Return downloads it.
            .keyboardShortcut(.return, modifiers: .command)
            .help("Download (\u{2318}\u{21A9})")
            .buttonStyle(.plain)
            .font(p.font(13, .semibold))
            .foregroundColor(p.onFill)
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
            .focusShape(radius: 7, inset: 2)
            Rectangle()
                .fill(p.onFill.opacity(0.28))
                .frame(width: 1, height: 18)
                .accessibilityHidden(true)
            Menu {
                Button("In 1 Hour") { model.begin(startAt: Date().addingTimeInterval(3600)) }
                Button(timeLabel(2)) { model.begin(startAt: atTime(2)) }
                Button(timeLabel(7)) { model.begin(startAt: atTime(7)) }
                Divider()
                Button("Pick a Time…") {
                    if let when = askForStartTime() { model.begin(startAt: when) }
                }
            } label: {
                Text("Later")
                    .font(p.font(13, .medium))
                    .foregroundColor(p.onFill)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: 30)
            .accessibilityLabel("Download later")
        }
        .background(p.fill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .opacity(model.isReady ? 1 : 0.45)
        .disabled(!model.isReady)
        // The menu draws its own words; on the accent they are always light.
        .environment(\.colorScheme, .dark)
    }

    private func bar(_ draft: DownloadDraft) -> some View {
        HStack(spacing: 12) {
            Text(draft.summary(rules: settings.value.folders))
                .font(p.font(12))
                .foregroundColor(p.subtext)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            startButton(draft)
        }
    }

    var body: some View {
        if let draft = model.draft {
            if Chrome.glass {
                // A bar of glass that floats over the end of the page.
                bar(draft)
                    .padding(.leading, 18)
                    .padding(.trailing, 12)
                    .frame(height: 54)
                    .floatingPanel(radius: 18)
                    .frame(maxWidth: 680 + 24)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                    .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 0) {
                    RowDivider()
                    bar(draft)
                        .frame(maxWidth: 680)
                        .padding(.horizontal, 28)
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                }
                .background(p.base)
            }
        }
    }
}
