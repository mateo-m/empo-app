import SwiftUI

struct Chip: View {
    private let label: String?
    private let systemImage: String?

    /// Chip with icon and label.
    init(_ label: String, systemImage: String) {
        self.label = label
        self.systemImage = systemImage
    }

    /// Icon-only chip.
    init(systemImage: String) {
        self.label = nil
        self.systemImage = systemImage
    }

    /// Label-only chip.
    init(_ label: String) {
        self.label = label
        self.systemImage = nil
    }

    var body: some View {
        HStack(spacing: Spacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            if let label {
                Text(label)
            }
        }
        .font(.caption2)
        .foregroundStyle(.primary)
        .padding(.horizontal, label != nil ? Spacing.md : 6)
        .padding(.vertical, 5)
        .glassEffect(.regular.tint(.black.opacity(0.3)), in: .capsule)
    }
}
