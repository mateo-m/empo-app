// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

struct SettingsToggle: View {
    let title: LocalizedStringResource
    @Binding var isOn: Bool
    let description: LocalizedStringResource

    var body: some View {
        #if os(macOS)
        Toggle(isOn: $isOn) {
            Text(title)
            Text(description)
        }
        .toggleStyle(.checkbox)
        #else
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Toggle(title, isOn: $isOn)
            SettingsDescription(Text(description))
        }
        .padding(.vertical, Spacing.xxs)
        #endif
    }
}

struct SettingsNavigationRow<Destination: View>: View {
    let title: Text
    let description: LocalizedStringResource
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                title
                SettingsDescription(Text(description))
            }
            .padding(.vertical, Spacing.xxs)
        }
    }
}

struct SettingsPicker<SelectionValue: Hashable, Content: View>: View {
    let title: LocalizedStringResource
    @Binding var selection: SelectionValue
    let description: Text
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Picker(selection: $selection) {
                content()
            } label: {
                Text(title)
            }
            SettingsDescription(description)
        }
        .padding(.vertical, Spacing.xxs)
    }
}

struct SettingsDescription: View {
    let text: Text

    init(_ text: Text) {
        self.text = text
    }

    var body: some View {
        BalancedWrap {
            text
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// Wraps text into lines of near-equal length, like CSS `text-wrap: balance`.
/// SwiftUI and TextKit have no such option. The layout picks the narrowest
/// width that keeps the line count of the full width.
struct BalancedWrap: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let text = subviews.first else { return .zero }
        guard let width = proposal.width, width.isFinite else { return text.sizeThatFits(proposal) }
        return text.sizeThatFits(ProposedViewSize(width: balancedWidth(of: text, in: width), height: nil))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        guard let text = subviews.first else { return }
        let width = balancedWidth(of: text, in: bounds.width)
        text.place(at: bounds.origin, proposal: ProposedViewSize(width: width, height: bounds.height))
    }

    private func balancedWidth(of text: LayoutSubview, in width: CGFloat) -> CGFloat {
        func height(at width: CGFloat) -> CGFloat {
            text.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }
        let target = height(at: width)
        var narrow: CGFloat = 0
        var wide = width
        while wide - narrow > 1 {
            let middle = (narrow + wide) / 2
            if height(at: middle) > target { narrow = middle } else { wide = middle }
        }
        return wide
    }
}
