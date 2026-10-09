// SystemState.swift: keeping the Mac awake while the app is working, and
// the number on the Dock icon.

import AppKit
import Engine

@MainActor
enum SystemState {
    /// What keeps the Mac awake. Each is on only while it is really working.
    enum Work: Hashable {
        case downloading, converting, reading

        var reason: String {
            switch self {
            case .downloading: return "\(Engine.productName) is downloading"
            case .converting: return "\(Engine.productName) is converting a file"
            case .reading: return "\(Engine.productName) is reading what was said in videos"
            }
        }
    }

    private static var awake: [Work: NSObjectProtocol] = [:]

    /// `busy` is what is downloading or about to; `active` also counts what
    /// is scheduled. The Mac is kept awake only while something is really
    /// downloading, not while a download merely waits for its time.
    static func update(busy: Int, active: Int) {
        NSApp.dockTile.badgeLabel = active > 0 ? "\(active)" : nil
        keepAwake(.downloading, busy > 0)
    }

    /// Starts or ends the hold for one kind of work.
    static func keepAwake(_ work: Work, _ on: Bool) {
        if on, awake[work] == nil {
            awake[work] = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: work.reason)
        } else if !on, let token = awake.removeValue(forKey: work) {
            ProcessInfo.processInfo.endActivity(token)
        }
    }

    static var isKeepingAwake: Bool { !awake.isEmpty }
}
