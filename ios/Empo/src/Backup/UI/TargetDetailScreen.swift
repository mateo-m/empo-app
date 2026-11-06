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
    @State private var signInOutcome: PermissionCheckOutcomeSheet?
    @State private var signInFailure: String?
    @State private var signsInThroughTheForm = false
    @State private var showsPlus = false
    @State private var gameNames: [String: String] = [:]

    private var item: BackupTargetItem? {
        model.items?.first { $0.id == targetId }
    }

    var body: some View {
        List {
            if let item {
                headerSection(item)
                if !item.row.isDisabled {
                    gamesSection(item)
                    pauseSection(item)
                    limitsSection(item)
                    cleanupSection(item)
                    devicesSection
                }
                removeSection
            }
        }
        .navigationTitle(item?.descriptor.displayName ?? "")
        .sheet(isPresented: $showsPlus) { PlusSheet() }
        .signInFailureAlert($signInFailure)
        .navigationBarTitleDisplayMode(.inline)
        .task { gameNames = BackupGameNames().namesByGameKey() }
        .sheet(isPresented: $showsRemoveSheet, onDismiss: leaveIfRemoved) {
            if let item {
                RemoveTargetSheet(item: item) { deletesBackups in
                    await model.remove(targetId: targetId, deleteBackups: deletesBackups)
                }
            }
        }
        .sheet(isPresented: $signsInThroughTheForm) {
            if let item {
                TargetSignInSheet(target: item.descriptor) { descriptor, result in
                    signInOutcome = PermissionCheckOutcomeSheet(target: descriptor, result: result)
                    Task { await model.refresh() }
                }
            }
        }
        .sheet(item: $signInOutcome) { outcome in
            PermissionCheckSheet(target: outcome.target, result: outcome.result)
        }
    }

    private func leaveIfRemoved() {
        if model.items?.contains(where: { $0.id == targetId }) == false { dismiss() }
    }

    // MARK: - The header, per 13.5 and 13.6

    private func headerSection(_ item: BackupTargetItem) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                HStack(spacing: Spacing.lg) {
                    AccountAvatar(
                        photo: item.descriptor.accountPhoto, provider: item.descriptor.provider)
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(item.descriptor.displayName)
                            .font(.headline)
                        if item.descriptor.displayName != item.descriptor.provider.serviceName {
                            Text(item.descriptor.provider.serviceName)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if let hint = item.descriptor.accountHint {
                            AccountHintText(hint: hint, provider: item.descriptor.provider)
                        }
                        Text(item.row.stateLine)
                            .font(.footnote)
                            .foregroundStyle(item.row.state.isProblem ? Color.red : Color.secondary)
                            // The List sizes this four-line header too short and cuts the last line.
                            .fixedSize(horizontal: false, vertical: true)
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
                            Task {
                                switch await model.signInAgain(item) {
                                case .checked(let outcome): signInOutcome = outcome
                                case .failed(let line): signInFailure = line
                                case nil: break
                                }
                            }
                        }
                    }
                    .disabled(model.isSigningIn)
                case .resume:
                    Button("Resume backups") { Task { await model.setPaused(false, targetId: targetId) } }
                case .tryAgain:
                    Button("Try again") { model.backUpNow() }
                case .getPlus:
                    Button {
                        showsPlus = true
                    } label: {
                        Text("Get Empo Plus").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.primary(size: .md))
                    .plusShine(over: .capsule)
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
                    HStack(spacing: Spacing.md) {
                        BackupGameArtwork(gameKey: game.gameKey)
                        Text(gameNames[game.gameKey] ?? String(localized: "A removed game"))
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

    // MARK: - The cap and the threshold

    private func limitsSection(_ item: BackupTargetItem) -> some View {
        Section {
            SizeLimitPicker(
                label: String(localized: "Storage limit"),
                offLabel: String(localized: "None"),
                presets: Self.capPresets,
                bytes: item.descriptor.capBytes
            ) { bytes in
                Task { await model.setCap(bytes, targetId: targetId) }
            }
            SizeLimitPicker(
                label: String(localized: "Ask for games over"),
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
                String(
                    localized:
                        "Empo stops adding backups here at the storage limit. For a game over the second size, it asks whether to back up the whole game or only its saves."
                ))
        }
    }

    private static let capPresets: [Int64] = [
        1 * gigabyte, 5 * gigabyte, 10 * gigabyte, 50 * gigabyte, 100 * gigabyte,
    ]

    private static let thresholdPresets: [Int64] = [
        100 * megabyte, 250 * megabyte, 500 * megabyte, 2 * gigabyte, 5 * gigabyte,
    ]

    // BackupText.bytes counts in powers of 1,000, so the
    // presets do too, or "1 GB" reads "1,07 GB".
    fileprivate static let megabyte: Int64 = 1_000_000
    fileprivate static let gigabyte: Int64 = 1_000_000_000

    // MARK: - Pending deletions and the sweep

    @ViewBuilder private func cleanupSection(_ item: BackupTargetItem) -> some View {
        if item.pendingDeletions > 0 {
            Section {
                let count =
                    item.pendingDeletions == 1
                    ? String(localized: "1 old backup")
                    : String(localized: "\(item.pendingDeletions) old backups")
                Text("\(count) waiting to be deleted")
                Button("Back up and delete them now") { model.backUpNow() }
            } footer: {
                Text("Empo deletes old backups during the next backup.")
            }
        }
    }

    // MARK: - The namespace list and Remove

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

private struct SizeLimitPicker: View {

    let label: String
    let offLabel: String
    let presets: [Int64]
    let bytes: Int64?
    let set: (Int64?) -> Void

    @State private var isCustom = false
    @State private var typed = ""

    private static let gigabytes = FloatingPointFormatStyle<Double>.number.grouping(.never)
        .precision(.fractionLength(0...1))
    private var typedGigabytes: Double? { try? Double(typed, format: Self.gigabytes) }

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
                    guard let gigabytes = typedGigabytes, gigabytes > 0 else { return }
                    set(Int64(gigabytes * Double(TargetDetailScreen.gigabyte)))
                    isCustom = false
                }
                .disabled(typedGigabytes == nil)
            }
        }
    }

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
                    typed =
                        bytes.map {
                            (Double($0) / Double(TargetDetailScreen.gigabyte)).formatted(Self.gigabytes)
                        } ?? ""
                    isCustom = true
                }
            })
    }
}
