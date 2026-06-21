import SwiftUI

struct SettingsView: View {
    @Environment(\.appState) private var appState
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
                settingsHeader

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
                        destination: URL(string: "https://github.com/mateo-m/empo-app")
                            ?? URL.empoHomepage
                    ) {
                        Label {
                            HStack {
                                Text("GitHub")
                                Spacer()
                                Image(systemName: "arrow.up.forward")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(.gitHubMark)
                                .resizable()
                                .scaledToFit()
                        }
                    }
                    .tint(.primary)

                    Link(
                        destination: URL(string: "https://twitter.com/gridplay_")
                            ?? URL.empoHomepage
                    ) {
                        Label {
                            HStack {
                                Text("Twitter")
                                Spacer()
                                Image(systemName: "arrow.up.forward")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(.twitterMark)
                                .resizable()
                                .scaledToFit()
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
                    Text("Made with ☕ by [**Grid**](https://twitter.com/gridplay_)")
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

    private var buildVersionButton: some View {
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

    private var settingsHeader: some View {
        VStack(spacing: Spacing.md) {
            Image(.empoMark)
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .foregroundStyle(.brand)
            // Match splash screen wordmark styling so the
            // first run and the settings header feel
            // continuous, scaled down to fit the sheet.
            Text(AppInfo.name)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)

            VStack(spacing: Spacing.xs) {
                buildVersionButton
                UpdateStatusIndicator(
                    status: appState.updateStatus,
                    onTapRetry: {
                        await appState.checkForUpdatesNow()
                    },
                    size: .compact,
                    showsManualRefresh: UpdateChecker.isSideloadOrDevBuild,
                    onManualRefresh: {
                        await appState.checkForUpdatesNow()
                    }
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing._3xl)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .environment(\.headerProminence, .standard)
    }
}

private enum UpdateStatusChipPhase: Hashable {
    case hidden
    case checking
    case upToDate
    case available(version: String)
    case failed

    init(_ status: UpdateChecker.Status) {
        switch status {
        case .unknown:
            self = .hidden
        case .checking:
            self = .checking
        case .upToDate:
            self = .upToDate
        case .available(let version, _):
            self = .available(version: version)
        case .failed:
            self = .failed
        }
    }

    var title: String {
        switch self {
        case .hidden:
            return ""
        case .checking:
            return "Checking for updates..."
        case .upToDate:
            return "Up to date"
        case .available(let version):
            return "Update available: v\(version)"
        case .failed:
            return "Retry update check"
        }
    }

    var systemImage: String? {
        switch self {
        case .checking, .hidden:
            return nil
        case .upToDate:
            return "checkmark.circle"
        case .available:
            return "arrow.down.circle.fill"
        case .failed:
            return "exclamationmark.triangle"
        }
    }

    var usesBrandGlass: Bool {
        if case .available = self { return true }
        return false
    }
}

/// Compact refresh affordance with a spring-driven spin while active.
/// When the check completes, the icon springs forward until it has
/// completed at least one full turn from when the spin started, then
/// resets to 0° invisibly (360° and 0° look identical).
private struct RefreshSpinIcon: View {
    let spinning: Bool
    var size: UpdateStatusIndicator.Size = .regular

    private let spinPeriod: TimeInterval = 0.85

    @State private var spinStart: Date?
    @State private var spinOrigin: Double = 0
    @State private var coastRotation: Double?
    @State private var coastGeneration: UInt = 0

    private var iconFont: Font {
        switch size {
        case .compact, .regular: .system(size: 11, weight: .semibold)
        }
    }

    private var isCoasting: Bool {
        coastRotation != nil
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !spinning && !isCoasting)) { context in
            Image(systemName: "arrow.clockwise")
                .font(iconFont)
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(displayedRotation(at: context.date)))
                .animation(isCoasting ? Motion.standard : nil, value: coastRotation)
        }
        .onChange(of: spinning, initial: true) { _, shouldSpin in
            if shouldSpin {
                startSpinning()
            } else {
                beginCoast()
            }
        }
    }

    private func startSpinning() {
        coastGeneration += 1
        coastRotation = nil
        spinOrigin = 0
        spinStart = Date()
    }

    private func displayedRotation(at date: Date) -> Double {
        if let coastRotation {
            return coastRotation
        }
        return spinRotation(at: date)
    }

    private func spinRotation(at date: Date) -> Double {
        guard let spinStart else { return spinOrigin }
        let elapsed = date.timeIntervalSince(spinStart)
        let revolution = elapsed / spinPeriod
        let completed = floor(revolution)
        let localProgress = revolution - completed
        let sprungProgress = springRevolutionProgress(localProgress)
        return spinOrigin + (completed + sprungProgress) * 360
    }

    /// One 0→1 spring segment per revolution while checking.
    private func springRevolutionProgress(_ progress: Double) -> Double {
        let t = min(max(progress, 0), 1)
        // Critically damped spring approximation (no overshoot).
        return 1 - (1 + 6 * t) * exp(-6 * t)
    }

    private func beginCoast() {
        coastGeneration += 1
        let generation = coastGeneration

        let current: Double
        if let spinStart {
            current = spinRotation(at: Date())
            self.spinStart = nil
        } else if let coastRotation {
            current = coastRotation
        } else {
            resetRotationSilently()
            return
        }

        let minimumTarget = spinOrigin + 360
        let remainder = current.truncatingRemainder(dividingBy: 360)
        let boundaryTarget = remainder > 1 ? current + (360 - remainder) : current
        let target = max(boundaryTarget, minimumTarget)

        guard target - current > 1 else {
            resetRotationSilently()
            return
        }

        coastRotation = current
        withAnimation(Motion.standard) {
            coastRotation = target
        } completion: {
            finishCoast(expectedGeneration: generation)
        }
    }

    private func resetRotationSilently() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            spinOrigin = 0
            spinStart = nil
            coastRotation = nil
        }
    }

    private func finishCoast(expectedGeneration: UInt) {
        guard coastGeneration == expectedGeneration, coastRotation != nil else { return }
        resetRotationSilently()
    }
}

