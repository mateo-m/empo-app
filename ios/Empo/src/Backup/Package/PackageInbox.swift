import GameProbe
import SwiftUI

/// One package file Files handed to Empo.
struct PickedPackage: Identifiable, Equatable {
    let url: URL
    var id: String { url.absoluteString }
}

/// Where a ZIP that Files opened waits for the import of SPEC 12.6.
///
/// Empo registers ZIP import, so "Open in Empo" on a package starts
/// the same flow the Import backup button starts. A ZIP that carries
/// no Empo manifest fails the check and says so.
@MainActor
@Observable
final class PackageInbox {

    static let shared = PackageInbox()

    private init() {}

    var pending: PickedPackage?

    /// Takes the URL where it names a ZIP file, and answers whether
    /// it took it.
    func accept(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "zip" else { return false }
        pending = PickedPackage(url: url)
        return true
    }
}

/// Shows the import sheet for a package Files opened.
struct PackageImportPresentation: ViewModifier {

    @State private var inbox = PackageInbox.shared

    func body(content: Content) -> some View {
        content.sheet(item: $inbox.pending) { picked in
            // Import is closed while a game runs, per 7.6.
            if PackageDoors.opens(gameIsPlaying: BackupDeviceConditions.isSessionLive) {
                PackageImportSheet(picked: picked.url)
            } else {
                PackageDoorClosedSheet()
            }
        }
    }
}

/// What both doors of 12.5 say while a game runs, per 7.6.
struct PackageDoorClosedSheet: View {

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        StandardSheet(
            title: "Import backup",
            trailingButton: SheetBarAction("Done") { dismiss() }
        ) {
            SheetBodyText(
                PackageDoors.line(gameName: EngineSessionCoordinator.shared.openGameName)
                    ?? "Close the game to import a backup.")
        }
    }
}
