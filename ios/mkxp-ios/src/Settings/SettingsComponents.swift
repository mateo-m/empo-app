import SwiftUI

struct SettingsToggle: View {
    let title: String
    @Binding var isOn: Bool
    let description: String
    var isExperimental: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Toggle(isOn: $isOn) {
                HStack(spacing: Spacing.xs) {
                    Text(title)
                    if isExperimental {
                        ExperimentalBadge()
                    }
                }
            }
            Text(description)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, Spacing.xxs)
    }
}

struct SettingsPicker<SelectionValue: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: SelectionValue
    let description: String
    var isExperimental: Bool = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Picker(selection: $selection) {
                content()
            } label: {
                HStack(spacing: Spacing.xs) {
                    Text(title)
                    if isExperimental {
                        ExperimentalBadge()
                    }
                }
            }
            Text(description)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, Spacing.xxs)
    }
}


private struct ExperimentalBadge: View {
    var body: some View {
        Text("BETA")
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .foregroundStyle(.orange)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.orange.opacity(0.15), in: Capsule())
    }
}
