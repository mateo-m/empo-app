import GameProbe
import SwiftUI

/// The one sheet that comes before the system prompt, per SPEC 13.19.
///
/// "Not now" calls nothing and marks nothing, so Empo's one chance at
/// the system prompt stays unspent.
struct NotificationAskSheet: View {

    let answer: (BackupNotificationAnswer) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        StandardSheet(title: BackupNotificationAsk.title, emblem: "bell.badge") {
            SheetBodyText(BackupNotificationAsk.body)
            VStack(spacing: Spacing.md) {
                SheetPrimaryButton(BackupNotificationAsk.turnOnLabel) {
                    answer(.turnOn)
                    dismiss()
                }
                Button(BackupNotificationAsk.notNowLabel) {
                    answer(.notNow)
                    dismiss()
                }
                .buttonStyle(SecondaryButtonStyle(size: .md))
            }
        }
        .interactiveDismissDisabled()
    }
}
