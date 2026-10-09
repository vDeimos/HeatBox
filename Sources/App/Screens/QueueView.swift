// QueueView.swift: everything downloading, waiting, finished or failed.

import AppKit
import Engine
import SwiftUI

/// "Starts tomorrow at 2:00 AM", in the person's own date and time format.
/// The engine leaves this sentence to the app so its own text reads the same
/// on every Mac.
enum ScheduleText {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    static func starts(_ date: Date) -> String {
        var when = formatter.string(from: date)
        // "Today at 2:00 AM" reads better mid-sentence in lower case; a date ("7 Oct 2026") is left alone.
        if let first = when.first, first.isLetter, when.hasPrefix("Today") || when.hasPrefix("Tomorrow") {
            when = first.lowercased() + when.dropFirst()
        }
        return "Starts \(when). \(Engine.productName) needs to stay open until then."
    }
}

/// A thin bar that says how far something is. Drawn here, not by the system,
/// so a finished, paused or failed download can keep its bar in its own colour.
struct ThinBar: View {
    /// 0 to 1.
    let fraction: Double
    let colour: Color
    @Environment(\.palette) private var p

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(p.control)
                Capsule().fill(colour)
                    .frame(width: max(geometry.size.width * CGFloat(min(max(fraction, 0), 1)), fraction > 0 ? 4 : 0))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// The square at the start of a row that says, with a picture, where a
/// download or a conversion stands.
struct StateTile: View {
    let symbol: String
    let colour: Color
    @Environment(\.palette) private var p

    var body: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(p.wash(colour))
            .frame(width: 40, height: 40)
            .overlay(Image(systemName: symbol).font(p.font(16, .semibold)).foregroundColor(colour))
            .accessibilityHidden(true)
    }
}

/// The round "more" button at the end of a row.
struct MoreMenu<Items: View>: View {
    let label: String
    @ViewBuilder var items: () -> Items
    @Environment(\.palette) private var p

    var body: some View {
        Menu {
            items()
        } label: {
            Image(systemName: "ellipsis")
                .font(p.font(13, .semibold))
                .foregroundColor(p.text)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 28, height: 28)
        .background(Circle().fill(p.control))
        .contentShape(Circle())
        .accessibilityLabel(label)
    }
}

struct QueueRow: View {
    let job: Job
    /// The time, for the countdown before another try.
    let now: Date
    /// How wide the title's column is, the same in every row so the columns line up.
    var titleWidth: CGFloat = 260
    @Environment(\.palette) private var p

    private var queue: QueueModel { AppModel.shared.queue }

    /// Every state has a word and a picture as well as a colour.
    private var look: (symbol: String, colour: Color) {
        switch job.state {
        case .waiting: return ("hourglass", p.subtext)
        case .paused: return ("pause.fill", p.subtext)
        case .cancelled: return ("slash.circle", p.subtext)
        case .lookingUp: return ("magnifyingglass", p.accent)
        case .running: return ("arrow.down", p.accent)
        case .scheduled: return ("clock", p.accent)
        case .retrying: return ("arrow.clockwise", p.warn)
        case .doneWithWarnings: return ("exclamationmark.triangle.fill", p.warn)
        case .done: return ("checkmark", p.good)
        case .failed: return ("xmark", p.bad)
        }
    }

    private var status: String {
        if case .scheduled(let date) = job.state { return ScheduleText.starts(date) }
        return job.statusLine(now: now)
    }

    /// How full the bar is: a download under way shows how far it is, and a
    /// finished one is full.
    private var barFraction: Double {
        switch job.state {
        case .done, .doneWithWarnings: return 1
        case .waiting, .scheduled, .cancelled: return 0
        case .lookingUp, .running, .paused, .retrying, .failed: return job.progress.fraction ?? 0
        }
    }

