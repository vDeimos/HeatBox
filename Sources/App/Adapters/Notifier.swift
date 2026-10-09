// Notifier.swift: the banner shown when a download finishes or fails.

import AppKit
import Engine
import UserNotifications

enum Notifier {
    static let category = "DOWNLOAD_FINISHED"
    static let playAction = "PLAY"

    /// Notifications belong to an app bundle. A bare program (`swift run`)
    /// has none, and asking for the notification centre there would crash.
    private static var center: UNUserNotificationCenter? {
        Launch.isBundled ? UNUserNotificationCenter.current() : nil
    }

    static func setUp(delegate: UNUserNotificationCenterDelegate) {
        guard let center else { return }
        center.delegate = delegate
        let play = UNNotificationAction(identifier: playAction, title: "Play", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: category, actions: [play], intentIdentifiers: [], options: []),
        ])
    }

    private static func post(title: String, body: String, path: String?, offerPlay: Bool) {
        guard let center else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            if let path {
                content.userInfo = ["path": path]
                if offerPlay { content.categoryIdentifier = category }
            }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil),
                       withCompletionHandler: nil)
        }
    }

    static func finished(title: String, path: String?, offerPlay: Bool) {
        post(title: "Download finished", body: title, path: path, offerPlay: offerPlay)
    }

    static func converted(title: String, path: String, offerPlay: Bool) {
        post(title: "Conversion finished", body: title, path: path, offerPlay: offerPlay)
    }

    static func failed(title: String, reason: String) {
        post(title: "Download failed", body: reason.isEmpty ? title : "\(title): \(reason)", path: nil, offerPlay: false)
    }
}
