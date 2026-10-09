// Overlays.swift: what opens over the main window: the command bar (Cmd-K),
// the welcome tour, and the notice of a new version.
//
// Which commands exist, what matches what was typed and in which order are
// the engine's (`CommandBar`, `CommandSearch`); so are the tour's steps and
// whether a version is newer. This file draws them and does what is picked.

import AppKit
import Engine
import SwiftUI

// MARK: - Command bar

@MainActor
final class CommandCenter: ObservableObject {
    @Published var isOpen = false
    @Published var query = "" {
        didSet { if query != oldValue { refresh() } }
    }
    @Published var selected = 0
    @Published private(set) var results: [CommandEntry] = []

    private var fixed: [CommandEntry] = []
    private var records: [LibraryRecord] = []

    func toggle() { isOpen ? close() : open() }

    func open() {
        let model = AppModel.shared
        guard !model.tour.isOpen, model.tools.missing.isEmpty else { return }
        let jobs = model.queue.jobs
        fixed = CommandBar.fixed(screens: Screen.allCases.map { ($0.rawValue, $0.label, $0.symbol) },
                                 situation: .init(hasBusy: QueueCounts(jobs).busy > 0, hasPaused: jobs.contains { $0.state == .paused }))
        records = []
        query = ""
        selected = 0
        isOpen = true
        refresh()
        // The Library's videos, read once each time the bar opens.
        Task {
            records = await model.library.repo.records()
            if isOpen { refresh() }
        }
    }

    func close() { isOpen = false }

    func move(_ step: Int) {
        guard !results.isEmpty else { return }
        selected = min(max(selected + step, 0), results.count - 1)
    }

    private func refresh() {
        results = CommandBar.results(query: query, fixed: fixed, records: records,
                                     spokenSearch: AppModel.shared.settings.value.spokenSearch)
        selected = 0
    }

    func run(at index: Int? = nil) {
        let position = index ?? selected
        guard results.indices.contains(position) else { return }
        let entry = results[position]
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        close()
        perform(entry, typed: typed)
    }

    private func perform(_ entry: CommandEntry, typed: String) {
        let model = AppModel.shared
        if let screen = Screen.allCases.first(where: { CommandBar.screenID($0.rawValue) == entry.id }) {
            model.nav.screen = screen
            return
        }
        if entry.id.hasPrefix(CommandBar.videoPrefix) {
            if let record = records.first(where: { CommandBar.videoID($0) == entry.id }) { model.library.play(record) }
            return
        }
        switch entry.id {
        case CommandBar.linkID:
            // Fills in the Download screen; nothing downloads until Download is pressed.
            model.download.take(link: typed)
        case CommandBar.spokenID:
            model.nav.screen = .library
            model.library.query.text = typed
        case CommandBar.settingsID:
            SettingsWindow.shared.show()
        case CommandBar.pauseAllID:
            model.queue.pauseAll()
        case CommandBar.resumeAllID:
            model.queue.resumeAll()
        case CommandBar.clearFinishedID:
            model.queue.clearFinished()
        case CommandBar.checkChannelsID:
            model.nav.screen = .following
            model.following.checkAll()
        case CommandBar.pasteID:
            model.nav.screen = .download
            model.download.paste()
            model.download.lookup()
        case CommandBar.openFolderID:
            Opener.open(folder: model.settings.value.folders.mainFolder)
        case CommandBar.tourID:
            model.tour.open()
        default:
            break
        }
    }
}

/// A one-line box for typing that also reports the arrow keys, Return and
/// Escape. SwiftUI's own text field cannot, on the macOS versions supported.
private struct CommandField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var size: CGFloat
    var onMove: (Int) -> Void
    var onReturn: () -> Void
    var onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: size)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.setAccessibilityLabel(placeholder)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.font = .systemFont(ofSize: size)
        if field.stringValue != text { field.stringValue = text }
        if !context.coordinator.focused, let window = field.window {
            context.coordinator.focused = true
            window.makeFirstResponder(field)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommandField
        var focused = false

        init(_ parent: CommandField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1); return true
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1); return true
            case #selector(NSResponder.insertNewline(_:)): parent.onReturn(); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onEscape(); return true
            default: return false
            }
        }
    }
}

