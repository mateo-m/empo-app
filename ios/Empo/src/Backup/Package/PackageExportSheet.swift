import GameProbe
import SwiftUI
import UIKit

/// What an export covers, per SPEC 12.4.
enum PackageExportSource {
    case game(GameContainer)
    case library

    @MainActor
    func plan() async throws -> PackagePlan {
        switch self {
        case .game(let container): return try await PackageExport.plan(game: container)
        case .library: return try await PackageExport.libraryPlan()
        }
    }
}

/// The build of one package and the save that follows it, per SPEC
/// 12.5.
@MainActor
@Observable
final class PackageExportModel {

    enum Phase: Equatable {
        case planning
        case building
        /// The picker is open.
        case saving
        /// Files reported no save, so the choice of 12.5 is up.
        case choosing
        case failed(String)
        case done
    }

    private(set) var phase: Phase = .planning
    private(set) var progress = PackageBuildProgress()
    private(set) var record: PackageRecord?

    private var task: Task<Void, Never>?
    private let localRoot = BackupRoot.layout.root

    /// Picks up a package a launch found waiting for its save.
    init(waiting record: PackageRecord? = nil) {
        guard let record else { return }
        self.record = record
        phase = .choosing
    }

    func start(_ source: PackageExportSource) {
        guard case .planning = phase, task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            let plan: PackagePlan
            do {
                plan = try await source.plan()
            } catch let unread as PackageExport.SettingsUnread {
                phase = .failed(
                    String(
                        localized:
                            "Empo couldn't read what \(unread.gameName) backs up. Open the game's settings, tap Backup, and choose what gets backed up again."
                    ))
                return
            } catch {
                BackupLog.line("PackageExportModel", "The package plan failed: \(error)")
                phase = .failed(String(localized: "Empo couldn't make this package. Try again."))
                return
            }
            guard !Task.isCancelled else { return }
            guard !plan.streams.isEmpty else {
                phase = .failed(String(localized: "This device holds nothing to export."))
                return
            }
            phase = .building
            progress = PackageBuildProgress(
                totalFileCount: plan.fileCount, totalBytes: plan.sourceBytes)
            await build(plan)
        }
    }

    private func build(_ plan: PackagePlan) async {
        let localRoot = localRoot
        let device = UIDevice.current.name
        let freeSpaceBytes = BackupRoot.freeSpaceBytes
        do {
            let show: @MainActor @Sendable (PackageBuildProgress) -> Void = { [weak self] value in
                self?.progress = value
            }
            let job = Task.detached(priority: .userInitiated) {
                try plan.build(
                    localRoot: localRoot,
                    sourceDevice: device,
                    freeSpaceBytes: freeSpaceBytes
                ) { value in
                    Task { await show(value) }
                }
            }
            // A detached task does not inherit the cancel of `task`,
            // so Cancel has to reach the build by hand.
            let built = try await withTaskCancellationHandler {
                try await job.value
            } onCancel: {
                job.cancel()
            }
            // A build that ended as Cancel came in keeps no ZIP.
            guard !Task.isCancelled else {
                built.delete(localRoot: localRoot)
                return
            }
            record = built
            phase = .saving
        } catch {
            // Cancel already set `.done`, and a failure that the cancel
            // caused must not open the sheet again.
            guard !Task.isCancelled else { return }
            switch error {
            case PackageBuildFailure.notEnoughSpace(let shortfall):
                phase = .failed(PackageDoors.shortfallLine(BackupText.bytes(shortfall)))
            case PackageBuildFailure.cancelled:
                phase = .done
            default:
                phase = .failed(String(localized: "Empo couldn't make this package. Try again."))
            }
        }
    }

    /// Cancelling the build deletes the partial ZIP, per 12.5. The
    /// build itself does the delete, because it holds the writer.
    func cancelTheBuild() {
        task?.cancel()
        phase = .done
    }

    /// Files owns the copy now, and Empo keeps no second one.
    func saved() {
        record?.delete(localRoot: localRoot)
        phase = .done
    }

    func notSaved() {
        phase = .choosing
    }

    func answer(_ choice: PackageSaveChoice) {
        switch choice {
        case .saveAgain:
            phase = .saving
        case .delete:
            record?.delete(localRoot: localRoot)
            phase = .done
        }
    }

    var line: String {
        let done = BackupText.bytes(progress.bytes)
        let total = BackupText.bytes(progress.totalBytes)
        return String(
            localized: "\(progress.fileCount) of \(progress.totalFileCount) files, \(done) of \(total)")
    }
}

/// The build progress sheet of SPEC 12.5, and the save that follows.
struct PackageExportSheet: View {

    let source: PackageExportSource
    @State var model = PackageExportModel()

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        StandardSheet(
            title: "Export backup",
            barAction: SheetBarAction("Cancel") { model.cancelTheBuild() }
        ) {
            switch model.phase {
            case .planning, .building:
                SheetBodyText(model.line)
                ProgressView(value: model.progress.fraction)
                    .progressViewStyle(.linear)
                SheetFootnote(
                    "Empo builds the file first. Files asks where to put it after that.")
            case .saving:
                ProgressView()
            case .choosing:
                choice
            case .failed(let message):
                SheetBodyText(message)
                SheetPrimaryButton("Done") { dismiss() }
            case .done:
                ProgressView()
            }
        }
        .task { model.start(source) }
        .onChange(of: model.phase) { _, phase in
            if phase == .done { dismiss() }
        }
        .sheet(
            isPresented: Binding(
                get: { model.phase == .saving },
                set: { isPresented in
                    if !isPresented, model.phase == .saving { model.notSaved() }
                })
        ) {
            if let record = model.record {
                PackageExportPicker(file: record.zipURL(localRoot: BackupRoot.layout.root)) { saved in
                    if saved {
                        model.saved()
                    } else {
                        model.notSaved()
                    }
                }
            }
        }
    }

    /// The Save again and Delete choice of 12.5.
    @ViewBuilder private var choice: some View {
        SheetBodyText(PackageSaveChoice.question(fileName: model.record?.fileName ?? ""))
        SheetPrimaryButton(PackageSaveChoice.saveAgain.label) {
            model.answer(.saveAgain)
        }
        SheetDestructiveButton(PackageSaveChoice.delete.label) {
            model.answer(.delete)
        }
    }
}
