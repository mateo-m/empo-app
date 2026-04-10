import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Interface") {
                    Picker("Title position", selection: $settings.titlePosition) {
                        ForEach(TitlePosition.allCases, id: \.self) { position in
                            Text(position.label).tag(position)
                        }
                    }
                }

                Section {
                    Toggle("Debug Mode", isOn: $settings.debugMode)
                    Toggle("Clean up invalid games", isOn: $settings.cleanupInvalidGames)
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("When enabled, games that failed to import (e.g. due to a crash) are automatically removed on launch.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