private struct CommandBarView: View {
    @ObservedObject private var center = AppModel.shared.commands
    @Environment(\.palette) private var p

    private func row(_ result: CommandEntry, index: Int) -> some View {
        let on = index == center.selected
        return Button {
            center.run(at: index)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: result.symbol).font(p.font(13)).foregroundColor(on ? p.onFill : p.accent)
                    .frame(width: 20).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.title).font(p.font(13, .medium)).foregroundColor(on ? p.onFill : p.text).lineLimit(1)
                    if !result.detail.isEmpty {
                        Text(result.detail).font(p.font(11)).foregroundColor(on ? p.onFill.opacity(0.85) : p.subtext).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(result.group).font(p.font(11)).foregroundColor(on ? p.onFill.opacity(0.85) : p.subtext)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(on ? p.fill : Color.clear)
            .cornerRadius(7)
            .contentShape(Rectangle())
            .focusShape(radius: 7)
        }
        .buttonStyle(.plain)
        .id(result.id)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { center.close() }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundColor(p.subtext).accessibilityHidden(true)
                    CommandField(text: $center.query, placeholder: Messages.commandPlaceholder, size: 16 * p.scale,
                                 onMove: { center.move($0) }, onReturn: { center.run() }, onEscape: { center.close() })
                        .frame(height: 24)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                RowDivider()
                if center.results.isEmpty {
                    Text(Messages.commandNothing).font(p.font(13)).foregroundColor(p.subtext)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 2) {
                                ForEach(Array(center.results.enumerated()), id: \.element.id) { pair in
                                    row(pair.element, index: pair.offset)
                                }
                            }
                            .padding(6)
                        }
                        .frame(maxHeight: 340)
                        .onChange(of: center.selected) { _ in
                            if center.results.indices.contains(center.selected) { proxy.scrollTo(center.results[center.selected].id) }
                        }
                    }
                }
            }
            .frame(width: 560)
            // As tall as its rows, up to the list's limit; then the list scrolls.
            .fixedSize(horizontal: false, vertical: true)
            .floatingPanel(radius: 16)
            .shadow(color: Color.black.opacity(0.35), radius: 24, x: 0, y: 10)
            .padding(.top, 90)
        }
        .accessibilityAddTraits(.isModal)
    }
}

// MARK: - Welcome tour

@MainActor
final class TourCenter: ObservableObject {
    @Published var isOpen = false
    @Published var step = 0

    /// Opens the tour once, the first time the main window is ready for use.
    func openIfFirstRun() {
        let model = AppModel.shared
        guard !model.settings.value.tourSeen, !isOpen, !Launch.isLaunchCheck, model.tools.missing.isEmpty else { return }
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !model.settings.value.tourSeen && !isOpen && model.tools.missing.isEmpty { open() }
        }
    }

    func open() {
        AppModel.shared.commands.close()
        step = 0
        isOpen = true
    }

    func next() {
        if let following = Tour.next(after: step) { step = following } else { finish() }
    }

    func back() { step = Tour.back(from: step) }

    func finish() {
        isOpen = false
        AppModel.shared.settings.value.tourSeen = true
    }
}

private struct TourCard: View {
    @ObservedObject private var tour = AppModel.shared.tour
    @Environment(\.palette) private var p

