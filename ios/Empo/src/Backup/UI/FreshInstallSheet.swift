import GameProbe
import SwiftUI

/// The fresh-install screen of SPEC 11.4 and the restores it runs.
///
/// Nothing restores before the confirm tap. The adopt question of
/// 11.5 comes right before the first write.
@MainActor
@Observable
final class FreshInstallModel {

    let descriptor: TargetDescriptor
    private(set) var plan: FreshInstallPlan
    /// The row a restore is writing now, or `nil` before the confirm
    /// tap and after the last row.
    private(set) var restoring: String?
    private(set) var finishedCount = 0
    private(set) var failures: [String] = []
    private(set) var isDone = false

    private let adoptableNamespaceIds: [String]

    init(descriptor: TargetDescriptor, scan: FreshInstallScan) {
        self.descriptor = descriptor
        plan = scan.plan
        adoptableNamespaceIds = scan.adoptableNamespaceIds
    }

    var selectedCount: Int {
        plan.selectedGames.count + (picked(plan.preferences) ? 1 : 0)
            + (picked(plan.rescuedSaves) ? 1 : 0)
    }

    // MARK: - What the user picks

    func setSelected(_ isSelected: Bool, ofGameNamed name: String) {
        guard let index = plan.games.firstIndex(where: { $0.name == name }) else { return }
        plan.games[index].isSelected = isSelected
    }

    func select(snapshotId: String, ofGameNamed name: String) {
        guard let index = plan.games.firstIndex(where: { $0.name == name }) else { return }
        plan.games[index].selectedSnapshotId = snapshotId
    }

    func setPreferencesSelected(_ isSelected: Bool) {
        plan.preferences?.isSelected = isSelected
    }

    func setRescuedSavesSelected(_ isSelected: Bool) {
        plan.rescuedSaves?.isSelected = isSelected
    }

    // MARK: - The adopt question, per 11.5

    var asksToAdopt: Bool { !adoptableNamespaceIds.isEmpty }

    func answerTheAdopt(_ answer: AdoptQuestion.Answer) {
        guard answer == .adopt, let first = adoptableNamespaceIds.first else { return }
        try? BackupKeychain.adoptNamespaceId(first)
    }

    // MARK: - The confirm tap

    func run() async {
        guard let provider = await BackupTargets.provider(for: descriptor) else {
            failures.append(descriptor.displayName)
            isDone = true
            return
        }

        for row in plan.selectedGames {
            guard let snapshot = row.selected else { continue }
            restoring = row.name
            guard
                let container = RestoreCoordinator.makeTheContainer(
                    folderName: snapshot.identity.containerFolderName)
            else {
                failures.append(row.name)
                continue
            }
            await restore(
                snapshot, into: container, scope: .wholeGame, name: row.name,
                provider: provider)
        }

        if let preferences = plan.preferences, preferences.isSelected {
            restoring = BackupGameNames.preferencesName
            await restore(
                preferences.snapshot, into: nil, scope: .preferences,
                name: BackupGameNames.preferencesName, provider: provider)
        }
        if let rescued = plan.rescuedSaves, rescued.isSelected {
            restoring = Self.rescuedSavesName
            await restore(
                rescued.snapshot, into: nil, scope: .rescuedSaves,
                name: Self.rescuedSavesName, provider: provider)
        }

        restoring = nil
        isDone = true
    }

    static let rescuedSavesName = "Rescued Saves"

    private func restore(
        _ row: SnapshotRow,
        into container: GameContainer?,
        scope: RestoreScope,
        name: String,
        provider: some BackupProvider
    ) async {
        let outcome = await RestoreCoordinator.shared.restore(
            row, into: container, provider: provider, descriptor: descriptor, scope: scope)
        if case .finished = outcome {
            finishedCount += 1
        } else {
            failures.append(name)
        }
    }

    private func picked(_ row: FreshInstallExtraRow?) -> Bool {
        row?.isSelected ?? false
    }
}

