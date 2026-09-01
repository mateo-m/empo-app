import Automerge
import Foundation
import GameProbe

/// The Automerge half of the sync document of SPEC 10.3.
///
/// `SyncDocumentModel` in GameProbe holds the shape. This file maps
/// it into an Automerge document one leaf at a time, and reads it
/// back. A write touches only the leaves that changed, so two
/// devices that edit different keys produce changes that merge with
/// no conflict at all.
///
/// A leaf carries JSON text, because a preference value has no fixed
/// type. The leaf is still the unit 10.3 names, so Automerge picks
/// the winner per key and not per document.
enum SyncDocument {

    enum Key {
        static let schemaVersion = "schemaVersion"
        static let minimumWriterVersion = "minimumWriterVersion"
        static let preferences = "preferences"
        static let controllerBindings = "controllerBindings"
        static let layoutProfiles = "layoutProfiles"
        static let targetDescriptors = "targetDescriptors"
        static let name = "name"
        static let controls = "controls"
        static let screen = "screen"
        static let deletedAt = "deletedAt"
        static let origin = "origin"
    }

    static func make(actorId: String) -> Document {
        let document = Document()
        setActor(actorId, on: document)
        return document
    }

    static func open(_ bytes: Data, actorId: String) throws -> Document {
        let document = try Document(bytes)
        setActor(actorId, on: document)
        return document
    }

    private static func setActor(_ actorId: String, on document: Document) {
        guard let uuid = UUID(uuidString: actorId) else { return }
        document.actor = ActorId(uuid: uuid)
    }

    /// The heads of 10.5 step 6, as text a state file can hold.
    static func heads(of document: Document) -> [String] {
        document.heads().map(\.debugDescription).sorted()
    }

    // MARK: - Reading

    static func model(of document: Document) throws -> SyncDocumentModel {
        var model = SyncDocumentModel(
            schemaVersion: try int(document, .ROOT, Key.schemaVersion) ?? SyncSchema.currentVersion,
            minimumWriterVersion: try int(document, .ROOT, Key.minimumWriterVersion)
                ?? SyncSchema.minimumWriterVersion)
        if let map = try mapId(document, .ROOT, Key.preferences) {
            model.preferences = try values(document, map)
        }
        if let map = try mapId(document, .ROOT, Key.controllerBindings) {
            model.controllerBindings = try values(document, map)
        }
        if let map = try mapId(document, .ROOT, Key.layoutProfiles) {
            for (id, value) in try document.mapEntries(obj: map) {
                guard case .Object(let entry, .Map) = value else { continue }
                model.layoutProfiles[id] = try profile(document, entry)
            }
        }
        if let map = try mapId(document, .ROOT, Key.targetDescriptors) {
            for (id, value) in try document.mapEntries(obj: map) {
                guard case .Object(let entry, .Map) = value else { continue }
                model.targetDescriptors[id] = try descriptor(document, entry, id: id)
            }
        }
        return model
    }

    private static func profile(_ document: Document, _ entry: ObjId) throws -> SyncProfile {
        var profile = SyncProfile(name: try text(document, entry, Key.name) ?? "")
        if let controls = try mapId(document, entry, Key.controls) {
            profile.controls = try values(document, controls)
        }
        profile.screen = try text(document, entry, Key.screen).flatMap(json(of:))
        profile.deletedAt = try date(document, entry, Key.deletedAt)
        profile.origin = try text(document, entry, Key.origin)
        return profile
    }

    private static func descriptor(
        _ document: Document, _ entry: ObjId, id: String
    ) throws -> TargetDescriptor? {
        guard
            let provider = try text(document, entry, "provider").flatMap(
                BackupProviderKind.init(rawValue:))
        else { return nil }
        return TargetDescriptor(
            id: id,
            provider: provider,
            label: try text(document, entry, "label") ?? "",
            root: try text(document, entry, "root") ?? "",
            sizeThresholdBytes: try int(document, entry, "sizeThresholdBytes").map(Int64.init),
            capBytes: try int(document, entry, "capBytes").map(Int64.init),
            isPaused: try flag(document, entry, "isPaused") ?? false)
    }

