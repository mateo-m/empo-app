import Foundation

/// The `(org, app)` pair OLD Empo engine builds fed to
/// `SDL_GetPrefPath`, which placed every game's data directory
/// under Application Support. `SaveMigration` recomputes it to
/// find those directories and funnel their saves forward.
///
/// Deliberately NOT sanitized and NOT `"."`-suppressed: the legacy
/// engine passed the raw strings to SDL, which sanitizes nothing,
/// so the on-disk legacy layout literally contains an org
/// directory named `.` when no org was declared. Reproducing the
/// old bug-for-bug behavior is the whole point - a "better" pair
/// here looks in the wrong place and silently reports "no legacy
/// saves".
public enum LegacyDataPathDefaults {

    public static func resolve(
        declaredOrg: String?,
        declaredApp: String?,
        iniTitle: String?
    ) -> (org: String, app: String) {
        let org = normalized(declaredOrg) ?? "."
        let app = normalized(declaredApp) ?? normalized(iniTitle) ?? "mkxp-z"
        return (org, app)
    }

    private static func normalized(_ value: String?) -> String? {
        guard
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
