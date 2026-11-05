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
            Text(description)
                .font(.footnote)
                .foregroundStyle(.secondary)
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
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, Spacing.xxs)
        }
    }
}

struct SettingsPicker<SelectionValue: Hashable, Content: View>: View {
    let title: LocalizedStringResource
    @Binding var selection: SelectionValue
    let description: LocalizedStringResource
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Picker(selection: $selection) {
                content()
            } label: {
                Text(title)
            }
            Text(description)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, Spacing.xxs)
    }
}
