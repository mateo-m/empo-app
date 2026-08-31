import GameProbe
import SwiftUI

/// The visible permission check of SPEC 13.7.
///
/// One tick per step: write, list, delete, free space. A failing step
/// is named, with the provider's message word for word. Dismissing
/// leaves the row in its previous state, because a dismissal is not
/// an acknowledgment.
struct PermissionCheckSheet: View {

    let targetLabel: String
    let result: PermissionCheckResult

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        StandardSheet(
            title: result.allowsAdd ? "\(targetLabel) is ready" : "\(targetLabel) refused a step",
            trailingButton: SheetBarAction("Close") { dismiss() }
        ) {
            SheetCard {
                ForEach(Array(result.steps.enumerated()), id: \.offset) { index, step in
                    if index > 0 { SheetRowSeparator() }
                    stepRow(step)
                }
            }
            if let failure = result.failure {
                SheetBodyText(message(of: failure))
            }
            if !result.canQueryQuota {
                SheetFootnote(TargetCapabilities.noSpaceQueryLine)
            }
        }
    }

    private func stepRow(_ step: PermissionCheckStepResult) -> some View {
        HStack(spacing: Spacing.lg) {
            Image(systemName: symbol(of: step.outcome))
                .foregroundStyle(color(of: step.outcome))
            Text(step.label.capitalized)
            Spacer(minLength: 0)
        }
        .padding(.vertical, Spacing.sm)
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
        case .authExpired: return "This target needs you to sign in again."
        case .permissionDenied: return "This target refused the request."
        case .outOfSpace: return "This target has no room left."
        case .offline: return "Empo could not reach this target."
        case .notFound: return "This target holds no folder at that path."
        case .throttled(let seconds):
            return "This target asked Empo to wait \(Int(seconds)) seconds."
        }
    }
}
