// MainWindow.swift: the window, the sidebar and what arrives from outside.

import AppKit
import Engine
import SwiftUI
import UniformTypeIdentifiers

/// The sidebar: macOS's own, so it collapses, resizes and reads as one. Its
/// toggle is the one the system puts in the toolbar.
struct Sidebar: View {
    @ObservedObject private var nav = AppModel.shared.nav
    @ObservedObject private var queue = AppModel.shared.queue
    @ObservedObject private var library = AppModel.shared.library
    @ObservedObject private var following = AppModel.shared.following
    @Environment(\.palette) private var p

    private func row(_ title: String, symbol: String, on: Bool) -> some View {
        Label {
            Text(title)
                .font(p.font(13, on ? .semibold : .medium))
                .foregroundColor(on ? p.onFill : p.text)
        } icon: {
            Image(systemName: symbol)
                .foregroundColor(on ? p.onFill : p.accent)
                .accessibilityHidden(true)
        }
    }

    /// The number beside a screen's name, and how VoiceOver says it.
    private func count(for screen: Screen) -> (number: Int, spoken: String) {
        switch screen {
        case .queue:
            let active = queue.counts.active
            return (active, "\(active) in progress")
        case .library:
            return (library.total, "\(library.total) saved")
        case .following:
            let fresh = following.freshCount
            return (fresh, "\(fresh) new")
        case .download, .convert:
            return (0, "")
        }
    }

    /// The artwork and the name, above the screens (ADR-011).
    private var brand: some View {
        VStack(spacing: 6) {
            BrandArt(height: 84)
            Text(Engine.productName)
                .font(p.font(17, .bold))
                .foregroundColor(p.text)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
        .padding(.bottom, 10)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Engine.productName)
    }

