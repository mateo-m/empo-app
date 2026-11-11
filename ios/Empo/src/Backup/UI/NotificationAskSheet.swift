import GameProbe
import SwiftUI

/// "Not now" leaves the system prompt unspent, because iOS gives an
/// app one chance at it.
struct NotificationAskSheet: View {

    let answer: (BackupNotificationAnswer) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var answered = false

    var body: some View {
        StandardSheet(
            title: BackupNotificationAsk.title,
            emblem: "bell.badge",
            barAction: SheetBarAction(BackupNotificationAsk.notNowLabel) { dismiss() }
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
