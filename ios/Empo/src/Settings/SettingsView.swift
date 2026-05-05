import SwiftUI

struct SettingsView: View {
    @Environment(\.appSettings) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var showBuildInfo = false

    // ExperimentalFeature toggles + ConfirmSheet/InfoSheet were
    // deleted alongside the gamePause/cheats graduation - see the
    // ExperimentalFeature comment block in AppSettings.swift for
    // how to bring opt-in toggles back.

    var body: some View {
        @Bindable var settings = settings
        return NavigationStack {
            Form {
                Section {
                    VStack(spacing: Spacing.md) {
                        // Match splash screen wordmark styling so the
                        // first run and the settings header feel
                        // continuous.
                        Text(AppInfo.name)
                            .font(AppFont.wordmark)
                        // Tap the marketing version to reveal full build
                        // details (commit, dirty flag, non-default branch).
                        Button {
                            showBuildInfo = true
                        } label: {
                            Text("v\(AppInfo.version)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Show build details")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.md)
                    .listRowBackground(Color.clear)
                }

                Section {
                    SettingsPicker(
                        title: "Theme",
                        selection: $settings.theme,
                        description: "Switch between dark, light, or system appearance."
                    ) {
                        ForEach(AppTheme.allCases, id: \.self) { theme in
                            Text(theme.label).tag(theme)
                        }
                    }

                    SettingsPicker(
                        title: "View mode",
                        selection: $settings.libraryDisplayMode,
                        description: "Show games as a grid of cards or a compact list."
                    ) {
                        ForEach(LibraryDisplayMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }

                    SettingsPicker(
                        title: "Title position",
                        selection: $settings.titlePosition,
                        description: "Where game titles show up on your library cards."
                    ) {
                        ForEach(TitlePosition.allCases, id: \.self) { position in
                            Text(position.label).tag(position)
                        }
                    }

                    SettingsToggle(
                        title: "Interface haptics",
                        isOn: $settings.interfaceHaptics,
                        description:
                            "Gentle taps when you press buttons, toggle switches, and navigate around."
                    )

                    SettingsToggle(
                        title: "Controller haptics",
                        isOn: $settings.controllerHaptics,
                        description: "Vibration feedback on the on-screen game controls while you play."
                    )

                    SettingsToggle(
                        title: "Continue playing",
                        isOn: $settings.showContinuePlaying,
                        description:
                            "Show a card at the top of your library to quickly jump back into your last game."
                    )
                } header: {
                    Text("Look & Feel")
                } footer: {
                    Text("Customize the appearance and layout of your library.")
                }

                Section {
                    SettingsToggle(
                        title: "Diagnostics overlay",
                        isOn: $settings.diagnosticsOverlay,
                        description:
                            "Adds a button to the in-game toolbar that toggles a draggable overlay showing the title, Ruby version, renderer, and FPS."
                    )

                    SettingsToggle(
                        title: "Show viewport bounds",
                        isOn: $settings.showViewportBounds,
                        description:
                            "Fills the framebuffer area outside the game viewport with a color of your choosing."
                    )

                    if settings.showViewportBounds {
                        NavigationLink {
                            ViewportBoundsColorPicker(color: $settings.viewportBoundsColor)
                        } label: {
                            HStack {
                                Text("Bounds color")
                                Spacer()
                                RoundedRectangle(cornerRadius: Radius.xs)
                                    .fill(settings.viewportBoundsColor)
                                    .frame(width: 24, height: 24)
                            }
                        }
                    }

                    SettingsToggle(
                        title: "Clean up broken imports",
                        isOn: $settings.cleanupInvalidGames,
                        description: "Removes games that didn't import properly on the next app launch."
                    )

                    SettingsToggle(
                        title: "Debug logs",
                        isOn: $settings.debugLogs,
                        description:
                            "Saves engine logs for each session. Find them in Files → \(AppInfo.name) → Games → <game> → Logs."
                    )

                    if settings.debugLogs {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Stepper(
                                "Keep last \(settings.maxLogFiles) logs per game",
                                value: $settings.maxLogFiles, in: 5...100, step: 5)
                            Text("Older logs get cleaned up automatically when a session starts.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, Spacing.xxs)
                    }
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("These options are intended for debugging and troubleshooting.")
                }

                Section {
                    NavigationLink {
                        LicensesView()
                    } label: {
                        Label("Open-source licenses", systemImage: "doc.text")
                    }

                    Link(
                        destination: URL(string: "https://github.com/mateo-m/empo-app/wiki/privacy-policy")
                            ?? URL.empoHomepage
                    ) {
                        Label {
                            HStack {
                                Text("Privacy Policy")
                                Spacer()
                                Image(systemName: "arrow.up.forward")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "hand.raised")
                        }
                    }
                    .tint(.primary)

                    Link(
                        destination: URL(string: "https://github.com/mateo-m/empo-app/issues")
                            ?? URL.empoHomepage
                    ) {
                        Label {
                            HStack {
                                Text("Report an issue")
                                Spacer()
                                Image(systemName: "arrow.up.forward")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "ladybug")
                        }
                    }
                    .tint(.primary)
                } header: {
                    Text("About")
                }

                Section {
                    // SwiftUI's Text initializer parses markdown in
                    // string literals, so the [Grid] link is rendered
                    // tappable with the .tint(.brand) the form uses.
                    Text("made with ☕ by [Grid](https://twitter.com/gridplay_)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                }

            }
            .sheet(isPresented: $showBuildInfo) {
                BuildInfoSheet()
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(.brand)
    }

}

/// Presented as a sheet when the user taps the version label in the
/// settings header. Shows build details as a grouped list styled to
/// match GameInfoView. The branch row is only included when the
/// current branch differs from the default, so release builds on
/// `main` stay minimal.
///
/// Uses the same navigation-stack-with-inline-title pattern as
/// SettingsView / GameInfoView / GameSettingsView so the toolbar reads
/// as native chrome (centered inline title, trailing Close button).
private struct BuildInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var measuredHeight: CGFloat = 0

    /// A detail row shown in the list. `value` is the copyable string; the
    /// optional `annotation` is rendered next to it but NOT part of the
    /// text-selection range so users can long-press to copy just the
    /// canonical value (e.g. the commit hash without a "(dirty)" suffix).
    private struct Row: Identifiable {
        let label: String
        let value: String
        var annotation: String?
        var id: String { label }
    }

    private var rows: [Row] {
        var r: [Row] = []
        r.append(Row(label: "Version", value: AppInfo.version))
        r.append(Row(label: "Build", value: AppInfo.build))
        r.append(
            Row(
                label: "Commit",
                value: GitInfo.commit,
                annotation: GitInfo.dirty ? "(dirty)" : nil
            ))
        if !GitInfo.branch.isEmpty, GitInfo.branch != GitInfo.defaultBranch {
            r.append(Row(label: "Branch", value: GitInfo.branch))
        }
        return r
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Divider().padding(.leading, Spacing.xl)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                            Text(row.label)
                            Spacer(minLength: Spacing.md)
                            // RootView applies `.fontDesign(.rounded)`
                            // to the entire app tree, which overrides
                            // any `.font(design: .monospaced)` set here via
                            // environment resolution. Override
                            // back to `.monospaced` explicitly so the
                            // value's font reads as fixed-width.
                            Text(row.value)
                                .font(.system(size: 15))
                                .fontDesign(.monospaced)
                                .textSelection(.enabled)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let annotation = row.annotation {
                                Text(annotation)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, Spacing.xl)
                        .padding(.vertical, Spacing.lg)
                    }
                }
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: Radius.xl))
                .padding(.horizontal, Spacing._2xl)
                .padding(.vertical, Spacing._2xl)
            }
            .intrinsicSheetContent(measuredHeight: $measuredHeight)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Build Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                        .tint(.brand)
                }
            }
        }
        .intrinsicSheetDetent(measuredHeight: measuredHeight, chromeAllowance: AppSize.libraryHeader)
    }
}

