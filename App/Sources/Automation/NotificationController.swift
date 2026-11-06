import AppKit
import Foundation
import MeetingCore
@preconcurrency import UserNotifications

/// Native reminders with Join / Open notes / Dismiss actions (§11.3–11.4).
@MainActor
final class NotificationController: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private let center = UNUserNotificationCenter.current()
    var onAction: ((String, UUID) -> Void)?
    /// Occurrence IDs presented in-app right now; used to avoid duplicate foreground presentation.
    var inAppPresentedOccurrences: () -> Set<UUID> = { [] }

    override init() {
        super.init()
        center.delegate = self
        // Register actions at launch (§11.3).
        let join = UNNotificationAction(identifier: NotificationActionID.join, title: "Join", options: [.foreground])
        let notes = UNNotificationAction(identifier: NotificationActionID.openNotes, title: "Open notes", options: [.foreground])
        let dismiss = UNNotificationAction(identifier: NotificationActionID.dismiss, title: "Dismiss", options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: NotificationActionID.category, actions: [join, notes, dismiss], intentIdentifiers: [])])
        Task { await refreshAuthorization() }
    }

    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
    }

    /// Requested only when the user enables reminders (§11.3).
    func requestAuthorization() async -> Bool {
        let ok = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        await refreshAuthorization()
        AppServices.shared?.windows.refocusAfterSystemPrompt()
        return ok
    }

    func reconcile(_ desired: [ReminderRequest]) async {
        guard authorization == .authorized || authorization == .provisional else {
            center.removeAllPendingNotificationRequests()
            return
        }
        let pending = Set(await center.pendingNotificationRequests().map(\.identifier))
        let (add, remove) = ReminderPlanner.reconcile(desired: desired, pending: pending)
        center.removePendingNotificationRequests(withIdentifiers: Array(remove))
        // Remove delivered reminders whose occurrence is no longer desired (moved/cancelled/declined/dismissed).
        let desiredOcc = Set(desired.map(\.occurrenceID))
        let delivered = await center.deliveredNotifications().map(\.request.identifier)
        center.removeDeliveredNotifications(withIdentifiers: delivered.filter { id in
            guard let (occ, _) = ReminderPlanner.parse(identifier: id) else { return false }
            return !desiredOcc.contains(occ) && remove.contains(id)
        })
        for r in add {
            let content = UNMutableNotificationContent()
            content.title = r.title
            content.body = r.body
            content.sound = .default
            content.categoryIdentifier = NotificationActionID.category
            content.threadIdentifier = "meetings"
            // Only an opaque occurrence identifier; never a passcode-bearing URL or transcript (§11.3).
            content.userInfo = [NotificationActionID.occurrenceKey: r.occurrenceID.uuidString]
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: r.fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: r.identifier, content: content, trigger: trigger))
        }
        Log.notifications.info("reminders reconciled add=\(add.count, privacy: .public) remove=\(remove.count, privacy: .public)")
    }

    func removeAll() {
        center.removeAllPendingNotificationRequests()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let occ = (notification.request.content.userInfo[NotificationActionID.occurrenceKey] as? String).flatMap(UUID.init(uuidString:))
        let shown = await MainActor.run { occ.map { self.inAppPresentedOccurrences().contains($0) } ?? false }
        return shown ? [] : [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let s = response.notification.request.content.userInfo[NotificationActionID.occurrenceKey] as? String, let id = UUID(uuidString: s) else { return }
        let action = response.actionIdentifier == UNNotificationDefaultActionIdentifier ? NotificationActionID.openNotes : response.actionIdentifier
        await MainActor.run { self.onAction?(action, id) }
    }
}
