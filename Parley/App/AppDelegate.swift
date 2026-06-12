import AppKit
import UserNotifications

/// Handles lifecycle concerns SwiftUI doesn't cover: tearing down any active
/// audio tap / aggregate device on quit, and routing "Start recording"
/// notification actions back into the recording controller.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    // Earliest delegate hook — runs before the model/recording stores read their
    // Application Support paths, so a post-rename data migration lands first.
    func applicationWillFinishLaunching(_ notification: Notification) {
        SupportDirectoryMigration.runIfNeeded()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        MainActor.assumeIsolated { CallNotifier.shared.configure() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            // A clean quit isn't a crash: clear the model-load sentinel so a quit
            // during ANE specialization doesn't make the next launch wipe the
            // compiled-model cache (and pay a ~150s cold re-specialization).
            ModelManager.noteGracefulShutdown()
            RecordingController.shared.teardownForQuit()
        }
    }

    // Show the banner even when the app is frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // Start recording when the user taps the call-detected notification or its
    // Start action. Gated on the notification's category: the app posts other
    // notifications too (e.g. "Summary ready to review"), and a default-action
    // click on those must NOT kick off a phantom recording — it just brings the
    // app forward so the user can get to History.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        if category == CallNotifier.categoryID,
           id == CallNotifier.startActionID || id == UNNotificationDefaultActionIdentifier {
            Task { @MainActor in
                AppLog.log("Notification action — starting recording", category: "detect")
                await RecordingController.shared.start(detectionInitiated: true)
            }
        } else if id == UNNotificationDefaultActionIdentifier {
            NSApp.activate(ignoringOtherApps: true)
        }
        completionHandler()
    }
}
