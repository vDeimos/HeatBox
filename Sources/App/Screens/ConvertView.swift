// ConvertView.swift: changing a file that is already on the Mac.
//
// The screen holds a `ConvertDraft` and draws it. Which jobs fit the file,
// what each would produce and why one cannot be done are the engine's
// decisions; `ConvertCenter` runs them. The original is never changed.

import AppKit
import Engine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ConvertModel: ObservableObject {
    @Published var input: String?
    @Published var draft: ConvertDraft?
    @Published var isLoading = false
    @Published var errorText: String?
    @Published private(set) var items: [Conversion] = []

    let center: ConvertCenter
    private let tools: ToolsModel
    private let settings: SettingsModel
    /// Called when the last conversion ends, so a hidden app can quit.
    var onIdle: (() -> Void)?

    init(center: ConvertCenter, tools: ToolsModel, settings: SettingsModel) {
        self.center = center
        self.tools = tools
        self.settings = settings
    }

    var hasRunning: Bool { items.contains { $0.state == .running } }

    func start() {
        Task { [weak self, center] in
            for await list in await center.updates() {
                guard let self else { return }
                let old = self.items
                self.items = list
                SystemState.keepAwake(.converting, self.hasRunning)
                self.announce(from: old, to: list)
            }
        }
    }

    private func announce(from old: [Conversion], to new: [Conversion]) {
        let wasRunning = Set(old.filter { $0.state == .running }.map(\.id))
        for item in new where item.state == .done && item.announce && wasRunning.contains(item.id) {
            Notifier.converted(title: (item.output as NSString).lastPathComponent, path: item.output,
                               offerPlay: settings.value.finish == .notifyAndOffer)
        }
        if !wasRunning.isEmpty && !hasRunning { onIdle?() }
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .audio]
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let path = panel.url?.path { load(path) }
    }

    func load(_ path: String) {
        input = path
        draft = nil
        errorText = nil
        isLoading = true
        let registry = tools.registry
        Task {
            let facts = await FileInspector.inspect(path, tools: registry)
            guard self.input == path else { return }
            self.isLoading = false
            if let facts {
                self.draft = ConvertDraft(input: path, facts: facts)
            } else {
                self.errorText = registry.path(.ffprobe) == nil ? Messages.noConverter : Messages.unreadableFile
            }
        }
    }

    func startConversion() {
        guard let draft, let plan = draft.plan() else { return }
        let label = draft.label
        let shrinking = draft.choice == .shrink
        Task { await center.start(plan, input: draft.input, label: label, mustBeSmaller: shrinking) }
    }

    /// Runs a plan on behalf of another screen, such as Send to iPhone, and
    /// gives the finished file's path, or nil if it did not work.
    func makeCopy(of input: String, plan: FFmpegPlanner.Plan, label: String) async -> String? {
        let id = await center.start(plan, input: input, label: label, announce: false)
        return await center.result(of: id)
    }

    func cancel(_ item: Conversion) { Task { await center.cancel(item.id) } }
    func clearFinished() { Task { await center.clearFinished() } }
}

private struct ConvertRow: View {
    let item: Conversion
    var titleWidth: CGFloat = 260
    @Environment(\.palette) private var p

    private var look: (symbol: String, colour: Color) {
        switch item.state {
        case .running: return ("arrow.triangle.2.circlepath", p.accent)
        case .done: return ("checkmark", p.good)
        case .failed: return ("xmark", p.bad)
        case .cancelled: return ("slash.circle", p.subtext)
        }
    }

