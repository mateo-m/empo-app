import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Title position", selection: $settings.titlePosition) {
                        ForEach(TitlePosition.allCases, id: \.self) { position in
                            Text(position.label).tag(position)
                        }
                    }
                } header: {
                    Text("Interface")
                } footer: {
                    Text("Controls how game titles are displayed on library cards.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Debug mode", isOn: $settings.debugMode)
                        Text("Shows FPS counter and engine info during gameplay.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Clean up invalid games", isOn: $settings.cleanupInvalidGames)
                        Text("Automatically removes games that failed to import on next launch.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Enable debug logs", isOn: $settings.debugLogs)
                        Text("Records engine and script diagnostics for each game session. Log files are saved to Documents/Logs and accessible via the Files app.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("These options are useful for troubleshooting game compatibility issues.")
                }

                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("\(GitInfo.commit)\(GitInfo.dirty ? " (dirty)" : "")")
                            .foregroundStyle(.secondary)
                    }
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
