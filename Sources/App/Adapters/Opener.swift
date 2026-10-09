// Opener.swift: playing a file, showing it in the Finder, and the clipboard.

import AppKit
import UniformTypeIdentifiers

enum Opener {
    /// IINA plays every format the downloader can produce; QuickTime does not.
    static let iina = URL(fileURLWithPath: "/Applications/IINA.app")

    static var hasIINA: Bool { FileManager.default.fileExists(atPath: iina.path) }

    static var playLabel: String { hasIINA ? "Play in IINA" : "Play" }

    /// Plays a file in IINA when it is installed, otherwise in whatever opens it.
    static func play(_ path: String) {
        let file = URL(fileURLWithPath: path)
        if hasIINA {
            NSWorkspace.shared.open([file], withApplicationAt: iina, configuration: NSWorkspace.OpenConfiguration(),
                                    completionHandler: nil)
        } else {
            NSWorkspace.shared.open(file)
        }
    }

    /// IINA's command-line tool, which can start a video at a chosen moment.
    private static let iinaCommand = "/Applications/IINA.app/Contents/MacOS/iina-cli"

    /// Plays a file from `seconds` (a little before, so the first word is not
    /// missed). Only IINA can; false means the file was opened from the start.
    @discardableResult
    static func play(_ path: String, at seconds: Double) -> Bool {
        if FileManager.default.isExecutableFile(atPath: iinaCommand) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: iinaCommand)
            process.arguments = ["--mpv-start=\(Int(max(seconds - 2, 0)))", path]
            process.standardInput = FileHandle.nullDevice
            if (try? process.run()) != nil { return true }
        }
        play(path)
        return false
    }

    /// Makes IINA the app that opens video files. False when IINA is not installed.
    static func makeIINADefault() -> Bool {
        guard hasIINA else { return false }
        var types: [UTType] = [.mpeg4Movie, .quickTimeMovie]
        for ext in ["mkv", "webm", "m4v", "avi"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        for type in types {
            NSWorkspace.shared.setDefaultApplication(at: iina, toOpen: type) { _ in }
        }
        return true
    }

    static func open(link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func open(folder: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: folder, isDirectory: true))
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
