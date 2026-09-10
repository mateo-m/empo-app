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
                service: target.provider, values: BackupTargetAdd.signInForm(of: target),
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

    private func submit(_ values: [String: String]) async {
        isWorking = true
        defer { isWorking = false }
        if AppSettings.shared.debugLogs { BackupLog.line("TargetSignInSheet", "\(target.id) signs in through the form") }
        let outcome =
            target.provider == .s3
            ? await BackupTargetAdd.s3(form: values, id: target.id)
            : await BackupTargetAdd.webdav(form: values, id: target.id)
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
