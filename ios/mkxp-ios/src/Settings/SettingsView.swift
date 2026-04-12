import SwiftUI

struct SettingsView: View {
    @Bindable var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var featureToEnable: ExperimentalFeature?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Theme", selection: $settings.theme) {
                        ForEach(AppTheme.allCases, id: \.self) { theme in
                            Text(theme.label).tag(theme)
                        }
                    }
                    Picker("Title position", selection: $settings.titlePosition) {
                        ForEach(TitlePosition.allCases, id: \.self) { position in
                            Text(position.label).tag(position)
                        }
                    }
                } header: {
                    Text("Look & Feel")
                } footer: {
                    Text("Choose where game titles show up on your library cards.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Debug mode", isOn: $settings.debugMode)
                        Text("Shows FPS and engine info while you play.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Clean up broken imports", isOn: $settings.cleanupInvalidGames)
                        Text("Automatically removes games that didn't import properly.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Debug logs", isOn: $settings.debugLogs)
                        Text("Saves engine logs for each session. Find them in Files → mkxp-z → Logs.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)

                    if settings.debugLogs {
                        VStack(alignment: .leading, spacing: 4) {
                            Stepper("Keep last \(settings.maxLogFiles) logs", value: $settings.maxLogFiles, in: 5...100, step: 5)
                            Text("Older logs get cleaned up automatically on launch.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Advanced")
                }

                Section {
                    ForEach(ExperimentalFeature.allCases) { feature in
                        let enabled = settings.isEnabled(feature)
                        Toggle(isOn: Binding(
                            get: { enabled },
                            set: { newValue in
                                if newValue {
                                    featureToEnable = feature
                                } else {
                                    settings.setEnabled(feature, false)
                                }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(feature.label)
                                Text(feature.description)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Experimental")
                } footer: {
                    Text("These features are still in development and may not work as expected.")
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
            .confirmationDialog(
                "Enable \(featureToEnable?.label.lowercased() ?? "")?",
                isPresented: Binding(
                    get: { featureToEnable != nil },
                    set: { if !$0 { featureToEnable = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Enable") {
                    if let feature = featureToEnable {
                        settings.setEnabled(feature, true)
                    }
                    featureToEnable = nil
                }
                Button("Cancel", role: .cancel) {
                    featureToEnable = nil
                }
            } message: {
                Text("This feature is experimental and may not work as expected.")
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
