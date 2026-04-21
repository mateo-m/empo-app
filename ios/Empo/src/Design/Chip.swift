import SwiftUI

struct Chip: View {
    private let label: String?
    private let systemImage: String?
    private let tint: Color

    init(_ label: String, systemImage: String, tint: Color = .chipScrim) {
        self.label = label
        self.systemImage = systemImage
        self.tint = tint
    }

    init(systemImage: String, tint: Color = .chipScrim) {
        self.label = nil
        self.systemImage = systemImage
        self.tint = tint
    }

    init(_ label: String, tint: Color = .chipScrim) {
        self.label = label
        self.systemImage = nil
        self.tint = tint
    }

    private var isIconOnly: Bool { label == nil && systemImage != nil }

    var body: some View {
        let content = HStack(spacing: Spacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            if let label {
                Text(label)
            }
        }
        .font(.caption2)
        .foregroundStyle(.white)

        if isIconOnly {
            content
                .padding(Spacing.sm)
                .glassEffect(.regular.tint(tint), in: .circle)
        } else {
            content
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs)
                .glassEffect(.regular.tint(tint), in: .capsule)
        }
    }
}