    var body: some View {
        List {
            brand
            ForEach(Screen.allCases) { screen in
                let on = nav.screen == screen
                let count = count(for: screen)
                Button {
                    nav.screen = screen
                } label: {
                    row(screen.label, symbol: screen.symbol, on: on)
                        .badge(count.number)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .focusShape(radius: 6, inset: -3)
                }
                .buttonStyle(.plain)
                // The selected row takes the accent chosen in Settings, not the Mac's.
                .listRowBackground(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(on ? p.fill : Color.clear)
                    .padding(.horizontal, 10))
                .accessibilityValue(count.number > 0 ? count.spoken : "")
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .listStyle(.sidebar)
        // The palette's sidebar colour over the system's own material, so the
        // sidebar stays translucent; lighter still where the sidebar is glass.
        .scrollContentBackground(.hidden)
        .background(p.mantle.opacity(Chrome.glass ? 0.30 : 0.72))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Settings sits at the bottom and opens its own window, as in
            // Apple's apps. Cmd-comma does the same.
            VStack(spacing: 0) {
                RowDivider()
                    .padding(.horizontal, 14)
                Button {
                    SettingsWindow.shared.show()
                } label: {
                    row("Settings", symbol: "gearshape", on: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                        .focusShape(radius: 8, inset: 6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 216, max: 280)
    }
}

/// Before macOS 26 the toolbar takes the window's colour. Where there is
/// glass the bar itself is clear: its buttons float, and the screen scrolls
/// beneath them.
private struct ToolbarTint: ViewModifier {
    @Environment(\.palette) private var p

    func body(content: Content) -> some View {
        if Chrome.glass {
            content.toolbarBackground(.hidden, for: .windowToolbar)
        } else {
            content.toolbarBackground(p.base, for: .windowToolbar)
        }
    }
}

/// The main window: the sidebar, and the chosen screen under a toolbar that
/// holds its title and its own actions.
struct MainWindow: View {
    @ObservedObject private var nav = AppModel.shared.nav
    @ObservedObject private var tools = AppModel.shared.tools
    @Environment(\.palette) private var p

    private var needsSetup: Bool { !tools.missing.isEmpty }

    /// How a screen sits in the window.
    private enum Layout {
        /// A readable column, for the screens that are read and filled in.
        case column
        /// The whole width, in one scrolling page.
        case wide
        /// The whole window: the screen has panes that scroll by themselves.
        case panes
    }

    private var layout: Layout {
        switch nav.screen {
        case .download: return .column
        case .queue, .convert: return .wide
        case .library, .following: return .panes
        }
    }

    @ViewBuilder
    private var screen: some View {
        switch nav.screen {
        case .download: DownloadView()
        case .queue: QueueView()
        case .library: LibraryView()
        case .following: FollowingView()
        case .convert: ConvertView()
        }
    }

    private var page: some View {
        ScrollView {
            screen
                .frame(maxWidth: layout == .column ? 680 : 1180, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 12)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if nav.screen == .download {
                DownloadFooter()
            }
        }
    }

    private var detail: some View {
        Group {
            if layout == .panes {
                screen
            } else {
                page
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            UpdateBanner()
                .padding(.top, 8)
        }
        .background(p.base)
        .modifier(ToolbarTint())
        .navigationTitle(nav.screen.label)
    }

    /// Whether the sidebar is showing. Held here so the toolbar's toggle and
    /// the View menu always have something to change.
    private let columns = State(initialValue: NavigationSplitViewVisibility.all)

    var body: some View {
        if needsSetup {
            // Nothing works until the tools are there, so Setup has the window to itself.
            SetupView()
                .modifier(ToolbarTint())
                .navigationTitle("Set Up")
        } else {
            NavigationSplitView(columnVisibility: columns.projectedValue) {
                Sidebar()
            } detail: {
                detail
            }
        }
    }
}

struct RootView: View {
    @ObservedObject private var tools = AppModel.shared.tools

    /// Something handed to the app from outside: one of its own links, a web
    /// link, or a .webloc file. It only ever fills in the Download screen.
    private func open(_ url: URL) {
        if let link = Links.linkFromOpened(url) {
            AppModel.shared.download.take(link: link)
        } else if url.isFileURL, let type = UTType(filenameExtension: url.pathExtension),
                  type.conforms(to: .movie) || type.conforms(to: .audio) {
            // A video or audio file is something to convert. It is only shown on the Convert screen.
            AppModel.shared.nav.screen = .convert
            AppModel.shared.convert.load(url.path)
        }
    }

    var body: some View {
        Themed {
            MainWindow()
                .overlay(Overlays())
        }
        .onAppear { AppModel.shared.tour.openIfFirstRun() }
        .onChange(of: tools.missing.isEmpty) { ready in
            if ready { AppModel.shared.tour.openIfFirstRun() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            tools.refresh()
        }
        .onOpenURL { open($0) }
        .onDrop(of: [UTType.fileURL, UTType.url, UTType.plainText], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in open(url) }
                }
                return true
            }
            if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text, LinkInput.read(text) != .none else { return }
                    Task { @MainActor in AppModel.shared.download.take(link: text) }
                }
                return true
            }
            return false
        }
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
    }
}

/// The Settings window, opened with Cmd-comma or from a "Change…" button.
/// It is an ordinary AppKit window so that it behaves the same on every
/// macOS version the app supports.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private(set) var window: NSWindow?
    private let nav = SettingsNavigation()

    private init() {}

    /// Opens Settings, at one of its parts when a button asks for that part.
    func show(_ section: SettingsSection? = nil) {
        if let section { nav.section = section }
        if window == nil {
            let host = NSHostingController(rootView: Themed { SettingsPage(nav: self.nav) })
            let made = NSWindow(contentViewController: host)
            made.title = "Settings"
            // The list of parts runs up the side of the window, beside its buttons.
            made.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            made.titlebarAppearsTransparent = true
            made.titleVisibility = .hidden
            made.setContentSize(NSSize(width: 820, height: 640))
            made.isReleasedWhenClosed = false
            made.center()
            window = made
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct SettingsPage: View {
    @ObservedObject var nav: SettingsNavigation
    @Environment(\.palette) private var p

    var body: some View {
        SettingsView(nav: nav)
            .background(p.base)
            .frame(minWidth: 740, minHeight: 440)
    }
}
