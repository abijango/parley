import Foundation
import UserNotifications

/// Posts "call detected" notifications with a Start action (for when auto-record
/// is off). `AppDelegate` is the `UNUserNotificationCenterDelegate` that routes
/// the Start action back to `RecordingController.start(detectionInitiated:)`.
@MainActor
final class CallNotifier {
    static let shared = CallNotifier()

    static let categoryID = "CALL_DETECTED"
    static let startActionID = "START_RECORDING"

    private let center = UNUserNotificationCenter.current()

    /// Registers the notification category + action and requests permission.
    func configure() {
        let start = UNNotificationAction(identifier: Self.startActionID, title: "Start recording", options: [.foreground])
        let category = UNNotificationCategory(identifier: Self.categoryID, actions: [start],
                                              intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            AppLog.log("Notification authorization granted=\(granted) error=\(error?.localizedDescription ?? "none")", category: "detect")
        }
    }

    func notifyCallDetected(_ call: DetectedCall) {
        let content = UNMutableNotificationContent()
        content.title = "Call detected — \(call.displayName)"
        content.body = "Start recording this call?"
        content.categoryIdentifier = Self.categoryID
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "call-\(call.pid)", content: content, trigger: nil)
        center.add(request) { error in
            if let error { AppLog.log("Notification post failed: \(error.localizedDescription)", category: "detect") }
        }
    }
}