private struct ViewportBoundsColorPicker: View {
    @Binding var color: Color

    var body: some View {
        Form {
            Section {
                ColorPicker("Color", selection: $color, supportsOpacity: true)
            }

            Section {
                HStack(spacing: Spacing._2xl) {
                    Spacer()
                    DevicePreview(color: color, isLandscape: false)
                    DevicePreview(color: color, isLandscape: true)
                    Spacer()
                }
                .padding(.vertical, Spacing.xl)
                .listRowBackground(Color.clear)
            } header: {
                Text("Preview")
            }
        }
        .navigationTitle("Bounds color")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Miniature device mockup showing the game viewport and bounds color.
private struct DevicePreview: View {
    let color: Color
    let isLandscape: Bool

    // Device proportions (roughly iPhone-like)
    private let portraitW: CGFloat = 70
    private let portraitH: CGFloat = 150
    private let cornerRadius: CGFloat = Radius.md
    private let bezelWidth: CGFloat = 2
    private let notchHeight: CGFloat = 8

    private var deviceW: CGFloat { isLandscape ? portraitH : portraitW }
    private var deviceH: CGFloat { isLandscape ? portraitW : portraitH }

    var body: some View {
        ZStack {
            // Device bezel
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(.secondary.opacity(0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(.secondary.opacity(Alpha.indicatorStroke), lineWidth: 1)
                )

            // Screen area
            let screenInset = bezelWidth + 2
            let screenW = deviceW - screenInset * 2
            let screenH = deviceH - screenInset * 2

            RoundedRectangle(cornerRadius: cornerRadius - 3)
                .fill(color)
                .padding(screenInset)

            // Game viewport
            let gameRect = gameViewportRect(screenW: screenW, screenH: screenH)
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.black)
                .frame(width: gameRect.width, height: gameRect.height)
                .offset(x: gameRect.offsetX, y: gameRect.offsetY)

            // Notch indicator
            notchView
        }
        .frame(width: deviceW, height: deviceH)
    }

    private var notchView: some View {
        Group {
            if isLandscape {
                // Notch on the left
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 4,
                    topTrailingRadius: 4
                )
                .fill(.secondary.opacity(Alpha.indicatorFill))
                .frame(width: notchHeight, height: 20)
                .offset(x: -(deviceW / 2 - notchHeight / 2))
            } else {
                // Notch on top
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 4,
                    bottomTrailingRadius: 4,
                    topTrailingRadius: 0
                )
                .fill(.secondary.opacity(Alpha.indicatorFill))
                .frame(width: 28, height: notchHeight)
                .offset(y: -(deviceH / 2 - notchHeight / 2))
            }
        }
    }