struct UpdateStatusIndicator: View {
    enum Size {
        case compact
        case regular
    }

    let status: UpdateChecker.Status
    let onTapRetry: () async -> Void
    var canDismiss: Bool = false
    var onDismiss: (() -> Void)?
    var size: Size = .regular
    var showsManualRefresh: Bool = false
    var onManualRefresh: (() async -> Void)?

    private var chipPhase: UpdateStatusChipPhase {
        UpdateStatusChipPhase(status)
    }

    private var showsRefreshIcon: Bool {
        showsManualRefresh && (chipPhase == .upToDate || chipPhase == .checking)
    }

    var body: some View {
        if chipPhase == .hidden {
            EmptyView()
        } else {
            HStack(spacing: Spacing.xs) {
                chip
                trailingRefreshControl
            }
            .geometryGroup()
            .animation(Motion.standard, value: chipPhase)
        }
    }

    @ViewBuilder
    private var chip: some View {
        let badge = UpdateStatusBadge(
            text: chipPhase.title,
            systemImage: chipPhase.systemImage,
            tint: chipPhase.usesBrandGlass ? .white : .secondary,
            background: chipPhase.usesBrandGlass ? .brand : Color.secondary.opacity(0.12),
            actionURL: releaseURL,
            dismissAction: canDismiss ? onDismiss : nil,
            usesBrandGlass: chipPhase.usesBrandGlass,
            size: size
        )

        if chipPhase == .failed {
            Button {
                Task { await onTapRetry() }
            } label: {
                badge
            }
            .buttonStyle(.plain)
        } else {
            badge
        }
    }

    private var releaseURL: URL? {
        guard case .available(_, let url) = status else { return nil }
        return url
    }

    @ViewBuilder
    private var trailingRefreshControl: some View {
        if showsRefreshIcon {
            Button {
                Task { await onManualRefresh?() }
            } label: {
                RefreshSpinIcon(spinning: chipPhase == .checking, size: size)
            }
            .buttonStyle(.plain)
            .disabled(chipPhase == .checking)
            .accessibilityLabel(
                chipPhase == .checking ? "Checking for updates" : "Check for updates"
            )
            .transition(.identity)
        }
    }
}

private struct BrandGlassModifier: ViewModifier {
    let interactive: Bool
    let tint: Color

    func body(content: Content) -> some View {
        if interactive {
            content
                .glassEffect(.regular.tint(tint).interactive(), in: .capsule)
                .darkGlass()
        } else {
            content
                .glassEffect(.regular.tint(tint), in: .capsule)
                .darkGlass()
        }
    }
}

struct UpdateStatusBadge: View {
    let text: String
    let systemImage: String?
    let tint: Color
    let background: Color
    var actionURL: URL?
    var dismissAction: (() -> Void)?
    var usesBrandGlass: Bool = false
    var size: UpdateStatusIndicator.Size = .regular

    @Environment(\.openURL) private var openURL
    @State private var dismissDragOffset: CGFloat = 0
    @State private var suppressTapOpen = false

    private static let dismissSwipeThreshold: CGFloat = 24

    /// Library banner: tap opens the release page, swipe down or X
    /// dismisses. Settings header keeps a plain `Link` instead.
    private var usesDismissiblePromoInteraction: Bool {
        actionURL != nil && dismissAction != nil
    }

