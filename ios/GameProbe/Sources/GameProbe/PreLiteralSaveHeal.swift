import Foundation

/// Undo for the engine's alias-era migration defect (v0.5.0 to
/// v0.6.0 on devices): the recovery in `platform_compat.rb`
/// compared the data directory to the cwd by path STRING, iOS
/// spells the same directory both `/var/...` and
/// `/private/var/...`, and the guard therefore never matched on a
/// real device. Every save-folder enumeration then "migrated"
/// each save onto itself, which renamed it to
/// `<name>.pre-literal.bak` - and chained one more layer per
/// enumeration, because `.bak` names counted as saves too.
///
/// This heal reverses the damage. Per directory:
///
///   - A FAMILY is every entry whose name ends in one or more
///     pre-literal layers (`.pre-literal.bak` or
///     `.pre-literal-N.bak`), keyed by the base name with all
///     layers stripped.
///   - A family whose base name exists on disk is left alone. A
///     bare file is newer than every chain member by
///     construction (chains only ever grew by renaming the bare
///     file away), and the heal never overwrites player data.
///   - Otherwise exactly one member is renamed to the base name:
///     newest modification time wins (renames never touch mtime,
///     so mtime is true content age); ties go to the FEWEST
///     layers (a member with fewer layers joined the chain
///     later); remaining ties break lexicographically.
///   - Every other member stays on disk untouched, as a
///     Files-visible manual override.
///
/// Content is deliberately NOT validated: chained names are not
/// all Ruby Marshal saves (`config.ini.bak` chained too, because
/// the engine treated every `.bak` as save-shaped). The heal
/// undoes rename damage; it does not judge file contents.
public enum PreLiteralSaveHeal {

    /// One chain layer at the end of a name: `.pre-literal.bak`
    /// or the collision-unique `.pre-literal-N.bak`.
    private static let layerSuffixPattern = "\\.pre-literal(-[0-9]+)?\\.bak$"

    public struct Candidate: Equatable, Sendable {
        public let name: String
        public let modificationDate: Date
        public let layerCount: Int

        public init(name: String, modificationDate: Date, layerCount: Int) {
            self.name = name
            self.modificationDate = modificationDate
            self.layerCount = layerCount
        }
    }

    public struct Outcome: Equatable, Sendable {
        /// Base names that got a member promoted back.
        public var promoted: [String] = []
        /// Chained names whose promotion rename failed; they stay
        /// on disk under the chained name and the next launch
        /// retries.
        public var failures: [String] = []

        public init() {}

        public var isEmpty: Bool { promoted.isEmpty && failures.isEmpty }
    }

    /// `"Game.rxdata.pre-literal.bak.pre-literal-2.bak"` ->
    /// `("Game.rxdata", 2)`. Nil when the name carries no layer.
    public static func familyBase(of name: String) -> (base: String, layers: Int)? {
        var base = name
        var layers = 0
        while let range = base.range(
            of: layerSuffixPattern, options: .regularExpression)
        {
            base.removeSubrange(range)
            layers += 1
        }
        guard layers > 0, !base.isEmpty else { return nil }
        return (base, layers)
    }

    /// The member the policy promotes: newest mtime, then fewest
    /// layers, then lexicographically first.
    public static func promotion(among candidates: [Candidate]) -> Candidate? {
        candidates.min { lhs, rhs in
            if lhs.modificationDate != rhs.modificationDate {
                return lhs.modificationDate > rhs.modificationDate
            }
            if lhs.layerCount != rhs.layerCount {
                return lhs.layerCount < rhs.layerCount
            }
            return lhs.name < rhs.name
        }
    }

    /// Heal one directory (its root entries only - the engine
    /// migration only ever renamed root entries).
    @discardableResult
    public static func heal(directory: URL, fm: FileManager = .default) -> Outcome {
        var outcome = Outcome()
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return outcome
        }

        var families: [String: [Candidate]] = [:]
        for name in names {
            guard let (base, layers) = familyBase(of: name) else { continue }
            let url = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
                !isDirectory.boolValue
            else { continue }
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let date = (attrs?[.modificationDate] as? Date) ?? .distantPast
            families[base, default: []].append(
                Candidate(name: name, modificationDate: date, layerCount: layers))
        }

        for (base, candidates) in families.sorted(by: { $0.key < $1.key }) {
            let baseURL = directory.appendingPathComponent(base)
            guard !fm.fileExists(atPath: baseURL.path) else { continue }
            guard let winner = promotion(among: candidates) else { continue }
            do {
                try fm.moveItem(
                    at: directory.appendingPathComponent(winner.name),
                    to: baseURL
                )
                outcome.promoted.append(base)
            } catch {
                outcome.failures.append(winner.name)
            }
        }
        return outcome
    }

    /// Heal `root` and every directory below it. The damage only
    /// exists at data-directory roots, but data directories nest
    /// under `Data/<org>/<app>` at varying depth, so the walk is
    /// the simplest correct scope. Healing an unaffected
    /// directory is a no-op.
    @discardableResult
    public static func healTree(at root: URL, fm: FileManager = .default) -> Outcome {
        var outcome = heal(directory: root, fm: fm)
        for name in fm.subdirectoryNames(at: root).sorted() {
            let child = healTree(
                at: root.appendingPathComponent(name, isDirectory: true), fm: fm)
            outcome.promoted.append(contentsOf: child.promoted)
            outcome.failures.append(contentsOf: child.failures)
        }
        return outcome
    }
}
