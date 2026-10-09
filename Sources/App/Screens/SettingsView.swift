// SettingsView.swift: folders, file names, appearance, downloads, spoken
// words, sign-in, the browser button, tools.
//
// These are defaults (plan Rule 6). Each change is written to settings.json
// at once and reaches the queue and the tool registry through `SettingsModel`.

import AppKit
import Engine
import SwiftUI

extension FinishAction {
    var label: String {
        switch self {
        case .notifyOnly: return "Notify only"
        case .notifyAndOffer: return "Notify and offer Play"
        case .playNow: return "Play straight away"
        }
    }
}

extension NameStyle {
    var label: String {
        switch self {
        case .title: return "Title"
        case .uploaderTitle: return "Uploader and title"
        case .dateTitle: return "Date and title"
        }
    }
}

/// The parts of Settings, listed down the side of its window.
enum SettingsSection: String, CaseIterable, Identifiable {
    case folders, fileNames, appearance, downloads, spoken, signIn, browser, tools

    var id: String { rawValue }

    var label: String {
        switch self {
        case .folders: return "Folders"
        case .fileNames: return "File Names"
        case .appearance: return "Appearance"
        case .downloads: return "Downloads"
        case .spoken: return "Spoken-word Search"
        case .signIn: return "Sign-in"
        case .browser: return "Browser Button"
        case .tools: return "Tools"
        }
    }

    var symbol: String {
        switch self {
        case .folders: return "folder"
        case .fileNames: return "square.and.pencil"
        case .appearance: return "paintbrush"
        case .downloads: return "arrow.down.circle"
        case .spoken: return "mic"
        case .signIn: return "person.crop.circle"
        case .browser: return "safari"
        case .tools: return "wrench.and.screwdriver"
        }
    }
}

/// Which part of Settings is showing. Held outside the view so a button on
/// another screen can open Settings at the right part.
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var section = SettingsSection.folders
}

struct SettingsView: View {
    @ObservedObject var nav: SettingsNavigation
    @ObservedObject private var settings = AppModel.shared.settings
    @ObservedObject private var tools = AppModel.shared.tools
    @ObservedObject private var spoken = AppModel.shared.spoken
    @Environment(\.palette) private var p
    private let notice = State<String?>(initialValue: nil)
    private let capturing = State(initialValue: false)
    private let signInMessage = State<String?>(initialValue: nil)

    private let sample = VideoFacts(id: "", title: "Sample video title", uploader: "Channel name", uploadDate: "20261004")

    private func sectionRow(_ section: SettingsSection) -> some View {
        let on = nav.section == section
        return Button {
            nav.section = section
        } label: {
            Label {
                Text(section.label)
                    .font(p.font(13, on ? .semibold : .medium))
                    .foregroundColor(on ? p.onFill : p.text)
            } icon: {
                Image(systemName: section.symbol)
                    .foregroundColor(on ? p.onFill : p.accent)
                    .frame(width: 20)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? p.fill : Color.clear))
            .contentShape(Rectangle())
            .focusShape(radius: 8)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    /// The parts, down the left. The window's own buttons sit above the title.
    private var sections: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings")
                .font(p.font(20, .bold))
                .foregroundColor(p.text)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .accessibilityAddTraits(.isHeader)
            ForEach(SettingsSection.allCases) { sectionRow($0) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 44)
        .padding(.bottom, 12)
        .frame(width: 216)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(p.mantle)
    }

