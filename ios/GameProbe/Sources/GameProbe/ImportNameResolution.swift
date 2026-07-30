import Foundation

/// Pure collision policy for import planning: given a game title
/// and the current library state, decide whether the import is a
/// fresh install, an in-place update, or a refusal. The app-side
/// `planImports` maps outcomes to plans and user-facing alerts.
///
/// The library invariant is one container per title - some games
/// derive their data locations from the title in their INI, so a
/// suffixed duplicate (`Testing 2`) would still call itself
/// "Testing" and read the other copy's data. Suffixed names are
/// therefore never produced; every collision resolves to an update
/// or a refusal.
public enum ImportNameResolution {

    public struct Context: Sendable {
        /// Installed container names keyed by lowercased name.
        public let installedNamesByKey: [String: String]
        /// Lowercased names of imports currently in flight.
        public let inFlightKeys: Set<String>
        /// Folder name of the currently open (playing/paused) game.
        public let openGameName: String?

        public init(
            installedFolderNames: [String],
            inFlightNames: [String],
            openGameName: String?
        ) {
            self.installedNamesByKey = Dictionary(
                installedFolderNames.map { ($0.lowercased(), $0) },
                uniquingKeysWith: { first, _ in first }
            )
            self.inFlightKeys = Set(inFlightNames.map { $0.lowercased() })
            self.openGameName = openGameName
        }
    }

    public enum Outcome: Equatable, Sendable {
        case fresh(folderName: String)
        case update(installedFolderName: String)
        case refusedInFlight
        case refusedDuplicateInBatch
        case refusedOpenGame
    }

    /// Resolve one selection. `reservedBatchKeys` carries the
    /// lowercased names claimed by earlier selections in the same
    /// batch; accepted outcomes (fresh/update) reserve their name,
    /// refusals don't.
    public static func resolve(
        title: String,
        context: Context,
        reservedBatchKeys: inout Set<String>
    ) -> Outcome {
        let preferred = GameFolderName.sanitize(title)
        let key = preferred.lowercased()

        if context.inFlightKeys.contains(key) {
            return .refusedInFlight
        }

        if !reservedBatchKeys.contains(key),
            let installed = context.installedNamesByKey[key]
        {
            if installed == context.openGameName {
                return .refusedOpenGame
            }
            reservedBatchKeys.insert(key)
            return .update(installedFolderName: installed)
        }

        if reservedBatchKeys.contains(key) {
            return .refusedDuplicateInBatch
        }

        reservedBatchKeys.insert(key)
        return .fresh(folderName: preferred)
    }
}
