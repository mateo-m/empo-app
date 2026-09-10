import GameProbe
import SwiftUI
import UIKit

/// The target screen of SPEC 13.8.
///
/// A pushed level and not an inline expansion, because the namespace
/// list below it is already a stack of target, namespace, game, and
/// snapshot.
struct TargetDetailScreen: View {

    let model: BackupsScreenModel
    let targetId: String

    @Environment(\.dismiss) private var dismiss
    @State private var showsEveryGame = false
    @State private var showsRemoveSheet = false
    @State private var removalFailure: String?
    @State private var signInOutcome: PermissionCheckOutcomeSheet?
    @State private var signsInThroughTheForm = false
    @State private var gameNames: [String: String] = [:]

    private var item: BackupTargetItem? {
        model.items?.first { $0.id == targetId }
    }

    var body: some View {
        List {
            if let item {
                headerSection(item)
                gamesSection(item)
                pauseSection(item)
                limitsSection(item)
                cleanupSection(item)
                devicesSection
                removeSection
            }
        }
        .navigationTitle(item?.descriptor.displayName ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task { gameNames = BackupGameNames().namesByGameKey() }
        .sheet(isPresented: $showsRemoveSheet) {
            if let item {
                RemoveTargetSheet(item: item) { deletesBackups in
                    Task {
                        removalFailure = await model.remove(
                            targetId: targetId, deleteBackups: deletesBackups)
                        if removalFailure == nil { dismiss() }
                    }
                }
            }
        }
        .sheet(isPresented: $signsInThroughTheForm) {
            if let item {
                TargetSignInSheet(target: item.descriptor) { descriptor, result in
                    signInOutcome = PermissionCheckOutcomeSheet(
                        targetLabel: descriptor.displayName, result: result)
                    Task { await model.refresh() }
                }
            }
        }
        .sheet(item: $signInOutcome) { outcome in
            PermissionCheckSheet(targetLabel: outcome.targetLabel, result: outcome.result)
        }
        .alert(
            "Couldn't remove this location", isPresented: .constant(removalFailure != nil),
            presenting: removalFailure
        ) { _ in
            Button("OK") { removalFailure = nil }
        } message: { line in
            Text(line)
        }
    }

    // MARK: - The header, per 13.5 and 13.6

    private func headerSection(_ item: BackupTargetItem) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                HStack(spacing: Spacing.lg) {
                    Image(systemName: item.descriptor.provider.symbolName)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.brand)
                        .frame(width: 40)
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(item.descriptor.provider.serviceName)
                            .font(.headline)
                        if let hint = item.descriptor.accountHint {
                            Text(hint)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Text(item.row.stateLine)
                            .font(.footnote)
                            .foregroundStyle(item.row.state == .current ? Color.secondary : Color.brand)
                    }
                }
                usage(item)
            }
            .padding(.vertical, Spacing.sm)
            if let action = item.row.action {
                switch action {
                case .signIn:
                    Button("Sign in again") {
                        if BackupTargetAdd.signsInThroughTheForm(item.descriptor.provider) {
                            signsInThroughTheForm = true
                        } else {
                            Task { signInOutcome = await model.signInAgain(item) }
                        }
                    }
                case .resume:
                    Button("Resume backups") { Task { await model.setPaused(false, targetId: targetId) } }
                case .makeSpace:
                    EmptyView()
                }
            }
        }
    }

    @ViewBuilder private func usage(_ item: BackupTargetItem) -> some View {
        switch item.usage {
        case .bar(let used, let limit):
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ProgressView(value: Double(used), total: Double(max(limit, 1)))
                    .tint(.brand)
                Text(
                    TargetUsageRules.line(
                        item.usage, usedText: BackupText.bytes(used),
                        limitText: BackupText.bytes(limit))
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        case .bytesWritten(let written):
            Text(TargetUsageRules.line(item.usage, usedText: BackupText.bytes(written)))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - The per-game breakdown, per 13.8

    @ViewBuilder private func gamesSection(_ item: BackupTargetItem) -> some View {
        if !item.games.isEmpty {
            Section {
                let shown = showsEveryGame ? item.games : Array(item.games.prefix(5))
                ForEach(shown, id: \.gameKey) { game in
                    HStack {
                        Text(gameNames[game.gameKey] ?? game.gameKey)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(BackupText.bytes(game.bytes))
                            .foregroundStyle(.secondary)
                    }
                }
                if item.games.count > 5 && !showsEveryGame {
                    Button("Show all \(item.games.count) games") { showsEveryGame = true }
                }
            } header: {
                Text("Games backed up here")
            }
        }
    }

    // MARK: - Pause, the only off state, per 13.8

    private func pauseSection(_ item: BackupTargetItem) -> some View {
        Section {
            Toggle(
                "Pause backups",
                isOn: Binding(
                    get: { item.descriptor.isPaused },
                    set: { isPaused in Task { await model.setPaused(isPaused, targetId: targetId) } }))
        } footer: {
            Text("While paused, nothing new is backed up here.")
        }
    }

    // MARK: - The cap and the threshold, per 13.8

    private func limitsSection(_ item: BackupTargetItem) -> some View {
        Section {
            SizeLimitPicker(
                label: "Storage limit",
                offLabel: "None",
                presets: Self.capPresets,
                bytes: item.descriptor.capBytes
            ) { bytes in
                Task { await model.setCap(bytes, targetId: targetId) }
            }
            SizeLimitPicker(
                label: "Ask for games over",
                offLabel: BackupText.bytes(BackupThreshold.defaultBytes),
                presets: Self.thresholdPresets,
                bytes: item.descriptor.sizeThresholdBytes
            ) { bytes in
                Task { await model.setThreshold(bytes, targetId: targetId) }
            }
        } header: {
            Text("Limits")
        } footer: {
            Text(
                "Empo stops adding backups here at the storage limit. For a game over the "
                    + "second size, it asks whether to back up the whole game or only its saves.")
        }
    }

    private static let capPresets: [Int64] = [
        1 << 30, 5 << 30, 10 << 30, 50 << 30, 100 << 30,
    ]

    private static let thresholdPresets: [Int64] = [
        100 << 20, 250 << 20, 500 << 20, 2 << 30, 5 << 30,
    ]

    // MARK: - Pending deletions and the sweep, per 13.8

    @ViewBuilder private func cleanupSection(_ item: BackupTargetItem) -> some View {
        let overdue = SweepSchedule.isOverdue(lastSweepAt: item.lastSweep, now: Date())
        let needsAction = overdue || !item.capabilities.reportsObjectAge
        if item.pendingDeletions > 0 || needsAction {
            Section {
                if item.pendingDeletions > 0 {
                    let count = item.pendingDeletions == 1 ? "1 old backup" : "\(item.pendingDeletions) old backups"
                    Text("\(count) waiting to be deleted")
                }
                if needsAction {
                    Button("Delete old backups now") {
                        BackupScheduler.shared.pressBackUpNow(.library)
                    }
                }
            } footer: {
                Text("Empo deletes backups over the Keep old backups limit at the next backup.")
            }
        }
    }

    // MARK: - The namespace list and Remove, per 13.9 and 13.10

    private var devicesSection: some View {
        Section {
            NavigationLink("Devices") {
                NamespaceListScreen(model: model, targetId: targetId)
            }
        } footer: {
            Text("Every device that backs up here, with its games and backups.")
        }
    }

    private var removeSection: some View {
        Section {
            Button("Remove location", role: .destructive) { showsRemoveSheet = true }
        }
    }
}

/// A size limit as the presets of 13.8 plus a Custom entry.
///
/// A value the user typed earlier is a preset of its own here, so
/// reopening the screen shows what the target holds.
private struct SizeLimitPicker: View {

    let label: String
    let offLabel: String
    let presets: [Int64]
    let bytes: Int64?
    let set: (Int64?) -> Void

    @State private var isCustom = false
    @State private var typed = ""

    private enum Choice: Hashable {
        case off
        case preset(Int64)
        case custom
    }

    var body: some View {
        Picker(label, selection: binding) {
            Text(offLabel).tag(Choice.off)
            ForEach(options, id: \.self) { value in
                Text(BackupText.bytes(value)).tag(Choice.preset(value))
            }
            Text("Custom").tag(Choice.custom)
        }
        if isCustom {
            HStack {
                TextField("Size in GB", text: $typed)
                    .keyboardType(.decimalPad)
                Button("Set") {
                    guard let gigabytes = Double(typed), gigabytes > 0 else { return }
                    set(Int64(gigabytes * 1_073_741_824))
                    isCustom = false
                }
                .disabled(Double(typed) == nil)
            }
        }
    }

    /// The presets plus the value the target holds, so a custom size
    /// keeps its own row.
    private var options: [Int64] {
        guard let bytes, !presets.contains(bytes) else { return presets }
        return (presets + [bytes]).sorted()
    }

    private var binding: Binding<Choice> {
        Binding(
            get: {
                if isCustom { return .custom }
                return bytes.map(Choice.preset) ?? .off
            },
            set: { choice in
                switch choice {
                case .off:
                    isCustom = false
                    set(nil)
                case .preset(let value):
                    isCustom = false
                    set(value)
                case .custom:
                    typed = bytes.map { String(format: "%.1f", Double($0) / 1_073_741_824) } ?? ""
                    isCustom = true
                }
            })
    }
}
