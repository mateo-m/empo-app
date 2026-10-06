import Foundation

/// The layout-profile rules of SPEC 10.6.
///
/// Automerge picks the winner of a same-field conflict on its own,
/// and its answer is deterministic. Device wall time never selects a
/// winner. What Empo owns is what happens to the version that lost:
/// it becomes a profile of its own, so no edit disappears.
public enum SyncProfileConflict {

    /// `<profile name> from <device name>`, per 10.6.
    public static func name(of profileName: String, deviceName: String) -> String {
        "\(profileName) from \(deviceName)"
    }

    /// The one short origin note the conflict profile carries.
    public static func originNote(deviceName: String) -> String {
        "Empo kept this version from \(deviceName) after both devices changed the same control."
    }

    /// The losing version, rebuilt as an ordinary profile with its
    /// own identity. It joins the profile list beside the winner.
    ///
    /// Both devices of a conflict rebuild it, so the identity comes
    /// from the profile and the losing controls. Both mint the same
    /// one, and the document ends with one conflict profile and not
    /// two.
    public static func conflictProfile(
        id profileId: String, losing: SyncProfile, deviceName: String
    ) -> (id: String, profile: SyncProfile) {
        let profile = SyncProfile(
            name: name(of: losing.name, deviceName: deviceName),
            controls: losing.controls,
            screen: losing.screen,
            origin: originNote(deviceName: deviceName))
        return (makeId(profileId: profileId, losing: losing.controls), profile)
    }

    public static func makeId(profileId: String, losing: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let lines = losing.keys.sorted().map { key -> String in
            let value = (try? encoder.encode(losing[key])).flatMap { String(data: $0, encoding: .utf8) }
            return key + "=" + (value ?? "")
        }
        return String(
            ContentHash.hex(ofUTF8: ([profileId] + lines).joined(separator: "\n")).prefix(16))
    }

    /// A profile deletion wins over a concurrent offline edit.
    ///
    /// The deletion record stays in the document, so the edit cannot
    /// bring the profile back. A device that wants the profile again
    /// creates it, and that mints a new identity.
    public static func merge(_ left: SyncProfile, _ right: SyncProfile) -> SyncProfile {
        switch (left.deletedAt, right.deletedAt) {
        case (nil, nil): return left
        case (let deleted?, nil): return withDeletion(left, at: deleted)
        case (nil, let deleted?): return withDeletion(right, at: deleted)
        case (let leftDeleted?, let rightDeleted?):
            return withDeletion(left, at: min(leftDeleted, rightDeleted))
        }
    }

    private static func withDeletion(_ profile: SyncProfile, at date: Date) -> SyncProfile {
        var copy = profile
        copy.deletedAt = date
        return copy
    }
}
