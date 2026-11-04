import GameProbe
import SwiftUI

/// The sign-in of a typed target, per SPEC 8.8 and 13.5: the add form
/// again, with what this device knows filled in and the secret empty.
struct TargetSignInSheet: View {

    let target: TargetDescriptor
    let signedIn: (TargetDescriptor, PermissionCheckResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isWorking = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            TargetFormScreen(
                service: target.provider, values: known, lockedFields: Set(locked.keys),
                submitTitle: "Sign in", failure: failure
            ) { values in
                Task { await submit(values) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if isWorking { ProgressView() }
            }
        }
    }

    private var known: [String: String] { BackupTargetAdd.signInForm(of: target) }

    /// A field this device has no value for stays open, so the user
    /// can type it.
    private var locked: [String: String] {
        known.filter { BackupTargetAdd.locationFields.contains($0.key) }
    }

    private func submit(_ typed: [String: String]) async {
        let values = typed.merging(locked) { _, kept in kept }
        isWorking = true
        defer { isWorking = false }
        if AppSettings.shared.debugLogs {
            BackupLog.line("TargetSignInSheet", "\(target.id) signs in through the form")
        }
        let outcome =
            target.provider == .s3
            ? await BackupTargetAdd.s3(form: values, existing: target)
            : await BackupTargetAdd.webdav(form: values, existing: target)
        switch outcome {
        case .checked(let descriptor, let result):
            signedIn(descriptor, result)
            dismiss()
        case .cancelled:
            failure = nil
        case .failed(let line):
            failure = line
        }
    }
}
