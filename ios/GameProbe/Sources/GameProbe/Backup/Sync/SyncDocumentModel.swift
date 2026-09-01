import Foundation

/// The sync document of SPEC 10.3, as plain values.
///
/// Automerge holds the live document, and that half lives in the
/// app, because the Automerge core ships for Apple platforms alone.
/// This is the shape both halves agree on. The app maps every field
/// here into the Automerge document one leaf at a time, so two
/// devices that change different keys, bindings, profiles, or
/// controls never collide.
public struct SyncDocumentModel: Equatable, Sendable {

    public var schemaVersion: Int
    public var minimumWriterVersion: Int
    /// The portable preferences of 10.1, by key.
    public var preferences: [String: JSONValue]
    /// The global controller overrides, by binding id.
    public var controllerBindings: [String: JSONValue]
    public var layoutProfiles: [String: SyncProfile]
    /// The shared descriptors of 10.8, by target id. None carries a
    /// secret or an account hint.
    public var targetDescriptors: [String: TargetDescriptor]

    public init(
        schemaVersion: Int = SyncSchema.currentVersion,
        minimumWriterVersion: Int = SyncSchema.minimumWriterVersion,
        preferences: [String: JSONValue] = [:],
        controllerBindings: [String: JSONValue] = [:],
        layoutProfiles: [String: SyncProfile] = [:],
        targetDescriptors: [String: TargetDescriptor] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.minimumWriterVersion = minimumWriterVersion
        self.preferences = preferences
        self.controllerBindings = controllerBindings
        self.layoutProfiles = layoutProfiles
        self.targetDescriptors = targetDescriptors
    }

    /// The profiles a device shows, which leaves out every deleted
    /// one.
    public var liveProfiles: [String: SyncProfile] {
        layoutProfiles.filter { $0.value.deletedAt == nil }
    }

    /// This device's values over the merged document, per 10.5 step
    /// 4.
    ///
    /// A leaf this device does not hold stays as the group left it.
    /// "Not set here" is not a delete: a device that never set a
    /// preference must not clear it for everyone. A delete travels
    /// as its own record, which is what `deletedAt` is for.
    public func overlaid(with local: SyncDocumentModel) -> SyncDocumentModel {
        var out = self
        out.preferences.merge(local.preferences) { _, mine in mine }
        out.controllerBindings.merge(local.controllerBindings) { _, mine in mine }
        out.targetDescriptors.merge(local.targetDescriptors) { _, mine in mine }
        for (id, mine) in local.layoutProfiles {
            out.layoutProfiles[id] = merged(theirs: out.layoutProfiles[id], mine: mine)
        }
        return out
    }

    /// A deletion wins over a concurrent edit, per 10.6, whichever
    /// side holds it.
    private func merged(theirs: SyncProfile?, mine: SyncProfile) -> SyncProfile {
        guard let theirs else { return mine }
        if theirs.isDeleted { return theirs }
        guard let deleted = mine.deletedAt else { return mine }
        var out = theirs
        out.deletedAt = deleted
        return out
    }
}

/// One layout profile inside the document, per 10.3.
///
/// A profile keeps its entry after a delete. The deletion record is
/// what makes a deletion win over a concurrent offline edit, per
/// 10.6, and recreating the profile mints a new identity that the
/// old edit cannot reach.
public struct SyncProfile: Equatable, Sendable {

    public var name: String
    /// The touch controls, by control id. `TouchSectionSyncCoder`
    /// makes the ids.
    public var controls: [String: JSONValue]
    /// `screen.json` as one value, per 10.3.
    public var screen: JSONValue?
    public var deletedAt: Date?
    /// The one short origin note a conflict profile carries.
    public var origin: String?

    public init(
        name: String,
        controls: [String: JSONValue] = [:],
        screen: JSONValue? = nil,
        deletedAt: Date? = nil,
        origin: String? = nil
    ) {
        self.name = name
        self.controls = controls
        self.screen = screen
        self.deletedAt = deletedAt
        self.origin = origin
    }

    public var isDeleted: Bool { deletedAt != nil }
}

/// The schema versions of SPEC 10.10.
public enum SyncSchema {

    /// The schema this build writes.
    public static let currentVersion = 1

    /// The oldest build that may still write the document. An
    /// additive change leaves it alone. A breaking migration raises
    /// it.
    public static let minimumWriterVersion = 1

    /// This build's writer version, which a document compares
    /// against its own `minimumWriterVersion`.
    public static let writerVersion = 1

    /// Whether this build may publish changes to a document.
    ///
    /// An older build still reads the fields it knows. It stops
    /// writing until it updates, per 10.10.
    public static func canPublish(toDocumentRequiring minimum: Int) -> Bool {
        writerVersion >= minimum
    }
}
