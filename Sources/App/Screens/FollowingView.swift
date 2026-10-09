// FollowingView.swift: channels you follow, and a Check now button.
//
// Nothing here runs by itself: a channel is only looked at when Check now is
// pressed, and nothing is downloaded until the person chooses it.
import Engine
import SwiftUI

/// What the screen shows for one channel. Not saved: Check now rebuilds it.
struct ChannelState {
    var fresh: [FeedEntry] = []
    var selected: Set<String> = []
    var status = ""
    var checking = false
}

@MainActor
final class FollowingModel: ObservableObject {
    @Published private(set) var channels: [Channel]
    @Published private(set) var state: [UUID: ChannelState] = [:]
    @Published var input = ""
    @Published var addError: String?
    @Published var adding = false
    @Published var checkingAll = false

    private let store: FollowStore
    private let tools: ToolsModel
    private let settings: SettingsModel
    private let queue: QueueModel
    private let nav: Navigation

    init(store: FollowStore, tools: ToolsModel, settings: SettingsModel, queue: QueueModel, nav: Navigation) {
        self.store = store
        self.tools = tools
        self.settings = settings
        self.queue = queue
        self.nav = nav
        channels = store.load()
    }

    /// Reads the file again, after the one-time import has added to it.
    func reload() {
        channels = store.load()
    }

    private func save() { try? store.save(channels) }

    func state(for id: UUID) -> ChannelState { state[id] ?? ChannelState() }

    /// New videos found by the last check, over every channel.
    var freshCount: Int { state.values.reduce(0) { $0 + $1.fresh.count } }

    func follow() {
        guard !adding else { return }
        guard let found = Links.extract(from: input).first else { addError = Messages.noLink; return }
        let target = Links.channelVideosURL(found)
        if channels.contains(where: { $0.link == target }) { addError = Messages.followingAlready; return }
        adding = true
        addError = nil
        let registry = tools.registry
        Task {
            let outcome = await Following.fetch(link: target, cookiesFile: AppModel.shared.signInFile, tools: registry)
            adding = false
            switch outcome {
            case .failure(let message):
                addError = message
            case .feed(let feed):
                let channel = FollowStore.newChannel(link: found, feed: feed, now: Date())
                channels.append(channel)
                state[channel.id] = ChannelState(status: Messages.followingStarted)
                input = ""
                save()
            }
        }
    }

    func unfollow(_ id: UUID) {
        channels.removeAll { $0.id == id }
        state[id] = nil
        save()
    }

    func checkAll() {
        guard !checkingAll, !channels.isEmpty else { return }
        checkingAll = true
        let list = channels
        for channel in list {
            var current = state(for: channel.id)
            current.checking = true
            current.status = Messages.followingChecking
            state[channel.id] = current
        }
        let registry = tools.registry
        let cookies = AppModel.shared.signInFile
        Task {
            for channel in list {
                apply(await Following.fetch(link: channel.link, cookiesFile: cookies, tools: registry), to: channel.id)
            }
            checkingAll = false
        }
    }

    private func apply(_ outcome: FeedOutcome, to id: UUID) {
        guard let index = channels.firstIndex(where: { $0.id == id }) else { return }
        var current = state(for: id)
        current.checking = false
        switch outcome {
        case .failure(let message):
            current.status = message
        case .feed(let feed):
            current.fresh = channels[index].fresh(in: feed)
            current.selected = Set(current.fresh.map(\.id))
            current.status = current.fresh.isEmpty ? Messages.followingNothingNew : Messages.followingNew(current.fresh.count)
            channels[index].lastChecked = Date()
            save()
        }
        state[id] = current
    }

    func toggle(_ entryID: String, for id: UUID) {
        var current = state(for: id)
        if current.selected.contains(entryID) { current.selected.remove(entryID) } else { current.selected.insert(entryID) }
        state[id] = current
    }

    func setChoice(_ choiceID: String, for id: UUID) {
        guard let index = channels.firstIndex(where: { $0.id == id }) else { return }
        channels[index].choiceID = choiceID
        save()
    }

    /// Takes videos off the "new" list without downloading them.
    func markSeen(_ ids: [String], for id: UUID) {
        guard let index = channels.firstIndex(where: { $0.id == id }) else { return }
        channels[index].markSeen(ids)
        var current = state(for: id)
        current.fresh.removeAll { ids.contains($0.id) }
        current.selected.subtract(ids)
        if current.fresh.isEmpty { current.status = Messages.followingNothingNew }
        state[id] = current
        save()
    }

    func markAllSeen(for id: UUID) { markSeen(state(for: id).fresh.map(\.id), for: id) }

    func downloadSelected(for id: UUID) {
        guard let channel = channels.first(where: { $0.id == id }) else { return }
        let current = state(for: id)
        let chosen = current.fresh.filter { current.selected.contains($0.id) }
        guard !chosen.isEmpty else { return }
        var draft = DownloadDraft(target: .links(chosen.map(\.url)))
        if let id = draft.choices.contains(where: { $0.id == channel.choiceID }) ? channel.choiceID : draft.choices.first?.id {
            draft.pick(id)
        }
        queue.add(draft.requests(defaults: DownloadDefaults(settings.value)))
        markSeen(chosen.map(\.id), for: id)
        nav.screen = .queue
    }
}

/// One followed channel in the list on the left: its name, when it was
/// last looked at, and how many new videos the last check found.
private struct ChannelCard: View {
    let channel: Channel
    @ObservedObject private var model = AppModel.shared.following
    @Environment(\.palette) private var p