    private struct GameRect {
        let width: CGFloat
        let height: CGFloat
        let offsetX: CGFloat
        let offsetY: CGFloat
    }

    private func gameViewportRect(screenW: CGFloat, screenH: CGFloat) -> GameRect {
        // Simulate a 4:3 game aspect ratio
        let gameAspect: CGFloat = 4.0 / 3.0
        let safeTopInset: CGFloat = notchHeight + 2

        if isLandscape {
            // Landscape: game centered, safe insets on left
            let safeLeftInset: CGFloat = notchHeight + 2
            let availW = screenW - safeLeftInset
            let availH = screenH
            var gameW = availW
            var gameH = gameW / gameAspect
            if gameH > availH {
                gameH = availH
                gameW = gameH * gameAspect
            }
            let offsetX = (safeLeftInset - 0) / 2
            return GameRect(width: gameW, height: gameH, offsetX: offsetX, offsetY: 0)
        } else {
            // Portrait: game top-center aligned within safe area
            let availW = screenW
            let availH = screenH - safeTopInset
            var gameW = availW
            var gameH = gameW / gameAspect
            if gameH > availH * 0.6 {
                gameH = availH * 0.6
                gameW = gameH * gameAspect
            }
            // Top-center: between top and center
            let topY = -(screenH / 2 - safeTopInset - gameH / 2 - 2)
            let centerY: CGFloat = 0
            let offsetY = (topY + centerY) / 2
            return GameRect(width: gameW, height: gameH, offsetX: 0, offsetY: offsetY)
        }
    }
}

extension URL {
    /// Fallback for any URL literal that fails to parse. Empty string
    /// URL initialization is the only way to guarantee a non-nil URL
    /// at compile time without a force-unwrap, so the project homepage
    /// serves as a safe landing page.
    fileprivate static let empoHomepage =
        URL(string: "https://github.com/mateo-m/empo-app") ?? URL(fileURLWithPath: "/")
}