    var body: some View {
        let steps = Tour.steps
        let step = steps[min(tour.step, steps.count - 1)]
        let last = tour.step >= steps.count - 1
        ZStack {
            // Clicks outside the card do nothing: the tour ends with Skip, Escape or its last button.
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture {}
            VStack(spacing: 14) {
                if tour.step == 0 {
                    Text(Messages.tourWelcome).font(p.font(12, .semibold)).foregroundColor(p.subtext)
                }
                if tour.step == 0 {
                    // The tour opens with the artwork; the later steps have their own pictures.
                    BrandArt(height: 112)
                } else {
                    Image(systemName: step.symbol).font(.system(size: 34)).foregroundColor(p.accent).padding(.top, 4).accessibilityHidden(true)
                }
                Text(step.title).font(p.font(20, .semibold)).foregroundColor(p.text).accessibilityAddTraits(.isHeader)
                Text(step.text).font(p.font(13)).foregroundColor(p.subtext).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).frame(minHeight: 84, alignment: .top)
                HStack(spacing: 6) {
                    ForEach(0..<steps.count, id: \.self) { index in
                        Circle().fill(index == tour.step ? p.fill : p.control).frame(width: 7, height: 7)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Step \(tour.step + 1) of \(steps.count)")
                HStack(spacing: 8) {
                    Button("Skip") { tour.finish() }
                        .buttonStyle(PillButtonStyle())
                        .keyboardShortcut(.cancelAction)
                        .opacity(last ? 0 : 1)
                        .accessibilityHidden(last)
                        .accessibilityLabel("Skip")
                    Spacer()
                    if tour.step > 0 {
                        Button("Back") { tour.back() }.buttonStyle(PillButtonStyle())
                            .accessibilityLabel("Back")
                    }
                    Button(last ? Messages.tourFinish : "Next") { tour.next() }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                        .accessibilityLabel(last ? Messages.tourFinish : "Next")
                }
                .padding(.top, 4)
            }
            .padding(26)
            .frame(width: 440)
            .floatingPanel(radius: 20)
            .shadow(color: Color.black.opacity(0.35), radius: 24, x: 0, y: 10)
        }
        .accessibilityAddTraits(.isModal)
    }
}

/// Whatever is open over the main window: the tour or the command bar.
struct Overlays: View {
    @ObservedObject private var commands = AppModel.shared.commands
    @ObservedObject private var tour = AppModel.shared.tour

    var body: some View {
        ZStack {
            if commands.isOpen { CommandBarView() }
            if tour.isOpen { TourCard() }
        }
    }
}

// MARK: - New version notice

/// Says when a newer version exists (a notice only, the app never
/// updates itself). It looks once per launch, and only when an address was
/// set when the app was built; with none, nothing is asked of anyone.
@MainActor
final class UpdateChecker: ObservableObject {
    @Published var notice: Versioning.Notice?
    private var started = false

    static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? Engine.version
    }

    func check() {
        guard !started, !Launch.isLaunchCheck else { return }
        started = true
        // `--update-notice=<file>` shows a notice from a file on this Mac, to see the banner.
        if let path = Launch.value(of: "--update-notice"), let data = FileManager.default.contents(atPath: (path as NSString).expandingTildeInPath) {
            notice = Versioning.notice(in: data, current: Self.currentVersion)
            return
        }
        guard let url = Versioning.noticeAddress(Bundle.main.object(forInfoDictionaryKey: "UpdateNoticeURL") as? String) else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let current = Self.currentVersion
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data, let found = Versioning.notice(in: data, current: current) else { return }
            Task { @MainActor in AppModel.shared.updates.notice = found }
        }.resume()
    }
}

struct UpdateBanner: View {
    @ObservedObject private var checker = AppModel.shared.updates
    @Environment(\.palette) private var p

    var body: some View {
        if let notice = checker.notice {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Messages.updateAvailable(notice.version)).font(p.font(13, .semibold)).foregroundColor(p.text)
                    if !notice.note.isEmpty {
                        Text(notice.note).font(p.font(12)).foregroundColor(p.subtext).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if !notice.url.isEmpty {
                    Button("Get It") { Opener.open(link: notice.url) }.buttonStyle(PillButtonStyle(kind: .primary))
                }
                Button("Dismiss") { checker.notice = nil }.buttonStyle(PillButtonStyle())
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .floatingPanel(radius: 14)
            .padding(.horizontal, 28)
            .padding(.bottom, 8)
        }
    }
}