    private var checkedText: String {
        guard let date = channel.lastChecked else { return "Not checked yet" }
        return "Checked " + date.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        let current = model.state(for: channel.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Text(channel.name).font(p.font(14, .semibold)).foregroundColor(p.text)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if !current.fresh.isEmpty {
                    Tag(text: "\(current.fresh.count) new", fill: p.fill, foreground: p.onFill)
                }
            }
            Text(channel.site).font(p.font(12)).foregroundColor(p.subtext)
            Text(checkedText).font(p.font(12)).foregroundColor(p.subtext)
            if current.checking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(Messages.followingChecking).font(p.font(12)).foregroundColor(p.subtext)
                }
            } else if !current.status.isEmpty && current.fresh.isEmpty {
                Text(current.status).font(p.font(12)).foregroundColor(p.subtext).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                MoreMenu(label: "More actions for \(channel.name)") {
                    Button("Stop following") { model.unfollow(channel.id) }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .groupChrome()
        .accessibilityElement(children: .contain)
    }
}

/// The new videos one channel's last check found, to tick and download.
private struct FreshSection: View {
    let channel: Channel
    let current: ChannelState
    @ObservedObject private var model = AppModel.shared.following
    @Environment(\.palette) private var p

    private func entryRow(_ entry: FeedEntry) -> some View {
        let picked = current.selected.contains(entry.id)
        return Toggle(isOn: Binding(get: { picked }, set: { _ in model.toggle(entry.id, for: channel.id) })) {
            HStack(spacing: 10) {
                Text(entry.title).font(p.font(13, .medium)).foregroundColor(p.text).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(entry.duration).font(p.font(12).monospacedDigit()).foregroundColor(p.subtext)
            }
            .padding(.leading, 4)
        }
        .toggleStyle(.checkbox)
        .tint(p.fill)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(channel.name).font(p.font(15, .semibold)).foregroundColor(p.text).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Tag(text: "\(current.fresh.count) new", fill: p.control, foreground: p.accent)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            Grouped {
                ForEach(Array(current.fresh.enumerated()), id: \.element.id) { pair in
                    VStack(spacing: 0) {
                        if pair.offset > 0 { RowDivider() }
                        entryRow(pair.element)
                    }
                }
                RowDivider()
                // One row where there is room, two where there is not.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        version
                        Spacer(minLength: 8)
                        buttons
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        version
                        HStack(spacing: 8) { buttons }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
        }
    }

    private var version: some View {
        Picker("Version", selection: Binding(get: { channel.choiceID }, set: { model.setChoice($0, for: channel.id) })) {
            ForEach(ChoiceBuilder.generic) { Text($0.title).tag($0.id) }
        }
        .frame(width: 230)
    }

    @ViewBuilder
    private var buttons: some View {
        Button("Mark all as seen") { model.markAllSeen(for: channel.id) }.buttonStyle(PillButtonStyle())
        Button {
            model.downloadSelected(for: channel.id)
        } label: {
            Label("Download \(current.selected.count) selected", systemImage: "arrow.down.to.line")
        }
        .buttonStyle(PillButtonStyle(kind: .primary)).disabled(current.selected.isEmpty)
    }
}

struct FollowingView: View {
    @ObservedObject private var model = AppModel.shared.following
    @Environment(\.palette) private var p

    /// The channels on the left; what their last check found on the right.
    var body: some View {
        HStack(spacing: 0) {
            channels
                .frame(width: 300)
            Rectangle().fill(p.separator).frame(width: 1).accessibilityHidden(true)
            ScrollView {
                fresh
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var channels: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                addBar
                if let error = model.addError {
                    Text(error).font(p.font(13)).foregroundColor(p.bad).fixedSize(horizontal: false, vertical: true)
                }
                if !model.channels.isEmpty {
                    HStack(spacing: 8) {
                        Text("Channels (\(model.channels.count))").font(p.font(15, .semibold)).foregroundColor(p.text)
                            .accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 8)
                        Button("Check now") { model.checkAll() }
                            .buttonStyle(PillButtonStyle(kind: .primary)).disabled(model.checkingAll)
                    }
                    .padding(.top, 4)
                    ForEach(model.channels) { ChannelCard(channel: $0) }
                }
            }
            .padding(.leading, 24)
            .padding(.trailing, 16)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                RowDivider()
                Text(Messages.followingExplainer).font(p.font(12)).foregroundColor(p.subtext)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 24)
                    .padding(.trailing, 16)
                    .padding(.vertical, 10)
            }
            .background(p.base)
        }
    }

    @ViewBuilder
    private var fresh: some View {
        let found = model.channels.filter { !model.state(for: $0.id).fresh.isEmpty }
        if model.channels.isEmpty {
            EmptyState(title: "Follow a channel", text: Messages.followingEmpty)
        } else if found.isEmpty {
            EmptyState(title: "Nothing new to show",
                       text: "Check now looks at every channel you follow and lists the videos published since the last check.")
        } else {
            VStack(alignment: .leading, spacing: 20) {
                Text("New videos").font(p.font(20, .semibold)).foregroundColor(p.text)
                    .padding(.horizontal, 14)
                    .accessibilityAddTraits(.isHeader)
                ForEach(found) { FreshSection(channel: $0, current: model.state(for: $0.id)) }
            }
        }
    }

    private var addBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add a channel by pasting its link").font(p.font(12)).foregroundColor(p.subtext)
            HStack(spacing: 8) {
                TextField("https://www.youtube.com/@channel", text: $model.input)
                    .textFieldStyle(.plain).font(p.font(13)).foregroundColor(p.text)
                    .padding(.horizontal, 10).padding(.vertical, 7).fieldChrome()
                    .onSubmit { model.follow() }
                    .accessibilityLabel("Channel link")
                Button("Follow") { model.follow() }.buttonStyle(PillButtonStyle()).disabled(model.adding)
            }
            if model.adding {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading the channel…").font(p.font(12)).foregroundColor(p.subtext)
                }
            }
        }
    }
}
