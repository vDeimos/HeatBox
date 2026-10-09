// LibraryView.swift: everything downloaded, with pictures.
//
// The screen draws what `LibraryRepository` hands it and forwards what the
// person does. Search, sort, grouping, "missing" and Undo are the engine's.
import AppKit
import Engine
import SwiftUI

@MainActor
final class LibraryModel: ObservableObject {
    @Published var query = LibraryQuery() {
        didSet {
            if query != oldValue { reload() }
            if query.text != oldValue.text { refreshSpoken() }
        }
    }
    /// Moments in the videos where the typed words were said.
    @Published private(set) var spokenResults: [SpokenResult] = []
    var spoken: SpokenModel?
    private var spokenTask: Task<Void, Never>?
    @Published private(set) var sections: [LibrarySection] = []
    @Published private(set) var total = 0
    @Published var selectedID: UUID?
    /// The last file moved to the Trash, kept so the move can be undone.
    @Published var undo: TrashedRecord?
    @Published var notice: String?

    let repo: LibraryRepository
    private let download: () -> DownloadModel
    private let folders: () -> [String]
    private var generation = 0

    init(repo: LibraryRepository, download: @escaping () -> DownloadModel, folders: @escaping () -> [String]) {
        self.repo = repo
        self.download = download
        self.folders = folders
    }

    func start() {
        Task { [weak self, repo] in
            for await _ in await repo.changes() {
                self?.reload()
                self?.spoken?.libraryChanged()
            }
        }
        refreshFiles()
    }

    /// Looks again at where every file is, including the folders downloads are saved to.
    func refreshFiles() {
        let places = folders()
        Task { [repo] in
            let check = await repo.refreshFiles(searchIn: places)
            if check.found > 0 { self.notice = Messages.libraryFilesFound(check.found) }
        }
    }

    private func reload() {
        generation += 1
        let mine = generation
        let query = self.query
        Task { [repo] in
            let found = await repo.sections(matching: query)
            let count = await repo.count()
            guard mine == self.generation else { return }
            self.sections = found
            self.total = count
        }
    }

    var selected: LibraryRecord? {
        guard let selectedID else { return nil }
        return sections.lazy.flatMap(\.records).first { $0.id == selectedID }
    }

    func play(_ record: LibraryRecord) {
        guard !record.missing else { return }
        Opener.play(record.path)
        Task { await repo.setWatched(record.id, true) }
    }

    /// Looks the typed words up in what was said, a moment after typing stops.
    private func refreshSpoken() {
        spokenTask?.cancel()
        let typed = query.text
        guard let indexer = spoken?.indexer, spoken?.status.enabled == true else {
            spokenResults = []
            return
        }
        spokenTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let found = await indexer.search(typed)
            guard let self, !Task.isCancelled, self.query.text == typed else { return }
            self.spokenResults = found
        }
    }

    /// Plays a video at the moment the searched words were said.
    func playSpoken(_ result: SpokenResult) {
        let timed = Opener.play(result.record.path, at: result.start)
        Task { await repo.setWatched(result.record.id, true) }
        notice = timed ? nil : Messages.spokenOpenedFromStart(TimeText.clock(result.start))
    }

    /// Opens the Convert screen with this file on it.
    func convert(_ record: LibraryRecord) {
        AppModel.shared.nav.screen = .convert
        AppModel.shared.convert.load(record.path)
    }

    func setWatched(_ record: LibraryRecord, _ watched: Bool) {
        Task { await repo.setWatched(record.id, watched) }
    }

    func remove(_ record: LibraryRecord) {
        if selectedID == record.id { selectedID = nil }
        Task { await repo.remove(record.id) }
    }

    func trash(_ record: LibraryRecord) {
        if selectedID == record.id { selectedID = nil }
        Task {
            do {
                let trashed = try await repo.trash(record.id)
                undo = trashed.trashedAt == nil ? nil : trashed
                notice = trashed.trashedAt == nil ? Messages.libraryTakenOffList(record.title) : nil
            } catch let failure as LibraryFailure {
                notice = failure.message
            } catch {
                notice = Messages.libraryCannotTrash
            }
        }
    }

    func undoTrash() {
        guard let last = undo else { return }
        undo = nil
        Task {
            do { try await repo.undo(last) } catch let failure as LibraryFailure { notice = failure.message } catch { notice = Messages.libraryCannotPutBack }
        }
    }

    /// Fills in the Download screen with the link again; nothing is downloaded until it is pressed.
    func getAgain(_ record: LibraryRecord) {
        guard !record.link.isEmpty else { return }
        Task {
            // A file that is gone must not leave the download tool saying "already downloaded".
            await repo.forgetInArchive(record)
            download().take(link: record.link)
        }
    }
}

private enum Pictures {
    static let cache = NSCache<NSString, NSImage>()

