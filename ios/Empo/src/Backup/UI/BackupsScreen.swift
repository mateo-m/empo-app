import GameProbe
import SwiftUI

/// The Backups screen of SPEC 13.4.
///
/// The order is fixed: the status card with "Back up now" and the
/// history, the open questions, the locations, the options, the
/// export and import rows, and the settings sync.
struct BackupsScreen: View {

    @State private var model = BackupsScreenModel()
    @State private var showsAddSheet = false
    @State private var addedTarget: PermissionCheckOutcomeSheet?
    /// The fresh-install flow of 11.4 and the notification ask of
    /// 13.19 wait for the permission sheet of the added target to
    /// close. SwiftUI drops a sheet asked for while another one is
    /// up, and keeps its flag set, so no later sheet opens either.
    @State private var pendingFreshInstall: FreshInstallItem?
    @State private var pendingNotificationAsk = false
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
                    writerQuestions
                    splitLine
                    adoptBanners
                    locations(items)
                    optionsSection
                    fileSection
                    syncSection
                }
            }
        }
        .navigationTitle("Backups")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.refresh() }
        // The card reads "Last backup" from the store, so the end of
        // a run needs a fresh read.
        .onChange(of: BackupRunMonitor.shared.isRunning) { _, running in
            if !running { Task { await model.refresh() } }
        }
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
                    pendingNotificationAsk = model.asksAboutNotifications()
                    if !result.allowsAdd {
                        return
                    }
                    if let scan = await model.freshInstall(after: descriptor) {
                        pendingFreshInstall = FreshInstallItem(descriptor: descriptor, scan: scan)
                    } else {
                        await model.readTheAdoptBanners(of: descriptor.id)
                    }
                    showTheNextSheet()
                }
            }
        }
        .sheet(
            item: $addedTarget,
            onDismiss: showTheNextSheet,
            content: { outcome in
                PermissionCheckSheet(targetLabel: outcome.targetLabel, result: outcome.result)
            }
        )
        .sheet(item: $freshInstall, onDismiss: showTheNextSheet) { item in
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

    /// The permission sheet goes first, the fresh-install sheet
    /// second, and the notification ask last.
    private func showTheNextSheet() {
        guard addedTarget == nil, freshInstall == nil else { return }
        if let item = pendingFreshInstall {
            pendingFreshInstall = nil
            freshInstall = item
        } else if pendingNotificationAsk {
            pendingNotificationAsk = false
            model.showsTheNotificationSheet = true
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
            ContentUnavailableView {
                Label("No backups yet", systemImage: "externaldrive.badge.icloud")
            } description: {
                Text("Add a place to keep copies of your saves, like iCloud Drive or your own server.")
            } actions: {
                Button("Add a location") { showsAddSheet = true }
                    .buttonStyle(PrimaryButtonStyle(size: .md))
            }
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - The status card, per 13.4 and 13.11

    private var isRunning: Bool { BackupRunMonitor.shared.isRunning }

    @ViewBuilder private var statusSection: some View {
        Section {
            if let status = model.status {
                BackupStatusCard(status: status)
            }
            if isRunning {
                Button("Pause backup") { BackupScheduler.shared.pauseTheRun() }
            } else {
                Button("Back up now") { Task { await press() } }
                    .disabled(!model.canBackUpNow)
            }
            NavigationLink("Backup history") {
                BackupHistoryScreen(model: model)
            }
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

    // MARK: - The writer question, per 5.12

    @ViewBuilder private var writerQuestions: some View {
        ForEach(model.writerQuestions) { item in
            Section {
                question(
                    WriterConflictQuestion.line(
                        deviceName: item.deviceName, targetLabel: item.targetLabel),
                    note: WriterConflictQuestion.note)
                Button(WriterConflictQuestion.label(of: .split)) {
                    model.answerTheWriterQuestion(item, resolution: .split)
                }
                Button(WriterConflictQuestion.label(of: .takeOver)) {
                    model.answerTheWriterQuestion(item, resolution: .takeOver)
                }
            }
        }
    }

    @ViewBuilder private var splitLine: some View {
        if model.showsTheSplitLine {
            Section {
                question(BackupNotificationRule.writerSplitLine, note: nil)
                Button("OK") { model.closeTheSplitLine() }
            }
        }
    }

    // MARK: - The adopt banner, per 13.13

    @ViewBuilder private var adoptBanners: some View {
        ForEach(model.adoptBanners) { banner in
            Section {
                question(AdoptQuestion.question, note: "On \(banner.targetLabel).")
                Button(AdoptQuestion.label(of: .adopt)) {
                    model.answerTheAdoptBanner(banner, adopts: true)
                }
                Button(AdoptQuestion.label(of: .startFresh)) {
                    model.answerTheAdoptBanner(banner, adopts: false)
                }
            }
        }
    }

    /// The text row of a question section. The answers are the rows
    /// under it, so every answer is a whole row.
    private func question(_ line: String, note: String?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(line)
                .font(.subheadline.weight(.medium))
            if let note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Spacing.xxs)
    }

    // MARK: - The locations, per 13.5

    private func locations(_ items: [BackupTargetItem]) -> some View {
        Section {
            ForEach(items) { item in
                HStack(spacing: Spacing.lg) {
                    NavigationLink {
                        TargetDetailScreen(model: model, targetId: item.id)
                    } label: {
                        TargetRowView(row: item.row, provider: item.descriptor.provider)
                    }
                    .disabled(item.row.isDisabled)
                    if let action = item.row.action, action != .makeSpace {
                        Button(action.label) { Task { await press(action, on: item) } }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                            .font(.subheadline.weight(.medium))
                    }
                }
            }
            Button {
                showsAddSheet = true
            } label: {
                Label("Add a location", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("Locations")
        }
    }

    private func press(_ action: TargetRowAction, on item: BackupTargetItem) async {
        switch action {
        case .resume:
            await model.setPaused(false, targetId: item.id)
        case .signIn:
            addedTarget = await model.signInAgain(item)
        case .makeSpace:
            break
        }
    }

    // MARK: - The options, per 13.14 and 13.19

    private var optionsSection: some View {
        Section {
            SettingsToggle(
                title: "Use cellular data",
                isOn: $overCellular,
                description: "Backs up over cellular as well as Wi-Fi. Low Data Mode always pauses backups.")

            SettingsPicker(
                title: "Keep old backups",
                selection: $retention,
                description: retention.line
            ) {
                ForEach(RetentionPreset.allCases, id: \.self) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            .onChange(of: retention) { _, preset in BackupSettings.retention = preset }

            if model.asksForNotifications {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Button(BackupNotificationAsk.rowLabel) {
                        Task { await model.pressTheNotificationRow() }
                    }
                    Text("Get a notification when a backup stops and needs you.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, Spacing.xxs)
            }
        } header: {
            Text("Options")
        }
    }

    // MARK: - Export and import, per 12.5

    /// Both doors close while a game runs, per 7.6.
    private var fileDoorsOpen: Bool {
        PackageDoors.opens(gameIsPlaying: BackupDeviceConditions.isSessionLive)
    }

    private var fileSection: some View {
        Section {
            Button("Export all saves") { exports = true }
                .disabled(!fileDoorsOpen)
            Button("Import a backup") { showsTheZipPicker = true }
                .disabled(!fileDoorsOpen)
            if let unsavedPackage {
                Button(PackageSaveChoice.question(fileName: unsavedPackage.fileName)) {
                    savesAgain = unsavedPackage
                }
            }
        } footer: {
            Text(
                PackageDoors.line(gameName: EngineSessionCoordinator.shared.openGameName)
                    ?? "An export is a ZIP file you keep in Files. It needs no backup location.")
        }
    }

    // MARK: - The settings sync, per 10.4

    private var syncSection: some View {
        Section {
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
        } footer: {
            Text(SyncGroupCopy.stableLine)
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
