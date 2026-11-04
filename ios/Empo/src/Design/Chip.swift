// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

struct Chip: View {
    private let label: LocalizedStringResource?
    private let systemImage: String?
    private let tint: Color

    init(_ label: LocalizedStringResource, systemImage: String, tint: Color = .chipScrim) {
        self.label = label
        self.systemImage = systemImage
        self.tint = tint
    }

    init(systemImage: String, tint: Color = .chipScrim) {
        self.label = nil
        self.systemImage = systemImage
        self.tint = tint
    }

    init(_ label: LocalizedStringResource, tint: Color = .chipScrim) {
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
