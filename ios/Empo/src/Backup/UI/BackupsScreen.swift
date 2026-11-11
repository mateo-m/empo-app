import GameProbe
import SwiftUI

/// The Backups screen of SPEC 13.4.
///
/// The order is fixed: the status card with "Back up now" and the
/// history, the open questions, the locations, the options, the
/// export and import rows, and the settings sync.
struct BackupsScreen: View {

    @State private var model = BackupsScreenModel()
    @State private var signInFailure: String?
    @State private var sheets = SheetQueue<BackupsSheet>()
    @AppStorage(DefaultsKey.backupOverCellular) private var overCellular = false
    @State private var retention = BackupSettings.retention
    /// The package a launch found waiting for its save, per 12.5.
    @State private var unsavedPackage: PackageRecord?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var looksForAGroup = false
    @State private var setUpAgainFailure: String?

    var body: some View {
        ReadFirst(value: model.items) { items in
            List {
                damagedTargetsLine
                if items.isEmpty {
                    emptyState
                    fileSection
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
        // The card grows a bar and the button changes its title when
        // a run starts. The list animates the row heights from here.
        .animation(reduceMotion ? nil : Motion.standard, value: isRunning)
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
        .signInFailureAlert($signInFailure)
        .onChange(of: EmpoPlus.shared.hasPlus) { Task { await model.refresh() } }
        .sheet(item: $sheets.presented, onDismiss: sheetClosed, content: content)
    }

    @ViewBuilder private func content(_ sheet: BackupsSheet) -> some View {
        switch sheet {
        case .plus:
            PlusSheet()
        case .export:
            PackageExportSheet(source: .library)
        case .zipPicker:
            PackageZipPicker { url in
                sheets.showNext(.importPackage(PickedPackage(url: url)))
                sheets.presented = nil
            }
        case .importPackage(let file):
            PackageImportSheet(picked: file.url)
        case .saveAgain(let record):
            PackageExportSheet(source: .library, model: PackageExportModel(waiting: record))
        case .add:
            AddTargetSheet(
                iCloudReach: model.iCloudReach,
                hasICloudDrive: (model.items ?? []).contains { $0.descriptor.provider == .iCloudDrive }
            ) { descriptor, result in
                sheets.show(.permission(PermissionCheckOutcomeSheet(target: descriptor, result: result)))
                Task {
                    await model.refresh()
                    let asksAboutNotifications = model.asksAboutNotifications()
                    if result.allowsAdd {
                        if let scan = await model.freshInstall(after: descriptor) {
                            sheets.show(
                                .freshInstall(
                                    FreshInstallItem(
                                        model: FreshInstallModel(descriptor: descriptor, scan: scan))))
                        } else {
                            await model.readTheAdoptBanners(of: descriptor.id)
                        }
                    }
                    if asksAboutNotifications { sheets.show(.notificationAsk) }
                }
            }
        case .signIn(let item):
            TargetSignInSheet(target: item.descriptor) { descriptor, result in
                sheets.show(.permission(PermissionCheckOutcomeSheet(target: descriptor, result: result)))
                Task { await model.refresh() }
            }
        case .permission(let outcome):
            PermissionCheckSheet(target: outcome.target, result: outcome.result)
        case .freshInstall(let item):
            FreshInstallSheet(model: item.model)
                .onDisappear {
                    // A cancel before the confirm tap leaves the
                    // question of 11.5 open, so the banner asks it.
                    guard !item.model.hasAnsweredTheAdopt else { return }
                    Task { await model.readTheAdoptBanners(of: item.model.descriptor.id) }
                }
        case .notificationAsk:
            NotificationAskSheet { answer in
                Task { await model.answerTheNotificationSheet(answer) }
            }
        case .firstAsk(let ask):
            FirstBackupAskSheet(
                model: BackupSheetModel(container: ask.container, gameName: ask.gameName),
                ask: ask.ask)
        case .join(let prompt):
            SyncJoinSheet(ask: prompt.ask) { group in SyncJoin.join(group) }
        }
    }

    private func sheetClosed() {
        switch sheets.closed() {
        case .saveAgain:
            readTheUnsavedPackage()
        case .firstAsk:
            // Each answer, and each dismissal, moves to the next game.
            // The run starts after the last one, because a dismissal is
            // an answer the user chose not to give.
            if !sheets.holds(where: \.isFirstAsk) { startTheRun() }
        default:
            break
        }
    }

    /// The package a failed or cancelled save left behind, per 12.5.
    private func readTheUnsavedPackage() {
        unsavedPackage = PackageRecord.waitingForASave(localRoot: BackupRoot.layout.root)
    }

    // MARK: - The empty state, per 13.14

    private var emptyState: some View {
        Section {
            ContentUnavailableView {
                Label("No backups yet", systemImage: "externaldrive.badge.icloud")
            } description: {
                Text("Add a place to keep copies of your saves, like iCloud Drive or your own server.")
            } actions: {
                Button("Add a location") { sheets.show(.add) }
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
            Button {
                if isRunning {
                    BackupScheduler.shared.pauseTheRun()
                } else {
                    Task { await press() }
                }
            } label: {
                ZStack(alignment: .leading) {
                    Text(isRunning ? "Pause backup" : "Back up now")
                        .id(isRunning)
                        .transition(reduceMotion ? .opacity : .stateChange)
                }
            }
            .disabled(!isRunning && !model.canBackUpNow)
            NavigationLink("Backup history") {
                BackupHistoryScreen(model: model)
            }
        }
    }

    /// The press asks about every game that never answered the ask
    /// of 3.5 before it starts the run, because a run skips such a
    /// game.
    private func press() async {
        let waiting = await model.gamesWaitingForTheAsk()
        guard waiting.isEmpty else {
            waiting.forEach { sheets.show(.firstAsk($0)) }
            return
        }
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

    @ViewBuilder private var damagedTargetsLine: some View {
        if model.targetsFileIsDamaged {
            Section {
                question(
                    String(localized: "Empo can't read your list of locations."),
                    note: String(
                        localized:
                            "Your backups are still there. Add your locations again to keep backing up."))
                Button("Add locations again") {
                    Task {
                        await model.setAsideTheDamagedTargets()
                        if !model.targetsFileIsDamaged { sheets.show(.add) }
                    }
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
                question(AdoptQuestion.question, note: String(localized: "On \(banner.targetLabel)."))
                Button(AdoptQuestion.label(of: .adopt)) {
                    Task { await model.answerTheAdoptBanner(banner, adopts: true) }
                }
                Button(AdoptQuestion.label(of: .startFresh)) {
                    Task { await model.answerTheAdoptBanner(banner, adopts: false) }
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
                NavigationLink {
                    TargetDetailScreen(model: model, targetId: item.id)
                } label: {
                    HStack(spacing: Spacing.lg) {
                        TargetRowView(row: item.row, target: item.descriptor)
                        Spacer(minLength: 0)
                        if let action = item.row.action {
                            if action == .getPlus {
                                Button(action.label) { Task { await press(action, on: item) } }
                                    .buttonStyle(.primary(size: .sm))
                                    .plusShine(over: .capsule)
                            } else {
                                Button(action.label) { Task { await press(action, on: item) } }
                                    .buttonStyle(.bordered)
                                    .buttonBorderShape(.capsule)
                                    .font(.subheadline.weight(.medium))
                            }
                        }
                    }
                }
            }
            Button {
                sheets.show(.add)
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
            if BackupTargetAdd.signsInThroughTheForm(item.descriptor.provider) {
                sheets.show(.signIn(item))
            } else {
                switch await model.signInAgain(item) {
                case .checked(let outcome): sheets.show(.permission(outcome))
                case .failed(let line): signInFailure = line
                case nil: break
                }
            }
        case .tryAgain:
            model.backUpNow()
        case .getPlus:
            sheets.show(.plus)
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
                description: Text(verbatim: retention.line)
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
            Button("Export all saves") { sheets.show(.export) }
                .disabled(!fileDoorsOpen)
            Button("Import a backup") { sheets.show(.zipPicker) }
                .disabled(!fileDoorsOpen)
            if let unsavedPackage {
                Button(PackageSaveChoice.question(fileName: unsavedPackage.fileName)) {
                    sheets.show(.saveAgain(unsavedPackage))
                }
            }
        } footer: {
            Text(
                PackageDoors.line(gameName: EngineSessionCoordinator.shared.openGameName)
                    ?? String(
                        localized: "An export is a ZIP file you keep in Files. It needs no backup location."))
        }
    }

    // MARK: - The settings sync, per 10.4

    private var syncSection: some View {
        Section {
            Button {
                if SyncPass.shared.settingsAreDamaged { setUpSyncAgain() } else { lookForAGroup() }
            } label: {
                HStack {
                    Text(
                        SyncPass.shared.settingsAreDamaged
                            ? SyncGroupCopy.setUpAgainLabel
                            : String(localized: "Sync settings with another device"))
                    Spacer()
                    if looksForAGroup { ProgressView() }
                }
            }
            .disabled(looksForAGroup)
        } footer: {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                if SyncPass.shared.settingsAreDamaged {
                    Label(
                        setUpAgainFailure ?? SyncGroupCopy.stoppedLine,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.warning)
                } else {
                    if SyncPass.shared.lastPassFailed {
                        Label(SyncGroupCopy.failedLine, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.warning)
                    }
                    Text(SyncGroupCopy.stableLine)
                }
            }
        }
    }

    private func setUpSyncAgain() {
        looksForAGroup = true
        setUpAgainFailure = nil
        Task {
            do {
                let ask = try await SyncJoin.setUpAgain()
                sheets.show(.join(SyncJoinPrompt(ask: ask)))
            } catch {
                BackupLog.line("BackupsScreen", "sync.json was not set aside: \(error)")
                setUpAgainFailure = String(localized: "Empo couldn't set up sync again. Try again.")
            }
            looksForAGroup = false
        }
    }

    /// The screen makes no request until the user asks, so the join
    /// step of 10.4 lists the targets from this press alone.
    private func lookForAGroup() {
        looksForAGroup = true
        Task {
            let ask = await SyncJoin.ask()
            looksForAGroup = false
            sheets.show(.join(SyncJoinPrompt(ask: ask)))
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
    let target: TargetDescriptor
    let result: PermissionCheckResult
    var id: String { target.id }
}

private enum BackupsSheet: Identifiable {
    case plus
    case export
    case zipPicker
    case importPackage(PickedPackage)
    case saveAgain(PackageRecord)
    case add
    case signIn(BackupTargetItem)
    case permission(PermissionCheckOutcomeSheet)
    case freshInstall(FreshInstallItem)
    case notificationAsk
    case firstAsk(BackupModeAsk)
    case join(SyncJoinPrompt)

    var id: String {
        switch self {
        case .plus: "plus"
        case .export: "export"
        case .zipPicker: "zip-picker"
        case .importPackage(let file): "import-" + file.id
        case .saveAgain(let record): "save-again-" + record.id
        case .add: "add"
        case .signIn(let item): "sign-in-" + item.id
        case .permission(let outcome): "permission-" + outcome.id
        case .freshInstall(let item): "fresh-install-" + item.id
        case .notificationAsk: "notification-ask"
        case .firstAsk(let ask): "first-ask-" + ask.id
        case .join(let prompt): "join-" + prompt.id.uuidString
        }
    }

    var isFirstAsk: Bool {
        if case .firstAsk = self { true } else { false }
    }
}

extension View {
    func signInFailureAlert(_ line: Binding<String?>) -> some View {
        alert(
            "Couldn't sign in",
            isPresented: Binding(
                get: { line.wrappedValue != nil }, set: { if !$0 { line.wrappedValue = nil } })
        ) {
            Button("OK") { line.wrappedValue = nil }
        } message: {
            Text(line.wrappedValue ?? "")
        }
    }
}
