import GameProbe
import SwiftUI

/// The Backups screen of SPEC 13.4.
///
/// The order is fixed: the status line, the adopt banner, the run
/// block, "Back up now", the target list, Manual transfer, the
/// app-wide settings, and Backup history.
struct BackupsScreen: View {

    @State private var model = BackupsScreenModel()
    @State private var showsAddSheet = false
    @State private var addedTarget: PermissionCheckOutcomeSheet?
    /// The fresh-install flow of 11.4. It waits for the permission
    /// sheet of the added target to close, because one view shows one
    /// sheet at a time.
    @State private var pendingFreshInstall: FreshInstallItem?
    @State private var freshInstall: FreshInstallItem?
    /// The games the ask of 3.5 still waits on, per the press below.
    @State private var waiting: [BackupModeAsk] = []
    @AppStorage(DefaultsKey.backupOverCellular) private var overCellular = false
    @State private var retention = BackupSettings.retention
    @State private var exports = false
    @State private var showsTheZipPicker = false
    @State private var picked: PickedPackage?
    /// The package a launch found waiting for its save, per 12.5.
    @State private var unsavedPackage: PackageRecord?
    @State private var savesAgain: PackageRecord?
    /// The join ask of 10.4, once the user presses the row.
    @State private var joinAsk: SyncJoinPrompt?
    @State private var looksForAGroup = false