    var body: some View {
        dismissibleInteraction(styledBadge)
            .offset(y: usesDismissiblePromoInteraction ? dismissDragOffset : 0)
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var styledBadge: some View {
        if usesBrandGlass {
            badgeContent
                .font(brandFont)
                .foregroundStyle(tint)
                .shadow(color: .black.opacity(Alpha.shadow), radius: 2, y: 1)
                .padding(.horizontal, brandHorizontalPadding)
                .padding(.vertical, brandVerticalPadding)
                .modifier(BrandGlassModifier(interactive: !usesDismissiblePromoInteraction, tint: background))
        } else {
            badgeContent
                .font(secondaryFont)
                .foregroundStyle(tint)
                .padding(.horizontal, secondaryHorizontalPadding)
                .padding(.vertical, secondaryVerticalPadding)
                .background(background)
                .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private func dismissibleInteraction<Content: View>(_ content: Content) -> some View {
        if usesDismissiblePromoInteraction, let actionURL, let dismissAction {
            content
                .contentShape(.capsule)
                .gesture(promoDragGesture(url: actionURL, dismiss: dismissAction))
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Swipe down to dismiss")
        } else {
            content
        }
    }

    @ViewBuilder
    private var badgeContent: some View {
        if usesDismissiblePromoInteraction, let actionURL, let dismissAction {
            dismissiblePromoContent(url: actionURL, dismiss: dismissAction)
        } else {
            staticBadgeContent
        }
    }

    private var staticBadgeContent: some View {
        HStack(spacing: 0) {
            if let actionURL {
                Link(destination: actionURL) {
                    label
                }
                .buttonStyle(.plain)
            } else {
                label
            }

            if let dismissAction {
                dismissButton(action: dismissAction)
            }
        }
    }

    private func dismissiblePromoContent(url: URL, dismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 0) {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
            dismissButton { dismissPromo(dismiss) }
        }
    }

    private func promoDragGesture(url: URL, dismiss: @escaping () -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let vertical = value.translation.height
                let horizontal = abs(value.translation.width)
                if vertical > 0, vertical > horizontal {
                    dismissDragOffset = vertical
                }
            }
            .onEnded { value in
                let vertical = value.translation.height
                let horizontal = abs(value.translation.width)
                let isTap = vertical * vertical + horizontal * horizontal < 144

                if vertical > 0, vertical > horizontal {
                    let distanceDismiss = vertical > Self.dismissSwipeThreshold
                    let flickDismiss = vertical > 8 && value.velocity.height > 400
                    if distanceDismiss || flickDismiss {
                        dismissPromo(dismiss, fromSwipe: true)
                        return
                    }
                }

                withAnimation(Motion.gentle) { dismissDragOffset = 0 }
                guard isTap else { return }
                guard !suppressTapOpen else {
                    suppressTapOpen = false
                    return
                }
                openURL(url)
            }
    }

    private func dismissPromo(_ dismiss: @escaping () -> Void, fromSwipe: Bool = false) {
        if !fromSwipe {
            dismissDragOffset = 0
        }
        dismiss()
    }

    private func dismissButton(action: @escaping () -> Void) -> some View {
        Button {
            suppressTapOpen = true
            action()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(dismissFont)
                .foregroundStyle(tint)
                .frame(width: dismissFrame, height: dismissFrame)
                .contentShape(Rectangle())
        }
        .padding(.leading, dismissLeadingPadding)
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss update banner")
    }

    private var label: some View {
        HStack(spacing: Spacing.sm) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(iconScale)
                    .id(systemImage)
                    .transition(.blurReplace)
            }

            Text(text)
                .lineLimit(1)
                .contentTransition(.numericText())
                .transition(.blurReplace)
        }
    }

    private var brandFont: Font {
        switch size {
        case .compact: .caption2.weight(.semibold)
        case .regular: .subheadline.weight(.semibold)
        }
    }

    private var secondaryFont: Font {
        switch size {
        case .compact: .caption.weight(.semibold)
        case .regular: .caption.weight(.semibold)
        }
    }

    private var brandHorizontalPadding: CGFloat {
        switch size {
        case .compact: Spacing.sm
        case .regular: ButtonSize.md.horizontalPadding
        }
    }

    private var brandVerticalPadding: CGFloat {
        switch size {
        case .compact: Spacing.xs
        case .regular: Spacing.md
        }
    }

    private var secondaryHorizontalPadding: CGFloat {
        switch size {
        case .compact: Spacing.sm
        case .regular: Spacing.md
        }
    }

    private var secondaryVerticalPadding: CGFloat {
        switch size {
        case .compact: Spacing.xxs
        case .regular: Spacing.xs
        }
    }

    private var dismissFont: Font {
        switch size {
        case .compact: .caption2.weight(.black)
        case .regular: .subheadline.weight(.black)
        }
    }

    private var dismissFrame: CGFloat {
        switch size {
        case .compact: 14
        case .regular: 18
        }
    }

    private var dismissLeadingPadding: CGFloat {
        switch size {
        case .compact: Spacing.xs
        case .regular: Spacing.md
        }
    }

    private var iconScale: Image.Scale {
        switch size {
        case .compact: .small
        case .regular: .medium
        }
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
