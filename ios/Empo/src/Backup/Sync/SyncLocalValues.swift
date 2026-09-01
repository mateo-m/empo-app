import Foundation
import GameProbe

/// This device's side of the sync document, per SPEC 10.5 steps 3
/// and 4.
///
/// It reads what the device holds now into the model, and it applies
/// a merged model back to UserDefaults, to the global controller
/// bindings, and to the layout profile files.
@MainActor
enum SyncLocalValues {

    /// The document leaves this device would publish now.
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

    /// The portable preferences, without the one key that has a
    /// finer home. `controllerMap.global` rides
    /// `controllerBindings`, per 10.3, so carrying it here as well
    /// would give one binding two homes with no precedence between
    /// them.
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
        // A profile this device deleted travels as a record, per
        // 10.6. The name comes from the merged document, which is
        // why the record carries none.
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

    /// The profile rules of 10.6 and 10.7.
    ///
    /// A profile arrives as it is: no refit and no refusal. On a name
    /// collision the incoming profile takes the name, and the whole
    /// local folder moves aside as `<name>.empo-displaced`.
    private static func applyProfiles(
        _ model: SyncDocumentModel, identities: inout SyncProfileIdentities
    ) {
        let store = LayoutProfilesManager.store

        for (id, profile) in model.layoutProfiles where profile.isDeleted {
            guard let local = identities.name(ofId: id) else { continue }
            LayoutProfilesManager.deleteProfile(local)
            identities.forget(profile: local)
        }

        for (id, profile) in model.liveProfiles {
            let local = identities.name(ofId: id)
            if let local, local != profile.name {
                _ = store.renameProfile(from: local, to: profile.name)
                identities.rename(from: local, to: profile.name)
            }
            if local == nil, store.profileExists(profile.name) {
                displace(profile.name, store: store, identities: &identities)
            }
            let touch = TouchSectionSyncCoder.section(of: profile.controls)
            if store.profileExists(profile.name) {
                _ = store.writeProfile(profile.name, touch: touch)
            } else {
                _ = store.createProfile(profile.name, touch: touch)
            }
            identities.ids[profile.name] = id
            applyScreen(profile.screen, name: profile.name, store: store)
            LayoutProfilesManager.postProfileChange(name: profile.name, from: nil)
        }
    }

    /// The local folder moves whole, per 10.7. This is the stated
    /// profile-folder exception to the per-file rule of 11.1.
    private static func displace(
        _ name: String, store: LayoutProfileStore, identities: inout SyncProfileIdentities
    ) {
        let taken = Set(store.listProfiles())
        let moved = DisplacedCopy.nextTreeName(for: name, taken: taken)
        guard store.renameProfile(from: name, to: moved) else { return }
        identities.rename(from: name, to: moved)
    }

    private static func applyScreen(_ value: JSONValue?, name: String, store: LayoutProfileStore) {
        guard let value, let data = try? JSONEncoder().encode(value) else { return }
        let parsed = ScreenRegionFile.parse(data)
        guard parsed.findings.isEmpty else { return }
        _ = store.writeScreen(name, portrait: parsed.portrait, landscape: parsed.landscape)
    }

    /// The descriptors of 10.8. A descriptor Empo does not hold
    /// arrives without its secret, which is the target placeholder.
    /// Removing a target stays local-only, so nothing here deletes.
    private static func applyDescriptors(_ descriptors: [String: TargetDescriptor]) {
        try? BackupTargets.update { local in
            for (id, incoming) in descriptors {
                guard let index = local.firstIndex(where: { $0.id == id }) else {
                    local.append(incoming)
                    continue
                }
                local[index] = local[index].withSyncedFields(from: incoming)
            }
        }
    }
}
