import Foundation
import GameProbe

@MainActor
enum SyncLocalValues {

    static func current(identities: inout SyncProfileIdentities) -> SyncDocumentModel {
        var model = SyncDocumentModel()
        model.preferences = preferences()
        if let global = BindingStore.loadGlobal() {
            model.controllerBindings = BindingMapSyncCoder.entries(of: global)
        }
        model.layoutProfiles = profiles(identities: &identities)
        for descriptor in BackupTargets.load() {
            model.targetDescriptors[descriptor.id] = descriptor.forSyncDocument()
        }
        return model
    }

    /// `controllerBindings` already carries `controllerMap.global`. A
    /// second copy here gives one binding two homes with no precedence.
    static func preferences() -> [String: JSONValue] {
        var values = DevicePreferences.currentDefaults()
        values.removeValue(forKey: PreferenceKeys.controllerMapGlobal.name)
        return values
    }

    private static func profiles(
        identities: inout SyncProfileIdentities
    ) -> [String: SyncProfile] {
        let store = LayoutProfilesManager.store
        var out: [String: SyncProfile] = [:]
        for name in store.listProfiles() {
            let id = identities.id(ofProfile: name)
            out[id] = SyncProfile(
                name: name,
                controls: TouchSectionSyncCoder.controls(
                    of: store.readProfile(name)?.touch ?? TouchSection()),
                screen: screenValue(name: name, store: store))
        }
        // The record has no name. The merged document supplies it.
        for (id, date) in identities.deleted {
            out[id] = SyncProfile(name: "", deletedAt: date)
        }
        return out
    }

    private static func screenValue(name: String, store: LayoutProfileStore) -> JSONValue? {
        guard let data = try? Data(contentsOf: store.screenURL(name)) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    // MARK: - Applying the merged document

    static func apply(_ model: SyncDocumentModel, identities: inout SyncProfileIdentities) {
        DevicePreferences.apply(model.preferences)
        if !model.controllerBindings.isEmpty {
            BindingStore.saveGlobal(BindingMapSyncCoder.map(of: model.controllerBindings))
        }
        applyProfiles(model, identities: &identities)
        applyDescriptors(model.targetDescriptors)
    }

    private static func applyProfiles(
        _ model: SyncDocumentModel, identities: inout SyncProfileIdentities
    ) {
        let store = LayoutProfilesManager.store

        for (id, profile) in model.layoutProfiles where profile.isDeleted {
            guard let local = identities.name(ofId: id) else { continue }
            do {
                try LayoutProfilesManager.deleteProfile(local)
                identities.forget(profile: local)
            } catch {
                NSLog("sync: delete of profile \(local) failed: \(error)")
            }
        }

        for (id, profile) in model.liveProfiles
        where LayoutProfileStore.validatedName(profile.name) == profile.name {
            // A failed step skips the profile, so that the incoming
            // profile never writes over a local one.
            do {
                let local = identities.name(ofId: id)
                if let local, local != profile.name {
                    try store.renameProfile(from: local, to: profile.name)
                    identities.rename(from: local, to: profile.name)
                }
                if local == nil, store.profileExists(profile.name) {
                    try displace(profile.name, store: store, identities: &identities)
                }
                let touch = TouchSectionSyncCoder.section(of: profile.controls)
                if store.profileExists(profile.name) {
                    try store.writeProfile(profile.name, touch: touch)
                } else {
                    try store.createProfile(profile.name, touch: touch)
                }
                identities.ids[profile.name] = id
                try applyScreen(profile.screen, name: profile.name, store: store)
            } catch {
                NSLog("sync: profile \(profile.name) not applied: \(error)")
            }
            LayoutProfilesManager.postProfileChange(name: profile.name, from: nil)
        }
    }

    private static func displace(
        _ name: String, store: LayoutProfileStore, identities: inout SyncProfileIdentities
    ) throws {
        let local = store.storedName(name) ?? name
        let taken = Set(store.listProfiles())
        let moved = DisplacedCopy.nextTreeName(for: local, taken: taken)
        try store.renameProfile(from: local, to: moved)
        identities.rename(from: local, to: moved)
    }

    private static func applyScreen(
        _ value: JSONValue?, name: String, store: LayoutProfileStore
    ) throws {
        guard let value, let data = try? JSONEncoder().encode(value) else { return }
        let parsed = ScreenRegionFile.parse(data)
        guard parsed.findings.isEmpty else { return }
        try store.writeScreen(name, portrait: parsed.portrait, landscape: parsed.landscape)
    }

    /// A new descriptor arrives without its secret. Target removal stays
    /// on this device, so this function never deletes a target.
    private static func applyDescriptors(_ descriptors: [String: TargetDescriptor]) {
        let removed = Set(SyncStore.state().removedTargetIds)
        try? BackupTargets.update { local in
            for (id, incoming) in descriptors {
                guard let index = local.firstIndex(where: { $0.id == id }) else {
                    if !removed.contains(id) { local.append(incoming) }
                    continue
                }
                local[index] = local[index].withSyncedFields(from: incoming)
            }
        }
    }
}

@MainActor
final class DeviceSyncValues: SyncLocalValuesStore {

    func read(identities: inout SyncProfileIdentities) -> SyncDocumentModel {
        SyncLocalValues.current(identities: &identities)
    }

    func apply(_ model: SyncDocumentModel, identities: inout SyncProfileIdentities) {
        SyncPass.shared.isApplying = true
        defer { SyncPass.shared.isApplying = false }
        SyncLocalValues.apply(model, identities: &identities)
    }
}
