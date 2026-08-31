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
    @State private var isRunning = BackupScheduler.shared.isRunning
    /// The games the ask of 3.5 still waits on, per the press below.
    @State private var waiting: [BackupModeAsk] = []
    @AppStorage(DefaultsKey.backupOverCellular) private var overCellular = false
    @State private var retention = BackupSettings.retention

    var body: some View {
        List {
            if model.isEmpty {
                emptyState
            } else {
                statusSection
                adoptBanners
                runBlock
                backUpNowSection
                targetList
                manualTransfer
                settingsSection
            }
            historySection
        }
        .navigationTitle("Backups")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !model.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") { showsAddSheet = true }
                }
            }
        }
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
        .sheet(isPresented: $showsAddSheet) {
            AddTargetSheet(iCloudReach: model.iCloudReach) { descriptor, result in
                addedTarget = PermissionCheckOutcomeSheet(
                    targetLabel: descriptor.displayName, result: result)
                Task {
                    await model.refresh()
                    model.askAboutNotificationsIfNeeded()
                }
            }
        }
        .sheet(item: $addedTarget) { outcome in
            PermissionCheckSheet(targetLabel: outcome.targetLabel, result: outcome.result)
        }
        .sheet(item: firstAsk) { ask in
            FirstBackupAskSheet(
                model: BackupSheetModel(container: ask.container, gameName: ask.gameName),
                ask: ask.ask)
        }
        .sheet(isPresented: $model.showsTheNotificationSheet) {
            NotificationAskSheet { answer in
                Task { await model.answerTheNotificationSheet(answer) }
            }
        }
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
                        Button("Continue") {
                            model.answerTheAdoptBanner(banner, adopts: true)
                        }
                        .buttonStyle(PrimaryButtonStyle(size: .sm))
                        Button("Start fresh") {
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

    @ViewBuilder private var runBlock: some View {
        if isRunning {
            Section {
                // Ticket 018 fills this with the per-game queue, the
                // byte-weighted total of 13.2, and Pause.
                HStack(spacing: Spacing.md) {
                    ProgressView()
                    Text("Backing up")
                }
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
        isRunning = true
    }

    // MARK: - The target list, per 13.5

    private var targetList: some View {
        Section {
            ForEach(model.items) { item in
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

    private var manualTransfer: some View {
        Section {
            Text("Ticket 019 brings the backup package.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Manual transfer")
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

            Text("Settings sync when Empo opens.")
                .font(.footnote)
                .foregroundStyle(.secondary)
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

/// The permission check of 8.7, waiting for its sheet.
struct PermissionCheckOutcomeSheet: Identifiable {
    let targetLabel: String
    let result: PermissionCheckResult
    var id: String { targetLabel }
}
