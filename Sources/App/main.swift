// main.swift: how the program starts.
//
//   StudioXPhobos                     opens the app
//   StudioXPhobos --smoke             says the program links and runs, without opening anything
//   StudioXPhobos --identity          prints the app's name, bundle id, link scheme and version
//                                     (scripts/build.sh writes Info.plist from this, so they
//                                     are named in one place only: Engine.swift)
//   StudioXPhobos --launch-check      opens the app, waits for its window and queue, then quits
//   --support-folder=<path>           keep the app's own files somewhere else for this run
//   --pretend-missing=deno,ffmpeg     show the setup screen as if those tools were absent
//   --update-notice=<file>            show the new-version banner from a notice file on this Mac
//   --no-glass                        draw the app as macOS 13 to 15 do, without macOS 26's glass
//
// A value is always part of its option's word: AppKit takes a bare word on the
// command line for a file to open.

import AppKit
import Engine
import SwiftUI

struct StudioXPhobosApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var settings = AppModel.shared.settings

    var body: some Scene {
        WindowGroup(Engine.productName) {
            RootView()
                .frame(minWidth: 860, idealWidth: 1100, minHeight: 600, idealHeight: 820)
                .preferredColorScheme(settings.value.theme.scheme)
        }
        .windowToolbarStyle(.unified)
        .handlesExternalEvents(matching: ["*"])
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Download") { AppModel.shared.nav.screen = .download }
                    .keyboardShortcut("n")
            }
            // View > Show or Hide Sidebar, with the system's shortcut.
            SidebarCommands()
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { SettingsWindow.shared.show() }
                    .keyboardShortcut(",")
            }
            CommandMenu("Go") {
                Button("Download") { AppModel.shared.nav.screen = .download }
                    .keyboardShortcut("1")
                Button("Queue") { AppModel.shared.nav.screen = .queue }
                    .keyboardShortcut("2")
                Button("Library") { AppModel.shared.nav.screen = .library }
                    .keyboardShortcut("3")
                Button("Following") { AppModel.shared.nav.screen = .following }
                    .keyboardShortcut("4")
                Button("Convert") { AppModel.shared.nav.screen = .convert }
                    .keyboardShortcut("5")
                Divider()
                Button("Command Bar…") { AppModel.shared.commands.toggle() }
                    .keyboardShortcut("k")
            }
            CommandGroup(replacing: .help) {
                Button("Welcome Tour") { AppModel.shared.tour.open() }
                Button("Licences and Notices") {
                    if let url = Bundle.main.url(forResource: "NOTICES", withExtension: "txt") { NSWorkspace.shared.open(url) }
                }
            }
        }
    }
}

if CommandLine.arguments.contains("--smoke") {
    print("\(Engine.productName) \(Engine.version) ok")
} else if CommandLine.arguments.contains("--identity") {
    print("name=\(Engine.productName)")
    print("executable=\(Engine.executableName)")
    print("bundle=\(Engine.bundleIdentifier)")
    print("scheme=\(Engine.urlScheme)")
    print("version=\(Engine.version)")
} else {
    // One copy at a time on a data folder: a second one would restart the
    // first one's downloads. It shows the first and quits instead.
    if !Launch.claimDataFolder() {
        Launch.showRunningCopy()
        print("\(Engine.productName) is already open.")
        exit(0)
    }
    // A bare program (swift run) has no bundle to say it is an ordinary app.
    if !Launch.isBundled { NSApplication.shared.setActivationPolicy(.regular) }
    StudioXPhobosApp.main()
}
