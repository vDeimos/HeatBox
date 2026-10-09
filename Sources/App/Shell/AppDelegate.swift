// AppDelegate.swift: launching, closing the window, quitting, notifications.

import AppKit
import Engine
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.setUp(delegate: self)
        // Reads the saved queue before anything can be added to it.
        AppModel.shared.start()
        if Launch.isLaunchCheck { LaunchCheck.run() }
    }

    // Closing the window quits the app only when nothing is downloading or
    // scheduled. Otherwise the downloads carry on and the app quits by
    // itself after the last one.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        AppModel.shared.queue.counts.active == 0 && !AppModel.shared.convert.hasRunning
    }

    // Quitting outright (Cmd-Q) while downloads run asks first. Downloads are
    // paused, not lost: they are written down and carry on next time.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        let counts = model.queue.counts
        let converting = model.convert.hasRunning
        if (counts.active > 0 || converting) && !Launch.isLaunchCheck {
            var lines: [String] = []
            if counts.busy > 0 {
                lines.append("Quitting pauses your downloads. Next time you open \(Engine.productName), press Resume to carry on where they stopped.")
            }
            if counts.scheduled > 0 {
                lines.append("Scheduled downloads only start while \(Engine.productName) is open.")
            }
            if converting {
                lines.append("Conversions in progress are cancelled; the originals are untouched.")
            }
            let alert = NSAlert()
            alert.messageText = counts.busy > 0 ? "Downloads are still going"
                : (counts.scheduled > 0 ? "Downloads are scheduled" : "A conversion is still running")
            alert.informativeText = lines.joined(separator: " ") + " To let them carry on in the background, close the window instead."
            alert.addButton(withTitle: "Keep Going")
            alert.addButton(withTitle: "Quit")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        // Pauses what is running, writes the queue down, and waits for every tool to stop.
        let queue = model.queue.queue
        let conversions = model.convert.center
        Task {
            await conversions.cancelAll()
            await conversions.idle()
            await queue.prepareForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // Show the banner only when the app is not the one in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        DispatchQueue.main.async {
            completionHandler(NSApp.isActive ? [] : [.banner, .sound])
        }
    }

    // The Play button on a finished-download notification.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let path = response.actionIdentifier == Notifier.playAction
            ? response.notification.request.content.userInfo["path"] as? String : nil
        DispatchQueue.main.async {
            if let path { Opener.play(path) }
            completionHandler()
        }
    }
}

/// Quitting from code. `terminate` waits, inside its own event loop, for the
/// queue to stop its tools, and that waiting is done by main-actor tasks. The
/// main queue runs one block at a time, so a `terminate` called from inside a
/// task or a main-queue block would wait for work that can never start. Going
/// through the run loop instead keeps the main queue free.
@MainActor
enum Quit {
    static func request() {
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
    }
}

/// `--launch-check`: proves the built app starts, reads its queue and puts
/// its window on screen, then quits. Fails (exit 1) after twenty seconds.
@MainActor
enum LaunchCheck {
    static func run() {
        Task {
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                let ready = AppModel.shared.queue.isReady
                let window = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
                if ready && window {
                    let tools = AppModel.shared.tools.statuses.map { "\($0.tool.rawValue)=\($0.found ? "found" : "missing")" }
                    print("launch ok: window up, queue read (\(AppModel.shared.queue.jobs.count) jobs), \(tools.joined(separator: " "))")
                    fflush(stdout)
                    Quit.request()
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            let windows = NSApp.windows.map { "\($0.className)(visible=\($0.isVisible), main=\($0.canBecomeMain))" }
            let report = "launch check failed: queue read=\(AppModel.shared.queue.isReady), "
                + "windows=[\(windows.joined(separator: ", "))], screens=\(NSScreen.screens.count), "
                + "active=\(NSApp.isActive), policy=\(NSApp.activationPolicy().rawValue)\n"
            FileHandle.standardError.write(Data(report.utf8))
            exit(1)
        }
    }
}