/// The fresh-install screen of SPEC 11.4.
struct FreshInstallSheet: View {

    @State var model: FreshInstallModel

    @Environment(\.dismiss) private var dismiss
    @State private var asksToAdopt = false
    @State private var runs = false

    var body: some View {
        NavigationStack {
            List {
                if runs {
                    progress
                } else {
                    games
                    extras
                    hints
                }
            }
            .navigationTitle("Restore your backups")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(model.isDone ? "Done" : "Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !runs {
                    SheetPrimaryButton("Restore") { press() }
                        .disabled(model.selectedCount == 0)
                        .padding(Spacing.lg)
                }
            }
        }
        .tint(.brand)
        .interactiveDismissDisabled(runs && !model.isDone)
        .alert(AdoptQuestion.question, isPresented: $asksToAdopt) {
            Button(AdoptQuestion.label(of: .adopt)) { answer(.adopt) }
            Button(AdoptQuestion.label(of: .startFresh)) { answer(.startFresh) }
        }
    }

    // MARK: - The rows

    private var games: some View {
        Section {
            ForEach(model.plan.games, id: \.name) { row in
                DisclosureGroup {
                    ForEach(row.snapshots, id: \.snapshotId) { snapshot in
                        Button {
                            model.select(snapshotId: snapshot.snapshotId, ofGameNamed: row.name)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: Spacing.xs) {
                                    Text(BackupText.date(snapshot.createdAt))
                                    Text("\(snapshot.deviceName), \(snapshot.targetLabel)")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if snapshot.snapshotId == row.selectedSnapshotId {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } label: {
                    Toggle(isOn: selection(of: row)) {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text(row.name)
                            Text(Self.line(of: row))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Games")
        }
    }

    @ViewBuilder private var extras: some View {
        Section {
            if let preferences = model.plan.preferences {
                Toggle(
                    "Settings",
                    isOn: Binding(
                        get: { preferences.isSelected },
                        set: { model.setPreferencesSelected($0) }))
            }
            if let rescued = model.plan.rescuedSaves {
                Toggle(
                    isOn: Binding(
                        get: { rescued.isSelected },
                        set: { model.setRescuedSavesSelected($0) })
                ) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(FreshInstallModel.rescuedSavesName)
                        Text(rescued.bucketNames.joined(separator: ", "))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private var hints: some View {
        if !model.plan.hints.isEmpty {
            Section {
                ForEach(model.plan.hints, id: \.self) { hint in
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var progress: some View {
        Section {
            if let restoring = model.restoring {
                HStack(spacing: Spacing.md) {
                    ProgressView()
                    Text("Restoring \(restoring)…")
                }
            } else if model.isDone {
                Text("Restored \(model.finishedCount) items.")
            }
            if !model.failures.isEmpty {
                Text("These did not restore: \(model.failures.joined(separator: ", ")).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The date and the device of the snapshot the row picked.
    private static func line(of row: FreshInstallGameRow) -> String {
        guard let selected = row.selected else { return "" }
        return "\(BackupText.date(selected.createdAt)), \(row.sourceDeviceName)"
    }

    // MARK: - The confirm tap

    private func selection(of row: FreshInstallGameRow) -> Binding<Bool> {
        Binding(
            get: { row.isSelected },
            set: { model.setSelected($0, ofGameNamed: row.name) })
    }

    private func press() {
        if model.asksToAdopt {
            asksToAdopt = true
            return
        }
        start()
    }

    private func answer(_ answer: AdoptQuestion.Answer) {
        model.answerTheAdopt(answer)
        start()
    }

    private func start() {
        runs = true
        Task { await model.run() }
    }
}

/// What the Backups screen holds while the permission sheet of the
/// added target is still open.
struct FreshInstallItem: Identifiable {
    let descriptor: TargetDescriptor
    let scan: FreshInstallScan

    var id: String { descriptor.id }
}
