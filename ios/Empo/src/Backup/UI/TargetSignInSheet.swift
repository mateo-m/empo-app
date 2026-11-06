import GameProbe
import SwiftUI

/// The sign-in of a typed target, per SPEC 8.8 and 13.5: the add form
/// again, with what this device knows filled in and the secret empty.
struct TargetSignInSheet: View {

    let target: TargetDescriptor
    let signedIn: (TargetDescriptor, PermissionCheckResult) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TargetFormScreen(
                service: target.provider, values: known, lockedFields: Set(locked.keys),
                submitTitle: "Sign in"
            ) { typed in
                let values = typed.merging(locked) { _, kept in kept }
                return target.provider == .s3
                    ? await BackupTargetAdd.s3(form: values, existing: target)
                    : await BackupTargetAdd.webdav(form: values, existing: target)
            } done: { descriptor, result in
                signedIn(descriptor, result)
                dismiss()
            }
            .navigationTitle("Sign in to \(target.displayName)")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var known: [String: String] { BackupTargetAdd.signInForm(of: target) }

    /// A field this device has no value for stays open, so the user
    /// can type it.
    private var locked: [String: String] {
        known.filter { BackupTargetAdd.locationFields.contains($0.key) }
    }
}
