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


/// Small flask glyph that marks a setting row as experimental. Matches
/// the icon used in `ExperimentalConfirmSheet` so users can associate
/// the warning chip on the confirmation sheet with this inline marker.
/// Tapping it opens an info sheet that explains what "experimental"
/// means in this app - useful for new users who haven't seen the
/// confirmation flow yet.
private struct ExperimentalBadge: View {
    @State private var showInfo = false

    var body: some View {
        Button {
            showInfo = true
        } label: {
            Image(systemName: "flask.fill")
                .font(.footnote)
                .foregroundStyle(.brand)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Learn about experimental features")
        .sheet(isPresented: $showInfo) {
            ExperimentalInfoSheet()
        }
    }
}
