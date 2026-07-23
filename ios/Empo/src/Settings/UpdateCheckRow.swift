import SwiftUI

// This stays as a light compatibility wrapper. It keeps the Xcode
// project file unchanged after the update status moved into the
// Settings header.
struct UpdateCheckRow: View {
    let status: UpdateChecker.Status
    let onTapRetry: () -> Void

    var body: some View {
        EmptyView()
    }
}
