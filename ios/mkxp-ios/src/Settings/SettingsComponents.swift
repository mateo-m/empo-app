import SwiftUI

/// A toggle with an inline description, used across Settings and Game Settings.
struct SettingsToggle: View {
    let title: String
    @Binding var isOn: Bool
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: $isOn)
            Text(description)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// A picker with an inline description, used across Settings and Game Settings.
struct SettingsPicker<SelectionValue: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: SelectionValue
    let description: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(title, selection: $selection) {
                content()
            }
            Text(description)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
