import GameProbe
import SwiftUI
import UIKit

/// What an export covers, per SPEC 12.4.
enum PackageExportSource {
    case game(GameContainer)
    case library

    @MainActor
    func plan() async -> PackageExport.Plan {
        switch self {
        case .game(let container): return await PackageExport.plan(game: container)
        case .library: return await PackageExport.libraryPlan()
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
    private let localRoot = BackupRoot.url

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
            let plan = await source.plan()
            guard !plan.streams.isEmpty else {
                phase = .failed("This device holds nothing to export.")
                return
            }
            phase = .building
            progress = PackageBuildProgress(
                totalFileCount: plan.fileCount, totalBytes: plan.sourceBytes)
            await build(plan)
        }
    }

    private func build(_ plan: PackageExport.Plan) async {
        let localRoot = localRoot
        let device = UIDevice.current.name
        let freeSpaceBytes = Self.freeSpaceBytes
        do {
            let built = try await Task.detached(priority: .userInitiated) { [weak self] in
                try PackageExport.build(
                    plan,
                    localRoot: localRoot,
                    sourceDevice: device,
                    freeSpaceBytes: freeSpaceBytes
                ) { value in
                    Task { @MainActor in self?.progress = value }
                }
            }.value
            record = built
            phase = .saving
        } catch PackageBuildFailure.notEnoughSpace(let shortfall) {
            phase = .failed(PackageDoors.shortfallLine(BackupText.bytes(shortfall)))
        } catch PackageBuildFailure.cancelled {
            phase = .done
        } catch {
            phase = .failed("Empo could not build this package.")
        }
    }

    /// Cancelling the build deletes the partial ZIP, per 12.5. The
    /// build itself does the delete, because it holds the writer.
    func cancelTheBuild() {
        task?.cancel()
        phase = .done
    }

    func saved() {
        record?.markSaved(localRoot: localRoot)
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
        "\(progress.fileCount) of \(progress.totalFileCount) files, "
            + "\(BackupText.bytes(progress.bytes)) of \(BackupText.bytes(progress.totalBytes))"
    }

    private static var freeSpaceBytes: Int64 {
        let values = try? BackupRoot.url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
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
            trailingButton: SheetBarAction("Cancel") { model.cancelTheBuild() }
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
        .sheet(isPresented: .constant(model.phase == .saving)) {
            if let record = model.record {
                PackageExportPicker(file: record.zipURL(localRoot: BackupRoot.url)) { saved in
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
        Button(PackageSaveChoice.delete.label, role: .destructive) {
            model.answer(.delete)
        }
        .buttonStyle(SecondaryButtonStyle(tint: .red))
    }
}
