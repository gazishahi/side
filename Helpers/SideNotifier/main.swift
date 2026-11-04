import AppKit
import UserNotifications

// Side's notifier (SIDE_RFC_SESSION_RESTORE.md, Notifications): a session keeper runs it to tell
// the person something happened in a terminal while no Side window was attached to it. It posts
// one notification under Side's name and icon, then quits. Clicking the notification launches it
// again with the click, and it opens the session's side://run/<id> link, which brings Side to that
// tab.
//
// Usage: Side Notifier --title <title> --body <body> --url <side://run/id> [--group <id>]

final class Notifier: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private func value(_ flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        guard let body = value("--body") else {
            // Launched by a click: the response arrives through the delegate.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { NSApp.terminate(nil) }
            return
        }
        // Side's own switch (Settings → Notifications) covers these too.
        if UserDefaults(suiteName: "com.shahi.side")?.object(forKey: "attention.notifyWhenNeedsYou") as? Bool == false {
            NSApp.terminate(nil)
            return
        }
        let title = value("--title") ?? "Side"
        let url = value("--url")
        let group = value("--group")
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { DispatchQueue.main.async { NSApp.terminate(nil) }; return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            if let group { content.threadIdentifier = group }
            if let url { content.userInfo = ["url": url] }
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request) { _ in DispatchQueue.main.async { NSApp.terminate(nil) } }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let link = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}

let app = NSApplication.shared
let notifier = Notifier()
app.delegate = notifier
app.run()