    @ViewBuilder
    private var page: some View {
        switch nav.section {
        case .folders: folders
        case .fileNames: fileNames
        case .appearance: appearance
        case .downloads: downloads
        case .spoken: spokenSearch
        case .signIn: signIn
        case .browser: browserButton
        case .tools: toolsGroup
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sections
            Rectangle().fill(p.separator).frame(width: 1).accessibilityHidden(true)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(nav.section.label)
                        .font(p.font(24, .bold))
                        .foregroundColor(p.text)
                        .padding(.horizontal, 14)
                        .accessibilityAddTraits(.isHeader)
                    if let message = notice.wrappedValue {
                        Text(message)
                            .font(p.font(12))
                            .foregroundColor(p.good)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14)
                    }
                    page
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 40)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(p.base)
        }
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: nav.section) { _ in notice.wrappedValue = nil }
    }

    // MARK: Spoken words

    private var spokenSearch: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grouped {
                SwitchRow(title: "Find words said in your videos",
                          detail: "Reads each video's captions, so the Library can search what was said and open the video at that moment.",
                          isOn: $settings.value.spokenSearch)
                if settings.value.spokenSearch {
                    RowDivider()
                    SwitchRow(title: "Listen to videos that have no captions",
                              detail: "Uses this Mac's own speech recognition, so nothing leaves your Mac. It only runs on mains power, and takes a while.",
                              isOn: $settings.value.transcribeLocally)
                    RowDivider()
                    Text(spoken.status.line)
                        .font(p.font(12))
                        .foregroundColor(p.subtext)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    RowDivider()
                    ControlRow(label: "Videos without words") {
                        Button("Try Again") { spoken.startOver() }
                            .buttonStyle(PillButtonStyle())
                    }
                }
            }
            Caption("Captions come from the video's site, one small request per video, only while this is on. Music and crosstalk are recognised poorly.")
        }
    }

    // MARK: Sign-in

    private var signInStatus: String {
        guard let date = SignIn.savedDate(paths: AppModel.shared.paths) else { return Messages.signInNone }
        return "Saved sign-in last refreshed \(date.formatted(date: .abbreviated, time: .shortened)). To refresh it, use 'Copy my sign-in' below."
    }

    private func captureSignIn() {
        capturing.wrappedValue = true
        signInMessage.wrappedValue = nil
        let browser = settings.value.signInBrowser
        let registry = tools.registry
        let destination = AppModel.shared.paths.signInFile
        Task {
            let problem = await SignIn.capture(browser: browser, to: destination, tools: registry)
            capturing.wrappedValue = false
            signInMessage.wrappedValue = problem ?? Messages.signInSaved
            // A sign-in that is switched on is used from the next download.
            AppModel.shared.settingsChanged()
        }
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grouped {
                SwitchRow(title: "Use my saved YouTube sign-in", detail: signInStatus, isOn: $settings.value.useSignIn)
                RowDivider()
                ControlRow(label: "Browser") {
                    Picker("Browser", selection: $settings.value.signInBrowser) {
                        ForEach(SignIn.browsers, id: \.self) { browser in
                            Text(browser.rawValue.capitalized).tag(browser)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                RowDivider()
                ControlRow(label: "Copy my sign-in") {
                    Button(capturing.wrappedValue ? "Reading…" : "From \(settings.value.signInBrowser.rawValue.capitalized)") {
                        captureSignIn()
                    }
                    .buttonStyle(PillButtonStyle())
                    .disabled(capturing.wrappedValue)
                }
                if let message = signInMessage.wrappedValue {
                    RowDivider()
                    Text(message)
                        .font(p.font(12))
                        .foregroundColor(p.warn)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
                RowDivider()
                ControlRow(label: "Full Disk Access") {
                    Button("Open System Settings…") {
                        Opener.open(link: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
                    }
                    .buttonStyle(PillButtonStyle())
                }
            }
            Caption("Only needed for members-only and age-restricted videos. Pressing the button reads that browser's YouTube and Google cookies once and keeps them in a private file of \(Engine.productName)'s own; nothing from other sites is kept. YouTube can restrict accounts that download heavily while signed in, so leave this off when you don't need it.")
        }
    }

    // MARK: Browser button

    private var browserButton: some View {
        Card {
            Text("Send the page you are looking at in any browser to \(Engine.productName) with one click.")
                .font(p.font(13))
                .foregroundColor(p.text)
                .fixedSize(horizontal: false, vertical: true)
            Text("1. Press the button below to copy the button's code.\n2. In your browser, add a new bookmark to the bookmarks bar. Name it Send to \(Engine.productName) and paste the code into the address box.\n3. On any video page, click that bookmark. The browser asks once whether it may open \(Engine.productName); allow it. The link is only filled in on the Download screen: nothing downloads until you choose.")
                .font(p.font(12))
                .foregroundColor(p.subtext)
                .fixedSize(horizontal: false, vertical: true)
            Button("Copy the Button's Code") {
                Opener.copy(Links.bookmarklet)
                notice.wrappedValue = "The button's code is copied. Paste it into the address box of a new bookmark."
            }
            .buttonStyle(PillButtonStyle())
        }
    }

    // MARK: Folders

    private func chooseFolder(startingAt current: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if FileManager.default.fileExists(atPath: current) {
            panel.directoryURL = URL(fileURLWithPath: current)
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private func folderRow(_ label: String, path: String, isCustom: Bool = false,
                           change: @escaping (String) -> Void, reset: (() -> Void)? = nil) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(p.font(13))
                .foregroundColor(p.text)
                .frame(width: 100, alignment: .leading)
            Text(Naming.breadcrumb(path))
                .font(p.font(13))
                .foregroundColor(p.subtext)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Button("Change…") {
                if let chosen = chooseFolder(startingAt: path) { change(chosen) }
            }
            .buttonStyle(PillButtonStyle())
            .accessibilityLabel("Change the folder for \(label)")
            if isCustom, let reset {
                Button("Reset") { reset() }
                    .buttonStyle(PillButtonStyle())
                    .accessibilityLabel("Reset the folder for \(label)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var folders: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grouped {
                folderRow("Main folder", path: settings.value.folders.mainFolder,
                          change: { settings.value.folders.mainFolder = $0 })
                ForEach(settings.value.knownSites, id: \.self) { site in
                    let custom = settings.value.folders.perSite[site]
                    VStack(spacing: 0) {
                        RowDivider()
                        folderRow(site,
                                  path: custom ?? settings.value.folders.folder(site: site, audioOnly: false, playlistTitle: nil),
                                  isCustom: custom != nil,
                                  change: { settings.value.folders.perSite[site] = $0 },
                                  reset: { settings.value.folders.perSite[site] = nil })
                    }
                }
                RowDivider()
                folderRow("Audio", path: settings.value.folders.audioFolder,
                          change: { settings.value.folders.audioFolder = $0 })
                RowDivider()
                SwitchRow(title: "Give each playlist its own subfolder", isOn: $settings.value.folders.playlistSubfolder)
                RowDivider()
                ControlRow(label: "Main folder in the Finder") {
                    Button("Open") { Opener.open(folder: settings.value.folders.mainFolder) }
                        .buttonStyle(PillButtonStyle())
                }
            }
            Caption("Sites appear here after your first download from them. A site without its own folder uses a subfolder of the main folder.")
        }
    }

    // MARK: File names

    private var fileNames: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grouped {
                ForEach(Array(NameStyle.allCases.enumerated()), id: \.element) { pair in
                    let style = pair.element
                    let on = settings.value.nameStyle == style
                    VStack(spacing: 0) {
                        if pair.offset > 0 { RowDivider() }
                        Button {
                            settings.value.nameStyle = style
                        } label: {
                            HStack(spacing: 12) {
                                RadioMark(on: on)
                                Text(style.label)
                                    .font(p.font(13))
                                    .foregroundColor(p.text)
                                    .frame(width: 150, alignment: .leading)
                                Text(Naming.fileStem(style: style, facts: sample) + ".mp4")
                                    .font(p.font(12))
                                    .foregroundColor(p.subtext)
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? [.isSelected] : [])
                    }
                }
            }
            Caption("If two videos would get the same name, the second gets a number, such as \"Title (2).mp4\".")
        }
    }

    // MARK: Appearance

    private var appearance: some View {
        Grouped {
            ControlRow(label: "Theme") {
                Segmented(options: ThemeChoice.allCases.map { (value: $0, label: $0.label) },
                          selection: $settings.value.theme)
            }
            RowDivider()
            ControlRow(label: "Accent colour") {
                HStack(spacing: 10) {
                    ForEach(AccentChoice.allCases, id: \.self) { accent in
                        let on = settings.value.accent == accent
                        Button {
                            settings.value.accent = accent
                        } label: {
                            Circle()
                                .fill(accent.fill)
                                .frame(width: 22, height: 22)
                                .overlay(Circle().stroke(on ? p.text : Color.clear, lineWidth: 2).padding(-4))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(accent.label)
                        .accessibilityAddTraits(on ? [.isSelected] : [])
                    }
                }
                .padding(.vertical, 4)
                .padding(.trailing, 4)
            }
            RowDivider()
            ControlRow(label: "Text size") {
                Segmented(options: [(value: false, label: "Standard"), (value: true, label: "Large")],
                          selection: $settings.value.largeText)
            }
        }
    }

    // MARK: Downloads

    private var downloads: some View {
        Grouped {
            ControlRow(label: "At the same time") {
                Segmented(options: QueueSettings.concurrencyRange.map { (value: $0, label: "\($0)") },
                          selection: $settings.value.maxConcurrent)
            }
            RowDivider()
            ControlRow(label: "When one finishes") {
                Picker("When one finishes", selection: $settings.value.finish) {
                    ForEach(FinishAction.allCases, id: \.self) { action in
                        Text(action.label).tag(action)
                    }
                }
                .labelsHidden()
                .frame(width: 210)
            }
            RowDivider()
            ControlRow(label: "Speed limit") {
                Picker("Speed limit", selection: $settings.value.speedLimitKB) {
                    ForEach(SpeedLimit.options, id: \.kilobytes) { option in
                        Text(option.label).tag(option.kilobytes)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
            }
            RowDivider()
            SwitchRow(title: "Try again when the connection drops",
                      detail: "Up to three times, waiting a little longer each time.",
                      isOn: $settings.value.autoRetry)
            RowDivider()
            SwitchRow(title: "Include subtitles when a video has them",
                      detail: "Kept inside the file. Switch them on in your player.",
                      isOn: $settings.value.subtitles)
            RowDivider()
            SwitchRow(title: "Use the video's picture as the file's cover image",
                      detail: "Saves as MKV unless you pick Plays everywhere or audio.",
                      isOn: $settings.value.coverImage)
            RowDivider()
            SwitchRow(title: "Cut sponsor segments out of YouTube videos", isOn: $settings.value.cutSponsors)
            RowDivider()
            SwitchRow(title: "Even out the volume of audio downloads",
                      detail: "So a playlist doesn't jump from quiet to loud. Takes a little longer.",
                      isOn: $settings.value.evenLoudness)
        }
    }

    // MARK: Tools

    private func chooseTool(_ tool: Tool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.prompt = "Use This"
        panel.message = "Choose the \(tool.rawValue) program to use."
        if let current = tools.registry.path(tool) {
            panel.directoryURL = URL(fileURLWithPath: current).deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            notice.wrappedValue = "That file is not a program, so the earlier \(tool.rawValue) is still used."
            return
        }
        settings.value.setOverride(path, for: tool)
    }

    private func sourceLabel(_ location: ToolLocation) -> String {
        switch location.source {
        case .userOverride: return "Chosen by you"
        case .managed: return "Installed by \(Engine.productName)"
        case .system: return location.path.hasPrefix("/usr/bin/") ? "Part of macOS" : "From Homebrew"
        }
    }

    private func toolRow(_ status: ToolStatus) -> some View {
        HStack(spacing: 10) {
            Image(systemName: status.found ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(status.found ? p.good : p.bad)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(status.tool.rawValue)
                        .font(p.font(13, .semibold))
                        .foregroundColor(p.text)
                    if let version = tools.version(of: status.tool) {
                        Text(version)
                            .font(p.font(12).monospacedDigit())
                            .foregroundColor(p.subtext)
                    }
                }
                if let location = status.location {
                    Text("\(sourceLabel(location)) · \(location.path)")
                        .font(p.font(12))
                        .foregroundColor(p.subtext)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    Text("Missing. \(status.tool.purpose).")
                        .font(p.font(12))
                        .foregroundColor(p.bad)
                }
            }
            Spacer(minLength: 8)
            if status.location?.source != .managed {
                Button(status.found ? "Install Copy" : "Install") { tools.install([status.tool]) }
                    .buttonStyle(PillButtonStyle(kind: status.found ? .plain : .primary))
                    .disabled(tools.isBusy)
                    .accessibilityLabel("Install \(Engine.productName)'s own copy of \(status.tool.rawValue)")
            }
            Button("Choose…") { chooseTool(status.tool) }
                .buttonStyle(PillButtonStyle())
                .accessibilityLabel("Choose the \(status.tool.rawValue) program")
            if settings.value.toolPaths[status.tool.rawValue] != nil {
                Button("Reset") { settings.value.setOverride(nil, for: status.tool) }
                    .buttonStyle(PillButtonStyle())
                    .accessibilityLabel("Go back to the usual \(status.tool.rawValue)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// Versions and counts for a bug report, saved where the person chooses.
    private func saveDiagnostics() {
        let model = AppModel.shared
        let rows = tools.statuses.map { status -> Diagnostics.Tool in
            let source: String
            switch status.location?.source {
            case .userOverride?: source = "chosen by you"
            case .managed?: source = "installed by the app"
            case .system?: source = "Homebrew or system"
            case nil: source = "not found"
            }
            return Diagnostics.Tool(name: status.tool.rawValue,
                                    version: status.location.flatMap { tools.versions[$0.path] }, source: source)
        }
        var chip = "unknown chip"
        #if arch(arm64)
        chip = "Apple silicon"
        #elseif arch(x86_64)
        chip = "Intel"
        #endif
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "dev"
        let text = Diagnostics.report(.init(
            appVersion: UpdateChecker.currentVersion, build: build,
            system: ProcessInfo.processInfo.operatingSystemVersionString, chip: chip, tools: rows,
            jobs: model.queue.jobs, settings: settings.value,
            freeSpace: DiskSpace.available(at: settings.value.folders.mainFolder)))
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(Engine.productName) diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            notice.wrappedValue = Messages.diagnosticsSaved
        } catch {
            notice.wrappedValue = Messages.diagnosticsCannotSave
        }
    }

    private static let upgradeCommand = "brew upgrade yt-dlp ffmpeg deno"

    private var toolsGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grouped {
                ForEach(Array(tools.statuses.enumerated()), id: \.element.tool) { pair in
                    VStack(spacing: 0) {
                        if pair.offset > 0 { RowDivider() }
                        toolRow(pair.element)
                    }
                }
                RowDivider()
                // Three buttons do not fit beside their label in a narrow window, so they sit under it.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Keep them current")
                        .font(p.font(13))
                        .foregroundColor(p.text)
                    HStack(spacing: 8) {
                        Button("Update yt-dlp") { tools.updateYtdlp() }
                            .buttonStyle(PillButtonStyle(kind: .primary))
                            .disabled(tools.isBusy)
                        Button("Copy the Homebrew Command") {
                            Opener.copy(Self.upgradeCommand)
                            notice.wrappedValue = "Copied. Paste it into Terminal and press Return: \(Self.upgradeCommand)"
                        }
                        .buttonStyle(PillButtonStyle())
                        Button("Check Again") { tools.refresh() }
                            .buttonStyle(PillButtonStyle())
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                if tools.provision != .idle {
                    ProvisionLine()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                RowDivider()
                ControlRow(label: "Bug reports") {
                    Button("Save Diagnostics…") { saveDiagnostics() }
                        .buttonStyle(PillButtonStyle())
                        .accessibilityLabel("Save a diagnostics file for a bug report")
                }
                RowDivider()
                ControlRow(label: "Video player") {
                    Button("Make IINA the Default") {
                        notice.wrappedValue = Opener.makeIINADefault()
                            ? "IINA is now set as the player for MP4, MOV, MKV, WebM, M4V and AVI files. macOS may ask you to confirm."
                            : "IINA is not in the Applications folder."
                    }
                    .buttonStyle(PillButtonStyle())
                }
            }
            Caption("\(Engine.productName) \(UpdateChecker.currentVersion). These free programs do the downloading and converting. The programs \(Engine.productName) installs are kept in its own folder and checked against a fixed fingerprint first; they are used before Homebrew's. FFmpeg is a GPL-licensed build by martin-riedl.de, yt-dlp is public domain and Deno is MIT-licensed. When a site changes and downloads start failing, updating yt-dlp usually fixes it.")
        }
    }
}