    static func image(_ url: URL) -> NSImage? {
        if let cached = cache.object(forKey: url.path as NSString) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: url.path as NSString)
        return image
    }
}

/// The picture for a record, or a placeholder when none was saved.
private struct RecordPicture: View {
    let record: LibraryRecord
    @Environment(\.palette) private var p

    var body: some View {
        if let url = AppModel.shared.library.repo.thumbnailURL(named: record.thumbnail), let image = Pictures.image(url) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                p.surface1
                Image(systemName: record.isAudio ? "waveform" : "film").font(.system(size: 26)).foregroundColor(p.subtext)
            }
        }
    }
}

private struct LibraryCard: View {
    let record: LibraryRecord
    let selected: Bool
    /// Puts the keyboard on the tiles, so the arrow keys carry on from a click.
    let takeKeyboard: () -> Void
    @ObservedObject private var model = AppModel.shared.library
    @Environment(\.palette) private var p

    /// Where it came from, which version, how big: what tells two tiles apart.
    private var facts: String {
        if record.missing { return Messages.libraryFileMissing }
        var parts = [record.site, record.choice]
        if let bytes = record.bytes { parts.append(ByteText.string(bytes)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay(RecordPicture(record: record))
                .overlay(Color.black.opacity(record.missing ? 0.55 : 0))
                .clipped()
                .overlay(alignment: .bottomTrailing) { DurationBadge(text: record.duration) }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(p.outline, lineWidth: 1))
            Text(record.title)
                .font(p.font(13, .semibold))
                .foregroundColor(record.missing ? p.subtext : p.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(facts)
                .font(p.font(11))
                .foregroundColor(p.subtext)
                .lineLimit(1)
            if record.watched {
                Tag(text: "Watched", symbol: "checkmark", fill: p.control, foreground: p.text)
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(selected ? p.wash(p.accent) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? p.accent : Color.clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.play(record) }
        .onTapGesture {
            model.selectedID = selected ? nil : record.id
            takeKeyboard()
        }
        // A tile is a button for VoiceOver and the keyboard, not only for a mouse.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.selectedID = selected ? nil : record.id }
        .accessibilityAction(named: Opener.playLabel) { if !record.missing { model.play(record) } }
        .contextMenu {
            if !record.missing {
                Button(Opener.playLabel) { model.play(record) }
                Button("Quick preview") { PreviewCenter.shared.show(record.path) }
                Button("Show in Finder") { Opener.reveal(record.path) }
                Button(record.watched ? "Mark as unwatched" : "Mark as watched") { model.setWatched(record, !record.watched) }
                Divider()
                Button("Send to iPhone") { PhoneSender.send(record.path) }
                Button("Share…") { PhoneSender.shareMenu(record.path) }
                Button("Convert or cut…") { model.convert(record) }
                Divider()
                Button("Move to Trash") { model.trash(record) }
            } else if !record.link.isEmpty {
                Button("Get it again") { model.getAgain(record) }
            }
            if !record.link.isEmpty { Button("Copy the link") { Opener.copy(record.link) } }
            Button("Remove from the Library list") { model.remove(record) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(record.title), \(record.site)\(record.watched ? ", watched" : "")\(record.missing ? ", file moved or deleted" : "")")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction { model.selectedID = record.id }
    }
}

/// One thing to do with the selected video: its name, and a picture at the end.
private struct DetailAction: View {
    let title: String
    let symbol: String
    var kind: PillButtonStyle.Kind = .plain
    let action: () -> Void
    @Environment(\.palette) private var p
    private let hovering = State(initialValue: false)

    private var foreground: Color {
        switch kind {
        case .plain: return p.text
        case .primary: return p.onFill
        case .danger: return p.bad
        }
    }

    private var fill: Color {
        switch kind {
        case .plain: return p.control
        case .primary: return p.fill
        case .danger: return p.wash(p.bad)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(p.font(13, kind == .primary ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: symbol)
                    .font(p.font(13))
                    .accessibilityHidden(true)
            }
            .foregroundColor(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .brightness(hovering.wrappedValue ? (p.dark ? 0.06 : -0.04) : 0)
            .contentShape(Rectangle())
            .focusShape(radius: 8)
        }
        .buttonStyle(.plain)
        .onHover { hovering.wrappedValue = $0 }
    }
}

/// The selected video, down the right-hand side of the window.
private struct LibraryDetail: View {
    let record: LibraryRecord
    @ObservedObject private var model = AppModel.shared.library
    @Environment(\.palette) private var p

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).font(p.font(12)).foregroundColor(p.subtext).frame(width: 66, alignment: .leading)
            Text(value).font(p.font(12)).foregroundColor(p.text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var picture: some View {
        Color.clear.aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay(RecordPicture(record: record))
            .overlay(Color.black.opacity(record.missing ? 0.55 : 0))
            .clipped()
            .overlay {
                if !record.missing {
                    Button { PreviewCenter.shared.show(record.path) } label: {
                        Label("Preview", systemImage: "play.fill")
                            .font(p.font(12, .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .floatingBadge()
                            .environment(\.colorScheme, .dark)
                    }
                    .buttonStyle(.plain)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(p.outline, lineWidth: 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            picture
            HStack(alignment: .top, spacing: 8) {
                Text(record.title).font(p.font(15, .semibold)).foregroundColor(p.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button { model.selectedID = nil } label: {
                    Image(systemName: "xmark").font(p.font(11, .bold)).foregroundColor(p.subtext)
                        .frame(width: 22, height: 22).background(Circle().fill(p.control))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close details")
            }
            VStack(alignment: .leading, spacing: 5) {
                if !record.duration.isEmpty { fact("Length", record.duration) }
                if !record.choice.isEmpty { fact("Version", record.choice) }
                if let bytes = record.bytes, !record.missing { fact("Size", ByteText.string(bytes)) }
                if !record.site.isEmpty { fact("Site", record.site) }
                if !record.uploader.isEmpty { fact("Channel", record.uploader) }
                fact("Saved in", (record.folder as NSString).abbreviatingWithTildeInPath)
                fact("Added", record.added.formatted(date: .abbreviated, time: .shortened))
            }
            RowDivider()
            VStack(spacing: 7) {
                if !record.missing {
                    DetailAction(title: Opener.playLabel, symbol: "play.fill", kind: .primary) { model.play(record) }
                    DetailAction(title: "Show in Finder", symbol: "folder") { Opener.reveal(record.path) }
                    DetailAction(title: record.watched ? "Mark as unwatched" : "Mark as watched",
                                 symbol: record.watched ? "eye.slash" : "eye") { model.setWatched(record, !record.watched) }
                    DetailAction(title: "Convert or Cut…", symbol: "scissors") { model.convert(record) }
                    DetailAction(title: "Send to iPhone", symbol: "iphone") { PhoneSender.send(record.path) }
                    DetailAction(title: "Share…", symbol: "square.and.arrow.up") { PhoneSender.shareMenu(record.path) }
                } else {
                    Text(Messages.libraryFileMissingDetail).font(p.font(12)).foregroundColor(p.subtext)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !record.link.isEmpty {
                        DetailAction(title: "Get it again", symbol: "arrow.down.circle", kind: .primary) { model.getAgain(record) }
                    }
                    DetailAction(title: "Remove from the list", symbol: "minus.circle") { model.remove(record) }
                }
                if !record.link.isEmpty {
                    DetailAction(title: "Copy the link", symbol: "link") { Opener.copy(record.link) }
                }
            }
            if !record.missing {
                RowDivider()
                DetailAction(title: "Move to Trash", symbol: "trash", kind: .danger) { model.trash(record) }
                Text("The file goes to the Trash. Undo brings it back.")
                    .font(p.font(11)).foregroundColor(p.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct LibraryView: View {
    @ObservedObject private var model = AppModel.shared.library
    @ObservedObject private var spoken = AppModel.shared.spoken
    @Environment(\.palette) private var p
    /// Whether the keyboard is on the tiles: Tab reaches them, the arrow keys
    /// move from one to the next and Return plays the chosen one.
    @FocusState private var tilesFocused: Bool
    private let tilesWidth = State(initialValue: CGFloat(0))

    /// The narrowest a tile gets, and the gap between two.
    private static let tileMinimum: CGFloat = 184
    private static let tileSpacing: CGFloat = 8

    /// Moves the selection to the tile next to it, as the arrow keys ask.
    private func move(_ direction: MoveCommandDirection) {
        let way: GridWalk.Direction
        switch direction {
        case .left: way = .left
        case .right: way = .right
        case .up: way = .up
        case .down: way = .down
        @unknown default: return
        }
        let tiles = model.sections.flatMap(\.records)
        let columns = GridWalk.columns(width: Double(tilesWidth.wrappedValue),
                                       minimum: Double(Self.tileMinimum), spacing: Double(Self.tileSpacing))
        let current = tiles.firstIndex { $0.id == model.selectedID }
        if let next = GridWalk.move(from: current, groups: model.sections.map(\.records.count), columns: columns, way) {
            model.selectedID = tiles[next].id
        }
    }

    /// The list on the left; the selected video, when there is one, down the right.
    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if model.total == 0 {
                            EmptyState(title: "Your Library", text: Messages.libraryEmpty)
                        } else {
                            controls
                            banners
                            spokenSection
                            grid
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 12)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // A tile chosen with the arrow keys is brought onto the page.
                .onChange(of: model.selectedID) { chosen in
                    if tilesFocused, let chosen { proxy.scrollTo(chosen) }
                }
            }
            if let record = model.selected, model.total > 0 {
                Rectangle().fill(p.separator).frame(width: 1).accessibilityHidden(true)
                ScrollView {
                    LibraryDetail(record: record)
                }
                .frame(width: 286)
                .background(p.mantle)
            }
        }
        .onAppear { model.refreshFiles() }
        // The search field, the order and the filter sit in the window's toolbar.
        .searchable(text: $model.query.text, placement: .toolbar,
                    prompt: spoken.status.enabled ? "Title, site, channel or spoken words" : "Title, site or channel")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.total > 0 {
                    Picker("Sort by", selection: $model.query.sort) {
                        ForEach(LibraryQuery.Sort.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .help("Sort by")
                    .accessibilityLabel("Sort by")
                    Picker("Show", selection: $model.query.filter) {
                        ForEach(LibraryQuery.Filter.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .help("Show")
                    .accessibilityLabel("Show")
                }
            }
        }
        // Space previews the selected video, as in Finder. Esc closes the details.
        // Return plays it, while the keyboard is on the tiles.
        .background(
            ZStack {
                Button("") { if let record = model.selected, !record.missing { PreviewCenter.shared.show(record.path) } }
                    .keyboardShortcut(.space, modifiers: [])
                Button("") { model.selectedID = nil }.keyboardShortcut(.escape, modifiers: [])
                Button("") { if let record = model.selected { model.play(record) } }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(!tilesFocused || model.selected == nil)
            }
            .opacity(0).accessibilityHidden(true)
        )
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Segmented(options: [(value: false, label: "By site"), (value: true, label: "By channel")], selection: $model.query.byChannel)
                .fixedSize()
            if spoken.status.enabled && spoken.status.searchable < spoken.status.total {
                Text(spoken.status.line).font(p.font(12)).foregroundColor(p.subtext).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The passage with the searched words in bold.
    private func highlighted(_ pieces: [SpokenPiece]) -> Text {
        pieces.reduce(Text("")) { whole, piece in
            whole + Text(piece.text).fontWeight(piece.matched ? .bold : .regular).foregroundColor(piece.matched ? p.text : p.subtext)
        }
    }

    private func spokenRow(_ result: SpokenResult) -> some View {
        Button {
            model.playSpoken(result)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Text(TimeText.clock(result.start)).font(p.font(12).monospacedDigit()).foregroundColor(p.accent)
                    .frame(width: 56, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.record.title).font(p.font(12, .semibold)).foregroundColor(p.text).lineLimit(1)
                    highlighted(result.pieces).font(p.font(12)).lineLimit(2).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(result.record.title), at \(TimeText.clock(result.start)): \(result.pieces.map(\.text).joined())")
    }

    @ViewBuilder
    private var spokenSection: some View {
        if !model.spokenResults.isEmpty {
            Grouped(title: Messages.spokenHeading) {
                ForEach(Array(model.spokenResults.enumerated()), id: \.element.id) { pair in
                    VStack(spacing: 0) {
                        if pair.offset > 0 { RowDivider() }
                        spokenRow(pair.element)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var banners: some View {
        if let last = model.undo {
            HStack(spacing: 10) {
                Text(Messages.libraryMovedToTrash(last.record.title)).font(p.font(12)).foregroundColor(p.text).lineLimit(1)
                Button("Undo") { model.undoTrash() }.buttonStyle(PillButtonStyle()).keyboardShortcut("z")
                Button("Dismiss") { model.undo = nil }.buttonStyle(PillButtonStyle())
            }
            .padding(10).groupChrome()
        }
        if let notice = model.notice {
            Text(notice).font(p.font(12)).foregroundColor(p.warn).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.sections.isEmpty {
                Text(Messages.libraryNoMatches).font(p.font(13)).foregroundColor(p.subtext)
            }
            ForEach(model.sections) { section in
                HStack(spacing: 8) {
                    Text(section.name).font(p.font(15, .semibold)).foregroundColor(p.text).accessibilityAddTraits(.isHeader)
                    Tag(text: "\(section.records.count)", fill: p.control, foreground: p.text)
                }
                .padding(.horizontal, 7)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.tileMinimum, maximum: 340), spacing: Self.tileSpacing, alignment: .top)], alignment: .leading, spacing: 10) {
                    ForEach(section.records) { record in
                        LibraryCard(record: record, selected: model.selectedID == record.id) { tilesFocused = true }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GeometryReader { size in
            Color.clear
                .onAppear { tilesWidth.wrappedValue = size.size.width }
                .onChange(of: size.size.width) { tilesWidth.wrappedValue = $0 }
        })
        // The chosen tile's own outline shows where the keyboard is.
        .keyboardList(enabled: !model.sections.isEmpty, ownMark: model.selected != nil)
        .focused($tilesFocused)
        .onMoveCommand(perform: move)
    }
}