    var body: some View {
        List {
            ReadFirst(value: model.items) { items in
                if items.isEmpty {
                    emptyState
                } else {
                    statusSection
                    adoptBanners
                    runBlock
                    backUpNowSection
                    targetList(items)
                    manualTransfer
                    settingsSection
                }
            }
            historySection
        }
        .navigationTitle("Backups")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.items?.isEmpty == false {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") { showsAddSheet = true }
                }
            }
        }
        .task { await model.refresh() }
        .task { readTheUnsavedPackage() }
        .refreshable { await model.refresh() }
        .sheet(isPresented: $exports) {
            PackageExportSheet(source: .library)
        }
        .sheet(isPresented: $showsTheZipPicker) {
            PackageZipPicker { url in
                showsTheZipPicker = false
                picked = PickedPackage(url: url)
            }
        }
        .sheet(item: $picked) { file in
            PackageImportSheet(picked: file.url)
        }
        .sheet(
            item: $savesAgain, onDismiss: readTheUnsavedPackage,
            content: { record in
                PackageExportSheet(source: .library, model: PackageExportModel(waiting: record))
            }
        )
        .sheet(isPresented: $showsAddSheet) {
            AddTargetSheet(iCloudReach: model.iCloudReach) { descriptor, result in
                addedTarget = PermissionCheckOutcomeSheet(
                    targetLabel: descriptor.displayName, result: result)
                Task {
                    await model.refresh()
                    model.askAboutNotificationsIfNeeded()
                    if let scan = await model.freshInstall(after: descriptor) {
                        pendingFreshInstall = FreshInstallItem(descriptor: descriptor, scan: scan)
                    } else {
                        await model.readTheAdoptBanners(of: descriptor.id)
                    }
                }
            }
        }
        .sheet(
            item: $addedTarget,
            onDismiss: {
                freshInstall = pendingFreshInstall
                pendingFreshInstall = nil
            },
            content: { outcome in
                PermissionCheckSheet(targetLabel: outcome.targetLabel, result: outcome.result)
            }
        )
        .sheet(item: $freshInstall) { item in
            FreshInstallSheet(
                model: FreshInstallModel(descriptor: item.descriptor, scan: item.scan))
        }
        .sheet(item: firstAsk) { ask in
            FirstBackupAskSheet(
                model: BackupSheetModel(container: ask.container, gameName: ask.gameName),
                ask: ask.ask)
        }
        .sheet(item: $joinAsk) { prompt in
            SyncJoinSheet(ask: prompt.ask) { group in SyncJoin.join(group) }
        }
        .sheet(isPresented: $model.showsTheNotificationSheet) {
            NotificationAskSheet { answer in
                Task { await model.answerTheNotificationSheet(answer) }
            }
        }
    }

    /// The package a failed or cancelled save left behind, per 12.5.
    private func readTheUnsavedPackage() {
        unsavedPackage = PackageRecord.waitingForASave(localRoot: BackupRoot.layout.root)
    }

    /// The queue of asks. Each answer, and each dismissal, moves to
    /// the next game. The run starts once the queue empties, because
    /// a dismissal is an answer the user chose not to give.
    private var firstAsk: Binding<BackupModeAsk?> {
        Binding(
            get: { waiting.first },
            set: { _ in
                if !waiting.isEmpty { waiting.removeFirst() }
                if waiting.isEmpty { startTheRun() }
            })
    }

    // MARK: - The empty state, per 13.14

    private var emptyState: some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                Text(
                    "Empo can copy your saves to a service you already use, "
                        + "so a lost phone does not lose your games."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                Button("Add a backup target") { showsAddSheet = true }
                    .buttonStyle(PrimaryButtonStyle(size: .md))
            }
            .padding(.vertical, Spacing.md)
        }
    }

    // MARK: - The status line, per 13.4

    @ViewBuilder private var statusSection: some View {
        if let status = model.status {
            Section {
                Text(status.line)
                    .font(.headline)
                    .foregroundStyle(status.isHealthy ? Color.primary : Color.orange)
                    .padding(.vertical, Spacing.xs)
            }
        }
    }

    // MARK: - The adopt banner, per 13.13

    @ViewBuilder private var adoptBanners: some View {
        ForEach(model.adoptBanners) { banner in
            Section {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text(AdoptQuestion.question)
                        .font(.subheadline)
                    Text("On \(banner.targetLabel).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack(spacing: Spacing.lg) {
                        Button(AdoptQuestion.label(of: .adopt)) {
                            model.answerTheAdoptBanner(banner, adopts: true)
                        }
                        .buttonStyle(PrimaryButtonStyle(size: .sm))
                        Button(AdoptQuestion.label(of: .startFresh)) {
                            model.answerTheAdoptBanner(banner, adopts: false)
                        }
                        .buttonStyle(SecondaryButtonStyle(size: .sm))
                    }
                }
                .padding(.vertical, Spacing.xs)
            }
        }
    }

    // MARK: - The run block, per 13.4

    /// The run block shows while a pass is in flight, per 13.4.
    private var isRunning: Bool { BackupRunMonitor.shared.isRunning }

    @ViewBuilder private var runBlock: some View {
        if isRunning {
            let monitor = BackupRunMonitor.shared
            Section {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text(monitor.line)
                        .font(.subheadline.weight(.medium))
                    // The bar counts the run plan the engine froze at
                    // staging end, per 13.2.
                    ProgressView(value: monitor.plan.fraction ?? 0)
                        .progressViewStyle(.linear)
                    Button("Pause") { BackupScheduler.shared.pauseTheRun() }
                        .buttonStyle(SecondaryButtonStyle(size: .sm))
                }
                .padding(.vertical, Spacing.xs)

                ForEach(monitor.queue) { row in
                    HStack {
                        Text(row.name)
                            .font(.footnote)
                        Spacer()
                        if monitor.isDone(row.gameKey) {
                            Image(systemName: "checkmark")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Backing up")
            }
        }
    }

    // MARK: - "Back up now", per 13.11

    private var backUpNowSection: some View {
        Section {
            Button {
                Task { await press() }
            } label: {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Back up now")
                    Text(model.backUpNowLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, Spacing.xxs)
            }
            .disabled(!model.canBackUpNow)
        }
    }

    /// The press asks about every game that never answered the ask
    /// of 3.5 before it starts the run, because a run skips such a
    /// game.
    private func press() async {
        waiting = await model.gamesWaitingForTheAsk()
        guard waiting.isEmpty else { return }
        startTheRun()
    }

    private func startTheRun() {
        model.backUpNow()
    }

    // MARK: - The target list, per 13.5

    private func targetList(_ items: [BackupTargetItem]) -> some View {
        Section {
            ForEach(items) { item in
                HStack(spacing: Spacing.lg) {
                    NavigationLink {
                        TargetDetailScreen(model: model, targetId: item.id)
                    } label: {
                        TargetRowView(row: item.row)
                    }
                    .disabled(item.row.isDisabled)
                    if let action = item.row.action {
                        Button(action.label) { Task { await press(item) } }
                            .buttonStyle(.borderless)
                            .font(.subheadline)
                    }
                }
            }
            Button("Add a target") { showsAddSheet = true }
        } header: {
            Text("Targets")
        }
    }

    private func press(_ item: BackupTargetItem) async {
        switch item.row.action {
        case .resume:
            await model.setPaused(false, targetId: item.id)
        case .signIn:
            let outcome = await BackupTargetAdd.signInAgain(item.descriptor)
            if case .checked(let descriptor, let result) = outcome {
                addedTarget = PermissionCheckOutcomeSheet(
                    targetLabel: descriptor.displayName, result: result)
            }
            await model.refresh()
        case .makeSpace, .none:
            break
        }
    }

    // MARK: - Manual transfer, per 12.5

    /// Both doors close while a game runs, per 7.6.
    private var manualTransferOpens: Bool {
        PackageDoors.opens(gameIsPlaying: BackupDeviceConditions.isSessionLive)
    }

    private var manualTransfer: some View {
        Section {
            Button("Export library") { exports = true }
                .disabled(!manualTransferOpens)
            Button("Import backup") { showsTheZipPicker = true }
                .disabled(!manualTransferOpens)
            if let unsavedPackage {
                Button(PackageSaveChoice.question(fileName: unsavedPackage.fileName)) {
                    savesAgain = unsavedPackage
                }
            }
        } header: {
            Text("Manual transfer")
        } footer: {
            Text(
                PackageDoors.line(gameName: EngineSessionCoordinator.shared.openGameName)
                    ?? "A backup package is a ZIP file you keep in Files. "
                    + "It needs no backup target.")
        }
    }

    // MARK: - The app-wide settings, per 13.14

    private var settingsSection: some View {
        Section {
            SettingsToggle(
                title: "Back up over cellular",
                isOn: $overCellular,
                description: "Off keeps every upload on Wi-Fi. Low Data Mode always stops uploads.")

            SettingsPicker(
                title: "Keep",
                selection: $retention,
                description: retention.line
            ) {
                ForEach(RetentionPreset.allCases, id: \.self) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            .onChange(of: retention) { _, preset in BackupSettings.retention = preset }

            Button {
                lookForAGroup()
            } label: {
                HStack {
                    Text("Sync settings with another device")
                    Spacer()
                    if looksForAGroup { ProgressView() }
                }
            }
            .disabled(looksForAGroup)

            Text(SyncGroupCopy.stableLine)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// The screen makes no request until the user asks, so the join
    /// step of 10.4 lists the targets from this press alone.
    private func lookForAGroup() {
        looksForAGroup = true
        Task {
            let ask = await SyncJoin.ask()
            looksForAGroup = false
            joinAsk = SyncJoinPrompt(ask: ask)
        }
    }

    // MARK: - Notifications and history, per 13.19 and 13.12

    private var historySection: some View {
        Section {
            if model.asksForNotifications {
                Button(BackupNotificationAsk.rowLabel) {
                    Task { await model.pressTheNotificationRow() }
                }
            }
            NavigationLink {
                BackupHistoryScreen(model: model)
            } label: {
                Text("Backup history")
            }
        }
    }
}

/// The join ask of 10.4, waiting for its sheet.
struct SyncJoinPrompt: Identifiable {
    let ask: SyncJoinAsk
    let id = UUID()
}

/// The permission check of 8.7, waiting for its sheet.
struct PermissionCheckOutcomeSheet: Identifiable {
    let targetLabel: String
    let result: PermissionCheckResult
    var id: String { targetLabel }
}