    /// The one thing most likely wanted next; the rest is under "more".
    @ViewBuilder
    private var mainAction: some View {
        switch job.state {
        case .paused:
            Button("Resume") { queue.resume(job.id) }
                .buttonStyle(PillButtonStyle(kind: .primary))
        case .scheduled:
            Button("Start Now") { queue.startNow(job.id) }
                .buttonStyle(PillButtonStyle())
        case .retrying:
            Button("Try Now") { queue.startNow(job.id) }
                .buttonStyle(PillButtonStyle())
        case .waiting, .lookingUp, .running:
            Button("Pause") { queue.pause(job.id) }
                .buttonStyle(PillButtonStyle())
        case .done, .doneWithWarnings:
            if let first = job.files.first {
                Button(Opener.playLabel) { Opener.play(first) }
                    .buttonStyle(PillButtonStyle(kind: .primary))
            } else if let folder = job.folder {
                Button("Open Folder") { Opener.open(folder: folder) }
                    .buttonStyle(PillButtonStyle())
            }
        case .failed, .cancelled:
            if job.state == .failed, Messages.suggestsToolUpdate(job.message) {
                Button("Update, Then Retry") { AppModel.shared.tools.updateYtdlp { queue.retry(job.id) } }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .disabled(AppModel.shared.tools.isBusy)
            }
            Button("Retry") { queue.retry(job.id) }
                .buttonStyle(PillButtonStyle(kind: job.state == .failed ? .primary : .plain))
        }
    }

    @ViewBuilder
    private var moreActions: some View {
        switch job.state {
        case .retrying:
            Button("Pause") { queue.pause(job.id) }
            Button("Cancel") { queue.cancel(job.id) }
        case .paused, .scheduled, .waiting, .lookingUp, .running:
            Button("Cancel") { queue.cancel(job.id) }
        case .done, .doneWithWarnings:
            if let first = job.files.first {
                Button("Show in Finder") { Opener.reveal(first) }
            }
        case .failed, .cancelled:
            Button("Remove") { queue.remove(job.id) }
        }
        Divider()
        Button("Show the Log") { LogWindow.shared.show(job) }
    }

    private var statusColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            (Text(job.state.label).fontWeight(.semibold).foregroundColor(look.colour == p.subtext ? p.text : look.colour)
             + Text(status.isEmpty ? "" : " · " + status).foregroundColor(job.state == .failed ? p.bad : p.subtext))
                .font(p.font(12).monospacedDigit())
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if job.state.isActive && (job.progress.fraction == nil || job.state == .lookingUp) {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(p.fill)
                    .accessibilityLabel("Working on \(job.title)")
            } else {
                ThinBar(fraction: barFraction, colour: look.colour == p.accent ? p.fill : look.colour)
                    .accessibilityElement()
                    .accessibilityLabel("Progress for \(job.title)")
                    .accessibilityValue("\(Int((barFraction * 100).rounded())) percent")
                    .accessibilityHidden(!job.state.isActive)
            }
            ForEach(job.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(p.font(12))
                    .foregroundColor(p.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            StateTile(symbol: look.symbol, colour: look.colour)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title)
                    .font(p.font(14, .semibold))
                    .foregroundColor(p.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(job.detail)
                    .font(p.font(12))
                    .foregroundColor(p.subtext)
                    .lineLimit(1)
            }
            .frame(width: titleWidth, alignment: .leading)
            statusColumn
                .frame(maxWidth: .infinity, alignment: .leading)
            mainAction
            MoreMenu(label: "More actions for \(job.title)") { moreActions }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

struct QueueView: View {
    @ObservedObject private var queue = AppModel.shared.queue
    @Environment(\.palette) private var p

    /// The list's width, so every row gives its title the same share of it.
    private let width = State(initialValue: CGFloat(760))

    private func list(now: Date) -> some View {
        let titleWidth = min(max(width.wrappedValue * 0.3, 150), 320)
        return Grouped {
            // Newest first, so a download just started is at the top.
            ForEach(Array(queue.jobs.reversed().enumerated()), id: \.element.id) { pair in
                VStack(spacing: 0) {
                    if pair.offset > 0 { RowDivider() }
                    QueueRow(job: pair.element, now: now, titleWidth: titleWidth)
                }
            }
        }
        .background(GeometryReader { geometry in
            Color.clear
                .onAppear { width.wrappedValue = geometry.size.width }
                .onChange(of: geometry.size.width) { width.wrappedValue = $0 }
        })
    }

    var body: some View {
        let counts = queue.counts
        VStack(alignment: .leading, spacing: 12) {
            if queue.jobs.isEmpty {
                EmptyState(title: "Nothing here yet",
                           text: "Downloads appear on this screen as soon as you start one, and stay until you clear them.")
            } else {
                Text(counts.summary)
                    .font(p.font(12))
                    .foregroundColor(p.subtext)
                    .padding(.horizontal, 14)
                // The clock only ticks on screen while a download counts down to another try.
                if queue.jobs.contains(where: { if case .retrying = $0.state { return true } else { return false } }) {
                    TimelineView(.periodic(from: Date(), by: 1)) { context in
                        list(now: context.date)
                    }
                } else {
                    list(now: Date())
                }
            }
        }
        // What applies to every download sits in the window's toolbar.
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !queue.jobs.isEmpty {
                    if counts.paused > 0 {
                        Button { queue.resumeAll() } label: { Label("Resume All", systemImage: "play.fill") }
                    }
                    if counts.busy > 0 {
                        Button { queue.pauseAll() } label: { Label("Pause All", systemImage: "pause.fill") }
                    }
                    Button { queue.cancelAll() } label: { Label("Cancel All", systemImage: "xmark") }
                        .disabled(counts.unfinished == 0)
                    Button { queue.clearFinished() } label: { Label("Clear Finished", systemImage: "sparkles") }
                        .disabled(counts.finished == 0)
                }
            }
        }
        .labelStyle(.titleAndIcon)
    }
}

