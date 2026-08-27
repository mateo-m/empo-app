import Foundation
import GameProbe
import UserNotifications

/// The three local notifications of SPEC 7.11, and nothing else.
///
/// Notify only when a problem exists and only user action can clear
/// it. Progress, completion, staleness warnings, and self-healing
/// pauses stay silent forever. The writer split never notifies,
/// because it heals itself.
///
/// The rules and the copy live in `BackupNotificationRule` and
/// `BackupNotificationLedger`, inside GameProbe. This file asks for
/// permission and posts.
@MainActor
enum BackupNotifier {

    /// Empo asks after the user configures their first target, never
    /// at first launch.
    static func askForPermissionIfNeeded(configuredTargetCount: Int) async {
        let asked = UserDefaults.standard.bool(forKey: DefaultsKey.backupNotificationsAsked)
        guard
            BackupNotificationRule.asksForPermission(
                configuredTargetCount: configuredTargetCount, hasAsked: asked)
        else { return }
        UserDefaults.standard.set(true, forKey: DefaultsKey.backupNotificationsAsked)
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    /// Posts what one run found on one target, and keeps the ledger
    /// so nothing posts twice.
    ///
    /// The ledger lives in `state.sqlite`. A rebuilt cache re-arms
    /// every cause, which costs the user one repeated notification
    /// and never a missed one.
    static func report(
        causes: Set<BackupFailFastCause>,
        targetId: String,
        targetLabel: String,
        store: BackupStateStore
    ) {
        var ledger = (try? store.notificationLedger()) ?? BackupNotificationLedger()
        let toPost = ledger.post(causes: causes, targetId: targetId)
        try? store.saveNotificationLedger(ledger)
        for cause in toPost {
            post(cause, targetLabel: targetLabel)
        }
    }

    private static func post(_ cause: BackupFailFastCause, targetLabel: String) {
        let content = UNMutableNotificationContent()
        content.body = BackupNotificationRule.text(
            for: cause,
            targetLabel: targetLabel,
            deviceName: BackupDeviceConditions.deviceName)
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "\(cause.rawValue).\(targetLabel)",
            content: content,
            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
