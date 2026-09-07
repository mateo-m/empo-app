import GameProbe
import SwiftUI

/// The one sheet that comes before the system prompt, per SPEC 13.19.
///
/// "Not now" calls nothing and marks nothing, so Empo's one chance at
/// the system prompt stays unspent.
struct NotificationAskSheet: View {

    let answer: (BackupNotificationAnswer) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var answered = false

    var body: some View {
        StandardSheet(
            title: BackupNotificationAsk.title,
            emblem: "bell.badge",
            trailingButton: SheetBarAction(BackupNotificationAsk.notNowLabel) { dismiss() }
        ) {
            SheetBodyText(BackupNotificationAsk.body)
            SheetPrimaryButton(BackupNotificationAsk.turnOnLabel) {
                answered = true
                answer(.turnOn)
                dismiss()
            }
        }
        .onDisappear {
            guard !answered else { return }
            answer(.notNow)
        }
    }
}