// MARK: - The log of one download

@MainActor
final class LogModel: ObservableObject {
    @Published var title = ""
    @Published var text = ""
    private var watching: Task<Void, Never>?

    /// Reads the job's log now and once a second while its window is open.
    func watch(_ job: Job, in queue: JobQueue) {
        watching?.cancel()
        title = job.title
        text = ""
        let id = job.id
        watching = Task { [weak self] in
            while !Task.isCancelled {
                let log = await queue.log(for: id).text
                guard let self, !Task.isCancelled else { return }
                if log != self.text { self.text = log }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() {
        watching?.cancel()
        watching = nil
    }
}

/// What the tools printed for one download, starting with the exact command.
@MainActor
final class LogWindow: NSObject, NSWindowDelegate {
    static let shared = LogWindow()
    private var window: NSWindow?
    private let model = LogModel()

    func show(_ job: Job) {
        model.watch(job, in: AppModel.shared.queue.queue)
        if window == nil {
            let host = NSHostingController(rootView: Themed { LogView(model: self.model) })
            let made = NSWindow(contentViewController: host)
            made.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            made.setContentSize(NSSize(width: 760, height: 480))
            made.isReleasedWhenClosed = false
            made.delegate = self
            made.center()
            window = made
        }
        window?.title = "Log: \(job.title)"
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
    }
}

private struct LogView: View {
    @ObservedObject var model: LogModel
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView([.vertical, .horizontal]) {
                Text(model.text.isEmpty ? "Nothing has been logged for this download yet. The log is kept only while \(Engine.productName) is open." : model.text)
                    .font(p.mono(11))
                    .foregroundColor(model.text.isEmpty ? p.subtext : p.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            RowDivider()
            HStack(spacing: 8) {
                Text("The first line is the exact command that ran.")
                    .font(p.font(12))
                    .foregroundColor(p.subtext)
                Spacer()
                Button("Copy the Log") { Opener.copy(model.text) }
                    .buttonStyle(PillButtonStyle())
                    .disabled(model.text.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(p.base)
        .frame(minWidth: 520, minHeight: 300)
    }
}
