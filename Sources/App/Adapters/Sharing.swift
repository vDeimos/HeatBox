// Sharing.swift: getting a file onto an iPhone, and the ordinary share menu.
// A file the phone can play is sent as it is; any other gets a phone-friendly
// copy first, saved beside the original. The original is never changed.

import AppKit
import Engine

@MainActor
enum PhoneSender {
    private static var picker: NSSharingServicePicker?

    /// Checks the file, makes a copy if it needs one, then opens AirDrop.
    /// What is going on is said on the Library screen.
    static func send(_ path: String) {
        let model = AppModel.shared
        model.library.notice = Messages.phoneChecking
        let registry = model.tools.registry
        Task {
            guard let facts = await FileInspector.inspect(path, tools: registry) else {
                model.library.notice = Messages.unreadableFile
                return
            }
            switch PhoneSend.decide(path: path, facts: facts) {
            case .ready:
                model.library.notice = nil
                share(path)
            case .impossible:
                model.library.notice = Messages.phoneCopyImpossible
            case .needsCopy(let plan):
                if ConvertDraft.asksOnBattery(plan, onBattery: BatteryPower().onBattery) && !confirmOnBattery() {
                    model.library.notice = nil
                    return
                }
                model.library.notice = Messages.phoneMakingCopy
                if let output = await model.convert.makeCopy(of: path, plan: plan, label: Messages.convertLabelPhone) {
                    model.library.notice = nil
                    share(output)
                } else {
                    model.library.notice = Messages.phoneCopyFailed
                }
            }
        }
    }

    private static func confirmOnBattery() -> Bool {
        let alert = NSAlert()
        alert.messageText = Messages.convertBatteryTitle
        alert.informativeText = Messages.phoneBatteryText
        alert.addButton(withTitle: "Make the Copy")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Opens AirDrop with the file ready. If AirDrop is not available, shows
    /// the ordinary share menu instead.
    static func share(_ path: String) {
        let url = URL(fileURLWithPath: path)
        NSApp.activate(ignoringOtherApps: true)
        if let airDrop = NSSharingService(named: .sendViaAirDrop), airDrop.canPerform(withItems: [url]) {
            airDrop.perform(withItems: [url])
        } else {
            shareMenu(path)
        }
    }

    /// The standard macOS share menu: Messages, Mail, AirDrop and the rest.
    static func shareMenu(_ path: String) {
        guard let view = (NSApp.keyWindow ?? NSApp.mainWindow)?.contentView else { return }
        let sharing = NSSharingServicePicker(items: [URL(fileURLWithPath: path)])
        picker = sharing
        let anchor = NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        sharing.show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }
}