    /// The control leaves the merge left with more than one value,
    /// per 10.6, mapped to the value Automerge did not pick.
    ///
    /// The losing value is the one that sorts first among the values
    /// that are not the winner, so two devices read the same loser
    /// from the same document.
    static func losingControls(
        of document: Document, profileId: String
    ) throws
        -> [String: JSONValue]
    {
        guard let map = try mapId(document, .ROOT, Key.layoutProfiles),
            let entry = try mapId(document, map, profileId),
            let controls = try mapId(document, entry, Key.controls)
        else { return [:] }

        var out: [String: JSONValue] = [:]
        for (key, winner) in try document.mapEntries(obj: controls) {
            guard case .Scalar(.String(let winning)) = winner else { continue }
            let all = try document.getAll(obj: controls, key: key)
            guard all.count > 1 else { continue }
            let texts = all.compactMap { value -> String? in
                guard case .Scalar(.String(let text)) = value else { return nil }
                return text
            }
            guard let losing = texts.sorted().first(where: { $0 != winning }),
                let parsed = json(of: losing)
            else { continue }
            out[key] = parsed
        }
        return out
    }

    /// Writes the winner of each leaf back, which is how Automerge
    /// resolves a conflict. Without it the same conflict answers
    /// every later pass, and the pass rebuilds the same profile
    /// again and again.
    static func resolveControls(of document: Document, profileId: String, keys: [String]) throws {
        guard let map = try mapId(document, .ROOT, Key.layoutProfiles),
            let entry = try mapId(document, map, profileId),
            let controls = try mapId(document, entry, Key.controls)
        else { return }
        for key in keys {
            guard case .Scalar(.String(let winning)) = try document.get(obj: controls, key: key)
            else { continue }
            try document.put(obj: controls, key: key, value: .String(winning))
        }
    }

    // MARK: - Writing

    /// Applies a model, leaf by leaf. Only a leaf whose value moved
    /// takes a change, so a pass that finds nothing new writes
    /// nothing at all.
    static func write(_ model: SyncDocumentModel, to document: Document) throws {
        let before = try Self.model(of: document)
        if before.schemaVersion != model.schemaVersion {
            try document.put(
                obj: .ROOT, key: Key.schemaVersion, value: .Int(Int64(model.schemaVersion)))
        }
        if before.minimumWriterVersion != model.minimumWriterVersion {
            try document.put(
                obj: .ROOT, key: Key.minimumWriterVersion,
                value: .Int(Int64(model.minimumWriterVersion)))
        }

        try writeValues(
            model.preferences, was: before.preferences,
            into: try makeMap(document, .ROOT, Key.preferences), document)
        try writeValues(
            model.controllerBindings, was: before.controllerBindings,
            into: try makeMap(document, .ROOT, Key.controllerBindings), document)
        try writeProfiles(model.layoutProfiles, was: before.layoutProfiles, document)
        try writeDescriptors(model.targetDescriptors, was: before.targetDescriptors, document)
    }

    private static func writeValues(
        _ values: [String: JSONValue], was: [String: JSONValue], into map: ObjId,
        _ document: Document
    ) throws {
        for (key, value) in values where was[key] != value {
            try document.put(obj: map, key: key, value: .String(try text(of: value)))
        }
        for key in was.keys where values[key] == nil {
            try document.delete(obj: map, key: key)
        }
    }

    private static func writeProfiles(
        _ profiles: [String: SyncProfile], was: [String: SyncProfile], _ document: Document
    ) throws {
        let map = try makeMap(document, .ROOT, Key.layoutProfiles)
        for (id, profile) in profiles where was[id] != profile {
            let entry = try makeMap(document, map, id)
            let old = was[id]
            if old?.name != profile.name {
                try document.put(obj: entry, key: Key.name, value: .String(profile.name))
            }
            try writeValues(
                profile.controls, was: old?.controls ?? [:],
                into: try makeMap(document, entry, Key.controls), document)
            if old?.screen != profile.screen {
                try put(document, entry, Key.screen, profile.screen.flatMap { try? text(of: $0) })
            }
            if old?.deletedAt != profile.deletedAt {
                try document.put(
                    obj: entry, key: Key.deletedAt,
                    value: profile.deletedAt.map(ScalarValue.Timestamp) ?? .Null)
            }
            if old?.origin != profile.origin {
                try put(document, entry, Key.origin, profile.origin)
            }
        }
        for id in was.keys where profiles[id] == nil {
            try document.delete(obj: map, key: id)
        }
    }

