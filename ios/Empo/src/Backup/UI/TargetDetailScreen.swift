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
    @State private var gameNames: [String: String] = [:]

    private var item: BackupTargetItem? {
        model.items.first { $0.id == targetId }
    }

    var body: some View {
        List {
            if let item {
                usageSection(item)
                gamesSection(item)
                limitsSection(item)
                pauseSection(item)
                maintenanceSection(item)
                namespaceSection(item)
                removeSection(item)
            }
        }
        .navigationTitle(item?.descriptor.displayName ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task { gameNames = Self.namesByGameKey() }
        .sheet(isPresented: $showsRemoveSheet) {
            if let item {
                RemoveTargetSheet(item: item) { deletesBackups in
                    Task {
                        await model.remove(targetId: targetId, deleteBackups: deletesBackups)
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Usage, per 13.6

    private func usageSection(_ item: BackupTargetItem) -> some View {
        Section {
            switch item.usage {
            case .bar(let used, let limit):
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    ProgressView(value: Double(used), total: Double(max(limit, 1)))
                    Text(
                        TargetUsageRules.line(
                            item.usage, usedText: BackupText.bytes(used),
                            limitText: BackupText.bytes(limit))
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, Spacing.xs)
            case .bytesWritten(let written):
                Text(
                    TargetUsageRules.line(item.usage, usedText: BackupText.bytes(written))
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
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
                        Spacer()
                        Text(BackupText.bytes(game.bytes))
                            .foregroundStyle(.secondary)
                    }
                }
                if item.games.count > 5 && !showsEveryGame {
                    Button("Show all") { showsEveryGame = true }
                }
            } header: {
                Text("Games")
            }
        }
    }

    // MARK: - The cap and the threshold, per 13.8

    private func limitsSection(_ item: BackupTargetItem) -> some View {
        Section {
            SizeLimitPicker(
                label: "Cap",
                offLabel: "No cap",
                presets: Self.capPresets,
                bytes: item.descriptor.capBytes
            ) { bytes in
                Task { await model.setCap(bytes, targetId: targetId) }
            }
            SizeLimitPicker(
                label: "Ask above",
                offLabel: "\(BackupText.bytes(BackupThreshold.defaultBytes)) (default)",
                presets: Self.thresholdPresets,
                bytes: item.descriptor.sizeThresholdBytes
            ) { bytes in
                Task { await model.setThreshold(bytes, targetId: targetId) }
            }
        } footer: {
            Text("A game over this size asks whether to back up the whole folder.")
        }
    }

    private static let capPresets: [Int64] = [
        1 << 30, 5 << 30, 10 << 30, 50 << 30, 100 << 30,
    ]

    private static let thresholdPresets: [Int64] = [
        100 << 20, 250 << 20, 500 << 20, 2 << 30, 5 << 30,
    ]

    // MARK: - Pause, the only off state, per 13.8

    private func pauseSection(_ item: BackupTargetItem) -> some View {
        Section {
            Toggle(
                "Pause",
                isOn: Binding(
                    get: { item.descriptor.isPaused },
                    set: { isPaused in Task { await model.setPaused(isPaused, targetId: targetId) } }))
        } footer: {
            Text("A paused target joins no backup, and it leaves the 7-day promise.")
        }
    }

    // MARK: - Pending deletions and the sweep, per 13.8

    @ViewBuilder private func maintenanceSection(_ item: BackupTargetItem) -> some View {
        let overdue = SweepSchedule.isOverdue(lastSweepAt: item.lastSweep, now: Date())
        let needsAction = overdue || !item.capabilities.reportsObjectAge
        if item.pendingDeletions > 0 || needsAction {
            Section {
                if item.pendingDeletions > 0 {
                    Text(
                        "\(item.pendingDeletions) deletions waiting for "
                            + item.descriptor.displayName)
                }
                if needsAction {
                    Button("Reclaim space") {
                        BackupScheduler.shared.pressBackUpNow(.library)
                    }
                }
            }
        }
    }

    // MARK: - The namespace list and Remove, per 13.9 and 13.10

    private func namespaceSection(_ item: BackupTargetItem) -> some View {
        Section {
            NavigationLink {
                NamespaceListScreen(model: model, targetId: targetId)
            } label: {
                Text("Devices")
            }
        }
    }

    private func removeSection(_ item: BackupTargetItem) -> some View {
        Section {
            Button("Remove", role: .destructive) { showsRemoveSheet = true }
        }
    }

    /// The library's own names, so a breakdown row reads as a game
    /// and not as a key.
    private static func namesByGameKey() -> [String: String] {
        var names: [String: String] = [:]
        for container in GameContainer.discover() {
            names[BackupKeys.gameKey(containerFolderName: container.folderName)] =
                container.folderName
        }
        return names
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
