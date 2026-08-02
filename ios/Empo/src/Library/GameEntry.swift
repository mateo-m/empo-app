import Foundation
import Observation

enum GameStatus: Hashable, Sendable {
    case ready
    case importing
    /// A delete is running (save rescue + removal). The card stays
    /// in place, inert, until the delete finishes or fails.
    case deleting
    case invalid
}

/// Value-type result of a catalog scan pass. Scans run off the main
/// actor, so they produce these Sendable snapshots; the main actor
/// merges them into existing `GameEntry` models via
/// `GameEntry.apply(_:)` (or creates new models for newcomers).
struct GameSnapshot: Sendable {
    let id: String
    let container: GameContainer?
    let title: String
    let artworkPath: String?
    var engineTitle: String?
    var lastPlayed: Date?
    var dateAdded: Date?
    var totalPlayTime: TimeInterval?
    var status: GameStatus = .ready
}

/// Reference model for one library entry.
///
/// `@Observable` reference semantics are the point of this type:
/// Observation tracks which *properties* each view body reads, so a
/// card that reads `importProgress` re-renders on every progress
/// tick while the library container view — which reads membership
/// and the sortable fields — is untouched. The previous design (a
/// value struct inside `GameLibrary.games`) meant every per-entry
/// mutation replaced an array element, which invalidated the whole
/// library body dozens of times per second mid-import.
///
/// All mutations happen on the main actor (they drive UI directly).
/// Off-main code communicates through `GameSnapshot` values.
@Observable
final class GameEntry: Identifiable {
    /// Bare UUID (matches `container?.id`). Stable across renames
    /// of the on-disk folder. Synthetic entries (in-flight imports
    /// without a committed folder yet) keep their id but have no
    /// `container`.
    let id: String

    /// `Documents/Games/<title>/` for ready entries.
    /// nil during pre-flight validation when nothing is on disk
    /// yet (the synthetic placeholder entry shown in the grid).
    var container: GameContainer?

    var title: String  // display title (custom override or base)
    var artworkPath: String?  // resolved artwork path
    // The engine's own title for the game (parsed from Game.ini),
    // surfaced on the library card alongside `title` when they
    // differ. Non-nil only when a user-set customTitle or a JGP
    // manifest name overrides the display title. nil means `title`
    // IS the engine title.
    var engineTitle: String?
    var lastPlayed: Date?  // from metadata, cached at scan time
    var dateAdded: Date?  // from metadata, cached at scan time
    // Cached at scan time like the dates above so the most/least
    // played sorts never touch disk.
    var totalPlayTime: TimeInterval?
    var status: GameStatus

    /// Extraction progress for `.importing` entries, 0...1. Lives
    /// outside `status` on purpose: it changes many times per second
    /// mid-import, and only the card's `GameStatusIndicator` subtree
    /// reads it. Folding it into `status` (the old design) meant
    /// every tick invalidated everything that reads status,
    /// including the library body via its animation keys.
    var importProgress: Double = 0

    /// Bumped when artwork *bytes* change under an unchanged
    /// `artworkPath` (the exe-icon sidecar is overwritten in place
    /// when a better icon surfaces mid-import). `GameArtworkView`
    /// folds it into its load-task identity, so a bump is what
    /// forces the reload that a stable path string can't signal.
    var artworkRevision: Int = 0

    /// Set when this session watches the entry finish an import
    /// (importing -> ready in `apply`). Drives the one-shot shimmer
    /// on the library artwork; the shimmer's completion clears it.
    /// Session-only by design - a relaunch shows no shimmer.
    var justImported = false

    init(
        id: String,
        container: GameContainer?,
        title: String,
        artworkPath: String?,
        engineTitle: String? = nil,
        lastPlayed: Date? = nil,
        dateAdded: Date? = nil,
        totalPlayTime: TimeInterval? = nil,
        status: GameStatus = .ready
    ) {
        self.id = id
        self.container = container
        self.title = title
        self.artworkPath = artworkPath
        self.engineTitle = engineTitle
        self.lastPlayed = lastPlayed
        self.dateAdded = dateAdded
        self.totalPlayTime = totalPlayTime
        self.status = status
    }

    convenience init(_ snapshot: GameSnapshot) {
        self.init(
            id: snapshot.id,
            container: snapshot.container,
            title: snapshot.title,
            artworkPath: snapshot.artworkPath,
            engineTitle: snapshot.engineTitle,
            lastPlayed: snapshot.lastPlayed,
            dateAdded: snapshot.dateAdded,
            totalPlayTime: snapshot.totalPlayTime,
            status: snapshot.status
        )
    }

    /// Merge a scan snapshot into this model. Every assignment is
    /// guarded: `@Observable` setters notify observers even when the
    /// new value equals the old one, so unconditional assignment
    /// would invalidate every dependent view on every scan pass.
    ///
    /// `preservingStatus` keeps the in-memory status (used by
    /// refreshes that only want metadata fields updated, e.g. after
    /// a title edit while the entry's status must not regress).
    func apply(_ snapshot: GameSnapshot, preservingStatus: Bool = false) {
        assert(snapshot.id == id, "applying snapshot for a different game")
        if container != snapshot.container { container = snapshot.container }
        if title != snapshot.title { title = snapshot.title }
        if artworkPath != snapshot.artworkPath { artworkPath = snapshot.artworkPath }
        if engineTitle != snapshot.engineTitle { engineTitle = snapshot.engineTitle }
        if lastPlayed != snapshot.lastPlayed { lastPlayed = snapshot.lastPlayed }
        if dateAdded != snapshot.dateAdded { dateAdded = snapshot.dateAdded }
        if totalPlayTime != snapshot.totalPlayTime { totalPlayTime = snapshot.totalPlayTime }
        if !preservingStatus && status != snapshot.status {
            if status == .importing && snapshot.status == .ready { justImported = true }
            status = snapshot.status
        }
    }

    /// Where the game's own files live. `<container>/Game/`. Empty
    /// string for synthetic in-flight imports without a committed
    /// folder.
    var path: String {
        container?.gameURL.path ?? ""
    }

    var isImporting: Bool {
        status == .importing
    }

    var isDeleting: Bool {
        status == .deleting
    }
}

/// Identity for navigation and diffing is the stable `id`; two live
/// models never share an id (the library holds one model per
/// container), so id equality is object identity in practice.
extension GameEntry: Hashable {
    static func == (lhs: GameEntry, rhs: GameEntry) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
