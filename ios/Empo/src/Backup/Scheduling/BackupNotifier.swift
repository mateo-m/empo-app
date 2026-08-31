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

    /// Shows a banner for a notification that posts while Empo is
    /// open.
    ///
    /// 7.11 says a cause posts "from the nightly task or the
    /// foreground pass". A foreground pass runs while the app is
    /// open, and iOS shows no banner then unless a delegate asks for
    /// one. Without this the foreground half of that sentence posts
    /// nothing the user can see.
    private final class Presenter: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(
            _ center: UNUserNotificationCenter, willPresent notification: UNNotification
        ) async -> UNNotificationPresentationOptions {
            [.banner, .sound]
        }
    }

    private static let presenter = Presenter()

    /// Takes the notification centre. iOS wants the delegate in place
    /// before launch ends, so the app delegate calls this.
    static func start() {
        UNUserNotificationCenter.current().delegate = presenter
    }

    /// Opens the system prompt and records that Empo spent its one
    /// chance at it.
    ///
    /// iOS gives an app one chance, so the sheet of 13.19 decides.
    /// Only "Turn on" reaches this. "Not now" marks nothing and
    /// calls nothing.
    static func spendTheSystemPrompt() async {
        UserDefaults.standard.set(true, forKey: DefaultsKey.backupNotificationPromptSpent)
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    /// The device check of tickets 007 to 012 has no screen to tap,
    /// so it goes straight to the system prompt. The Backups screen
    /// shows the sheet of 13.19 instead.
    static func askForPermissionIfNeeded(configuredTargetCount: Int) async {
        let asked = UserDefaults.standard.bool(forKey: DefaultsKey.backupNotificationsAsked)
        guard
            BackupNotificationRule.asksForPermission(
                configuredTargetCount: configuredTargetCount, hasAsked: asked)
        else { return }
        UserDefaults.standard.set(true, forKey: DefaultsKey.backupNotificationsAsked)
        await spendTheSystemPrompt()
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
        BackupLog.line(
            "BackupNotifier",
            "\(targetLabel) carries \(causes.count) cause, posts \(toPost.count)")
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
