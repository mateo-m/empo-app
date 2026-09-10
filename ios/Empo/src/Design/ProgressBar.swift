import SwiftUI

struct ProgressBar: View {
    let fraction: Double?
    var tint: Color = .brand
    var height: CGFloat = 4

    @State private var slid = false

    private static let segment = 0.3

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fill = fraction.map { min(max($0, 0), 1) }
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.2))
                Capsule()
                    .fill(tint)
                    .frame(width: width * (fill ?? Self.segment))
                    .offset(x: fill == nil && slid ? width * (1 - Self.segment) : 0)
            }
            .animation(
                fill == nil ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : nil,
                value: slid)
            .animation(Motion.snappy, value: fill)
        }
        .frame(height: height)
        .onAppear { slid = fraction == nil }
        .onChange(of: fraction == nil) { _, indeterminate in
            if indeterminate { slid = true }
        }
    }
}
