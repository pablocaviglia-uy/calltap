import AppKit
import UserNotifications

/// "WhatsApp call — Record" when a call starts, and "Call recorded" when the file is saved.
final class CallNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let recordAction = "record"
    private static let callCategory = "call"
    private static let callRequest = "call"

    private let center = UNUserNotificationCenter.current()
    var onRecord: (() -> Void)?

    func setUp() {
        center.delegate = self
        let record = UNNotificationAction(identifier: Self.recordAction, title: "Record", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.callCategory, actions: [record], intentIdentifiers: [], options: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func callStarted() {
        let content = UNMutableNotificationContent()
        content.title = "WhatsApp call"
        content.body = "Record it? Let the other person know first."
        content.categoryIdentifier = Self.callCategory
        center.add(UNNotificationRequest(identifier: Self.callRequest, content: content, trigger: nil))
    }

    func clearCallPrompt() {
        center.removeDeliveredNotifications(withIdentifiers: [Self.callRequest])
    }

    func saved(_ url: URL) {
        let content = UNMutableNotificationContent()
        content.title = "Call recorded"
        content.body = url.lastPathComponent
        content.userInfo = ["path": url.path]
        center.add(UNNotificationRequest(identifier: "saved-\(UUID().uuidString)", content: content, trigger: nil))
    }

    func failed(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Recording failed"
        content.body = message
        center.add(UNNotificationRequest(identifier: "failed-\(UUID().uuidString)", content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let path = response.notification.request.content.userInfo["path"] as? String
        DispatchQueue.main.async {
            if action == Self.recordAction {
                self.onRecord?()
            } else if action == UNNotificationDefaultActionIdentifier, let path {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        completionHandler()
    }
}
