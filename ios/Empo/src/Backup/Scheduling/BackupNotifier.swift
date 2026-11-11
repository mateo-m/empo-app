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

    /// iOS asks this only while Empo is on screen. The pill of 13.2
    /// says what stopped when it shows, so the notice stays silent
    /// then. A run that stops before it plans an upload shows no
    /// pill, so the notice shows instead.
    private final class Presenter: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(
            _ center: UNUserNotificationCenter, willPresent notification: UNNotification
        ) async -> UNNotificationPresentationOptions {
            await MainActor.run { BackupRunMonitor.shared.showsPill } ? [] : [.banner, .sound]
        }
    }

    private static let presenter = Presenter()

    /// Takes the notification centre. iOS wants the delegate in place
    /// before launch ends, so the app delegate calls this.
    static func start() {
        UNUserNotificationCenter.current().delegate = presenter
    }

    /// Opens the system prompt.
    ///
    /// iOS gives an app one chance, so the sheet of 13.19 decides.
    /// Only "Turn on" reaches this. "Not now" calls nothing.
    static func spendTheSystemPrompt() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    /// Posts what one pass found on every target it touched, and
    /// keeps the ledger so nothing posts twice.
    ///
    /// The ledger lives in `state.sqlite`. A rebuilt cache re-arms
    /// every cause, which costs the user one repeated notification
    /// and never a missed one.
    static func report(_ targets: [BackupPassTarget], store: BackupStateStore) {
        var ledger: BackupNotificationLedger
        do {
            ledger = try store.notificationLedger()
        } catch {
            BackupLog.line("BackupNotifier", "The ledger was not read, every cause posts: \(error)")
            ledger = BackupNotificationLedger()
        }
        let toPost = ledger.post(pass: targets.map { ($0.id, $0.causes) })
        do {
            try store.saveNotificationLedger(ledger)
        } catch {
            BackupLog.line("BackupNotifier", "The ledger was not saved: \(error)")
        }
        for (target, posts) in zip(targets, toPost) {
            BackupLog.line(
                "BackupNotifier",
                "\(target.label) carries \(target.causes.count) cause, posts \(posts.causes.count)")
            for cause in posts.causes {
                post(cause, targetId: target.id, targetLabel: target.label)
            }
        }
    }

    private static func post(_ cause: BackupFailFastCause, targetId: String, targetLabel: String) {
        let content = UNMutableNotificationContent()
        content.body = BackupNotificationRule.text(
            for: cause,
            targetLabel: targetLabel,
            deviceName: BackupDeviceConditions.deviceName)
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "\(cause.rawValue).\(targetId)",
            content: content,
            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
