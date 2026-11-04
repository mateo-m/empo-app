import GameProbe
import SwiftUI

/// The visible permission check of SPEC 13.7.
///
/// A pass shows the account the location opens. A failure shows one
/// tick per step and names the failing one, with the provider's
/// message word for word. Dismissing leaves the row in its previous
/// state, because a dismissal is not an acknowledgment.
struct PermissionCheckSheet: View {

    let target: TargetDescriptor
    let result: PermissionCheckResult

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if result.allowsAdd {
            StandardSheet(title: "\(target.displayName) is ready", emblem: "checkmark.circle") {
                SheetCard { accountRow }
                if !result.canQueryQuota {
                    SheetFootnote(TargetCapabilities.noSpaceQueryLine)
                }
            } footer: {
                SheetPrimaryButton("Done") { dismiss() }
            }
        } else {
            StandardSheet(
                title: "\(target.displayName) refused a step",
                barAction: SheetBarAction("Close") { dismiss() }
            ) {
                SheetCard {
                    ForEach(Array(result.steps.enumerated()), id: \.offset) { index, step in
                        if index > 0 { SheetRowSeparator(leadingColumn: 22) }
                        stepRow(step)
                    }
                }
                if let failure = result.failure {
                    SheetBodyText(message(of: failure))
                }
            }
        }
    }

    private var accountRow: some View {
        HStack(spacing: Spacing.lg) {
            AccountAvatar(photo: target.accountPhoto, provider: target.provider)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(target.accountName ?? target.provider.serviceName)
                    .lineLimit(1)
                if let hint = target.accountHint, hint != target.accountName {
                    AccountHintText(hint: hint, provider: target.provider)
                }
                if let space {
                    Text(space)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.lg)
    }

    private var space: String? {
        guard let quota = result.quota, let limit = quota.limitBytes else { return nil }
        let free = BackupText.bytes(max(limit - quota.usedBytes, 0))
        return "\(free) free of \(BackupText.bytes(limit))"
    }

    private func stepRow(_ step: PermissionCheckStepResult) -> some View {
        HStack(spacing: Spacing.lg) {
            Image(systemName: symbol(of: step.outcome))
                .foregroundStyle(color(of: step.outcome))
                .frame(width: 22)
            Text(step.label.prefix(1).uppercased() + step.label.dropFirst())
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.lg)
        .frame(minHeight: 44)
    }

    private func symbol(of outcome: PermissionCheckOutcome) -> String {
        switch outcome {
        case .passed: return "checkmark.circle.fill"
        case .skipped: return "minus.circle"
        case .failed: return "xmark.circle.fill"
        case .notRun: return "circle"
        }
    }

    private func color(of outcome: PermissionCheckOutcome) -> Color {
        switch outcome {
        case .passed: return .green
        case .failed: return .red
        case .skipped, .notRun: return .secondary
        }
    }

    /// A `rejected` message reaches the user word for word, and a
    /// certificate failure already carries the system-trust line of
    /// 8.11.
    private func message(of failure: BackupProviderError) -> String {
        switch failure {
        case .rejected(let message): return message
        case .authExpired: return "This location needs you to sign in again."
        case .permissionDenied: return "This location refused the request."
        case .outOfSpace: return "This location has no room left."
        case .offline: return "Empo could not reach this location."
        case .serverError: return "This location had a server error. Try again later."
        case .notFound: return "This location holds no folder at that path."
        case .throttled(let seconds):
            return "This location asked Empo to wait \(Int(seconds)) seconds."
        }
    }
}