    private static func writeDescriptors(
        _ descriptors: [String: TargetDescriptor], was: [String: TargetDescriptor],
        _ document: Document
    ) throws {
        let map = try makeMap(document, .ROOT, Key.targetDescriptors)
        for (id, descriptor) in descriptors where was[id] != descriptor {
            let entry = try makeMap(document, map, id)
            let old = was[id]
            if old?.provider != descriptor.provider {
                try document.put(
                    obj: entry, key: "provider", value: .String(descriptor.provider.rawValue))
            }
            if old?.label != descriptor.label {
                try document.put(obj: entry, key: "label", value: .String(descriptor.label))
            }
            if old?.root != descriptor.root {
                try document.put(obj: entry, key: "root", value: .String(descriptor.root))
            }
            if old?.sizeThresholdBytes != descriptor.sizeThresholdBytes {
                try document.put(
                    obj: entry, key: "sizeThresholdBytes",
                    value: descriptor.sizeThresholdBytes.map { ScalarValue.Int($0) } ?? .Null)
            }
            if old?.capBytes != descriptor.capBytes {
                try document.put(
                    obj: entry, key: "capBytes",
                    value: descriptor.capBytes.map { ScalarValue.Int($0) } ?? .Null)
            }
            if old?.isPaused != descriptor.isPaused {
                try document.put(
                    obj: entry, key: "isPaused", value: .Boolean(descriptor.isPaused))
            }
        }
        for id in was.keys where descriptors[id] == nil {
            try document.delete(obj: map, key: id)
        }
    }

    // MARK: - The Automerge shapes

    private static func mapId(
        _ document: Document, _ obj: ObjId, _ key: String
    ) throws -> ObjId? {
        guard case .Object(let id, .Map) = try document.get(obj: obj, key: key) else { return nil }
        return id
    }

    private static func makeMap(_ document: Document, _ obj: ObjId, _ key: String) throws -> ObjId {
        if let known = try mapId(document, obj, key) { return known }
        return try document.putObject(obj: obj, key: key, ty: .Map)
    }

    private static func values(_ document: Document, _ map: ObjId) throws -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for (key, value) in try document.mapEntries(obj: map) {
            guard case .Scalar(.String(let json)) = value, let parsed = self.json(of: json) else {
                continue
            }
            out[key] = parsed
        }
        return out
    }

    private static func put(
        _ document: Document, _ obj: ObjId, _ key: String, _ value: String?
    ) throws {
        try document.put(obj: obj, key: key, value: value.map(ScalarValue.String) ?? .Null)
    }

    private static func text(_ document: Document, _ obj: ObjId, _ key: String) throws -> String? {
        guard case .Scalar(.String(let value)) = try document.get(obj: obj, key: key) else {
            return nil
        }
        return value
    }

    private static func int(_ document: Document, _ obj: ObjId, _ key: String) throws -> Int? {
        switch try document.get(obj: obj, key: key) {
        case .Scalar(.Int(let value)): return Int(value)
        case .Scalar(.Uint(let value)): return Int(value)
        default: return nil
        }
    }

    private static func flag(_ document: Document, _ obj: ObjId, _ key: String) throws -> Bool? {
        guard case .Scalar(.Boolean(let value)) = try document.get(obj: obj, key: key) else {
            return nil
        }
        return value
    }

    private static func date(_ document: Document, _ obj: ObjId, _ key: String) throws -> Date? {
        guard case .Scalar(.Timestamp(let value)) = try document.get(obj: obj, key: key) else {
            return nil
        }
        return value
    }

    // MARK: - The leaf text

    /// A leaf holds one JSON value under one key. A bare value at
    /// the top of a document is a JSON fragment, and not every
    /// encoder writes one, so the wrapper keeps the leaf ordinary
    /// JSON.
    private static let leafKey = "value"

    private static func text(of value: JSONValue) throws -> String {
        let data = try JSONEncoder().encode(JSONValue.object([leafKey: value]))
        guard let text = String(data: data, encoding: .utf8) else {
            throw SyncCopyRejection.unreadable("a leaf value is not UTF-8")
        }
        return text
    }

    private static func json(of text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8),
            let wrapper = try? JSONDecoder().decode(JSONValue.self, from: data),
            case .object(let fields) = wrapper
        else { return nil }
        return fields[leafKey]
    }
}