    private var fraction: Double {
        switch item.state {
        case .running, .failed: return item.progress
        case .done: return 1
        case .cancelled: return 0
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            StateTile(symbol: look.symbol, colour: look.colour)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(p.font(14, .semibold)).foregroundColor(p.text).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.detail).font(p.font(12)).foregroundColor(p.subtext).lineLimit(1)
            }
            .frame(width: titleWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                (Text(item.state.label).fontWeight(.semibold).foregroundColor(look.colour == p.subtext ? p.text : look.colour)
                 + Text(item.status.isEmpty ? "" : " · " + item.status).foregroundColor(item.state == .failed ? p.bad : p.subtext))
                    .font(p.font(12).monospacedDigit())
                    .fixedSize(horizontal: false, vertical: true)
                ThinBar(fraction: fraction, colour: look.colour == p.accent ? p.fill : look.colour)
                    .accessibilityElement()
                    .accessibilityLabel("Progress for \(item.title)")
                    .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
                    .accessibilityHidden(item.state != .running)
                if item.state == .failed && !item.toolSays.isEmpty {
                    Text(item.toolSays).font(p.mono(11)).foregroundColor(p.subtext).lineLimit(2).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if item.state == .running {
                Button("Cancel") { AppModel.shared.convert.cancel(item) }.buttonStyle(PillButtonStyle())
            } else if item.state == .done {
                Button(Opener.playLabel) { Opener.play(item.output) }.buttonStyle(PillButtonStyle(kind: .primary))
                MoreMenu(label: "More actions for \(item.title)") {
                    Button("Show in Finder") { Opener.reveal(item.output) }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ConvertView: View {
    @ObservedObject private var model = AppModel.shared.convert
    @Environment(\.palette) private var p
    private let askingAboutBattery = State(initialValue: false)
    /// The screen's width: side by side where there is room, stacked where there is not.
    private let width = State(initialValue: CGFloat(760))

    var body: some View {
        let wide = width.wrappedValue >= 720
        VStack(alignment: .leading, spacing: 16) {
            if let draft = model.draft, wide {
                HStack(alignment: .top, spacing: 16) {
                    fileCard
                        .frame(maxWidth: .infinity)
                    jobs(draft)
                        .frame(maxWidth: .infinity)
                }
            } else {
                fileCard
                if let draft = model.draft { jobs(draft) }
            }
            if !model.items.isEmpty {
                conversions
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GeometryReader { geometry in
            Color.clear
                .onAppear { width.wrappedValue = geometry.size.width }
                .onChange(of: geometry.size.width) { width.wrappedValue = $0 }
        })
        .alert(Messages.convertBatteryTitle, isPresented: askingAboutBattery.projectedValue) {
            Button("Convert Now") { model.startConversion() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Messages.convertBatteryText)
        }
    }

    private var conversions: some View {
        let titleWidth = min(max(width.wrappedValue * 0.3, 150), 320)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                GroupHeader(title: "Conversions")
                Spacer()
                Button("Clear Finished") { model.clearFinished() }.buttonStyle(PillButtonStyle())
            }
            Grouped {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { pair in
                    VStack(spacing: 0) {
                        if pair.offset > 0 { RowDivider() }
                        ConvertRow(item: pair.element, titleWidth: titleWidth)
                    }
                }
            }
        }
    }

    /// Where a file is dropped or chosen, and what the file on screen is.
    private var fileCard: some View {
        Card(title: "File") {
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc").font(.system(size: 28)).foregroundColor(p.accent).accessibilityHidden(true)
                Text(model.input == nil ? "Drop a video or audio file here" : "Drop a different file here to replace it.")
                    .font(p.font(model.input == nil ? 15 : 13, model.input == nil ? .semibold : .regular))
                    .foregroundColor(model.input == nil ? p.text : p.subtext)
                    .multilineTextAlignment(.center)
                if model.input == nil {
                    Text("Or choose one, or use Convert or Cut in the Library. The original file is never changed.")
                        .font(p.font(12)).foregroundColor(p.subtext)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                Button(model.input == nil ? "Choose a File" : "Choose Another") { model.chooseFile() }.buttonStyle(PillButtonStyle())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, model.input == nil ? 36 : 18)
            .frame(maxWidth: .infinity)
            .background(p.field)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(p.fieldBorder, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            if let path = model.input {
                VStack(alignment: .leading, spacing: 4) {
                    Text((path as NSString).lastPathComponent).font(p.font(15, .semibold)).foregroundColor(p.text)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if let draft = model.draft {
                        Text(draft.factsLine()).font(p.font(12)).foregroundColor(p.subtext)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("The original file is never changed.").font(p.font(12)).foregroundColor(p.subtext)
                }
            }
            if model.isLoading {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading the file…").font(p.font(13)).foregroundColor(p.subtext)
                }
            }
            if let error = model.errorText {
                Text(error).font(p.font(13)).foregroundColor(p.bad).fixedSize(horizontal: false, vertical: true)
            }
        }
        // A file dropped here is for converting, not a link for the Download screen.
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in model.load(url.path) }
            }
            return true
        }
    }

    private func shrinkSizes(_ draft: ConvertDraft) -> some View {
        HStack(spacing: 8) {
            ForEach(ShrinkLevel.allCases, id: \.self) { level in
                let picked = draft.level == level
                Button {
                    model.draft?.level = level
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(level.label).font(p.font(13, .semibold)).foregroundColor(p.text)
                        Text(draft.estimate(for: level)).font(p.font(12)).foregroundColor(p.subtext)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(picked ? p.wash(p.accent) : p.control.opacity(0.5))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(picked ? p.accent : Color.clear, lineWidth: 2))
                    .cornerRadius(8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(picked ? [.isSelected] : [])
            }
        }
    }

    private func jobRow(_ choice: ConvertChoice, _ draft: ConvertDraft) -> some View {
        let on = draft.choice == choice
        let usable = draft.available(choice)
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                model.draft?.choice = choice
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    RadioMark(on: on).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(choice.title).font(p.font(13, .semibold)).foregroundColor(p.text)
                        Text(usable ? choice.explanation : Messages.convertNotPossible)
                            .font(p.font(12)).foregroundColor(p.subtext)
                            .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!usable)
            .accessibilityAddTraits(on ? [.isSelected] : [])
            if on && choice == .shrink { shrinkSizes(draft) }
            if on && choice == .clip && draft.facts.duration > 1 {
                ClipControls(duration: draft.facts.duration,
                             start: Binding(get: { model.draft?.clipStart ?? 0 }, set: { model.draft?.clipStart = $0 }),
                             end: Binding(get: { model.draft?.clipEnd ?? 0 }, set: { model.draft?.clipEnd = $0 }))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(on ? p.control.opacity(0.55) : Color.clear)
        .opacity(usable ? 1 : 0.55)
    }

    /// What can be done with the file, and the button that does it.
    private func jobs(_ draft: ConvertDraft) -> some View {
        Grouped(title: "What would you like to do?") {
            ForEach(Array(ConvertChoice.allCases.enumerated()), id: \.element) { pair in
                VStack(spacing: 0) {
                    if pair.offset > 0 { RowDivider() }
                    jobRow(pair.element, draft)
                }
            }
            RowDivider()
            startBar(draft)
                .padding(14)
        }
    }

    private func startBar(_ draft: ConvertDraft) -> some View {
        let plan = draft.plan()
        return VStack(alignment: .leading, spacing: 8) {
            if let plan {
                Text(draft.summary(for: plan)).font(p.font(12)).foregroundColor(p.subtext).fixedSize(horizontal: false, vertical: true)
            } else if let blocker = draft.blocker() {
                Text(blocker).font(p.font(12)).foregroundColor(p.warn).fixedSize(horizontal: false, vertical: true)
            }
            Button {
                if let plan, ConvertDraft.asksOnBattery(plan, onBattery: BatteryPower().onBattery) {
                    askingAboutBattery.wrappedValue = true
                } else {
                    model.startConversion()
                }
            } label: {
                Text("Start")
                    .font(p.font(14, .semibold))
                    .foregroundColor(p.onFill)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(p.fill)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(plan == nil ? 0.45 : 1)
            .disabled(plan == nil)
        }
    }
}
