import Foundation
import UserNotifications

/// A "your run finished" notification, derived from a real gateway terminal event.
/// Never a timer, never a guess — see designs/2026-09-07-push-notifications-decision.md.
struct RunNotification: Equatable {
    let title: String
    let body: String
    /// Which thread to open when the notification is tapped.
    let sessionKey: String

    /// nil for anything that is not a run ending.
    static func from(_ env: InboundEnvelope, threadTitle: String) -> RunNotification? {
        guard env.eventKind == "chat",
              let state = env.payload?.state,
              let sessionKey = env.payload?.sessionKey else { return nil }
        let title: String
        switch state {
        case "final":   title = "Run finished"
        case "aborted": title = "Run stopped"
        case "error":   title = "Run failed"
        default:        return nil     // delta, or anything still in flight
        }
        return RunNotification(title: title, body: threadTitle, sessionKey: sessionKey)
    }

    var content: UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["sessionKey": sessionKey]
        content.sound = .default
        return content
    }
}

/// Ask once, remember the answer, never nag.
struct NotificationPermission: Equatable {
    enum State: Equatable { case notDetermined, granted, denied }

    private(set) var state: State = .notDetermined

    var shouldAsk: Bool { state == .notDetermined }
    var canNotify: Bool { state == .granted }

    mutating func record(granted: Bool) { state = granted ? .granted : .denied }
}

/// Posts run-completion notifications. Foreground and briefly-backgrounded only: once iOS
/// suspends the socket there is no event to notify from, and the app does not pretend there is.
@MainActor
final class RunNotifier {
    private var permission = NotificationPermission()
    private let center: UNUserNotificationCenter?

    init(center: UNUserNotificationCenter? = .current()) {
        self.center = center
    }

    /// Called the first time a run could produce a notification — in context, not at launch.
    func requestPermissionIfNeeded() async {
        guard permission.shouldAsk, let center else { return }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        permission.record(granted: granted)
    }

    func post(_ notification: RunNotification) async {
        guard permission.canNotify, let center else { return }
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: notification.content, trigger: nil)
        try? await center.add(request)
    }
}
