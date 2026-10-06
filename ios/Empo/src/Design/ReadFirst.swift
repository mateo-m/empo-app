import SwiftUI

/// The wait a screen shows until its data arrives.
///
/// The content takes the value, so no screen branches on "not read
/// yet" inside its own rows.
struct ReadFirst<Value, Content: View>: View {

    let value: Value?
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        if let value {
            content(value)
        } else {
            ProgressView()
        }
    }
}
