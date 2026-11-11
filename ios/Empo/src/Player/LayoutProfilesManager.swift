// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import GameProbe

extension Notification.Name {
    /// The object is the sender. Observers ignore their own posts.
    static let layoutProfileDidChange = Notification.Name("layoutProfileDidChange")

    static let layoutPinDidChange = Notification.Name("layoutPinDidChange")

    static let layoutDefaultProfileDidChange = Notification.Name(
        "layoutDefaultProfileDidChange")
}

@MainActor
enum LayoutProfilesManager {
    nonisolated static let profileNameKey = "name"
    nonisolated static let gameIDKey = "gameID"

    nonisolated static let profilesRootURL: URL = DataDirectory.documentsRootURL
        .appendingPathComponent("Profiles", isDirectory: true)

    static let store: LayoutProfileStore = {
        try? FileManager.default.createDirectory(
            at: profilesRootURL, withIntermediateDirectories: true)
        return LayoutProfileStore(
            profilesRoot: profilesRootURL, gamesRoot: GameContainer.rootURL)
    }()

    // MARK: - Default profile

    private static let defaultKey = DefaultsKey.layoutProfilesDefault

    static var defaultProfileName: String? {
        get {
            guard let name = UserDefaults.standard.string(forKey: defaultKey) else { return nil }
            return store.profileExists(name) ? name : nil
        }
        set {
            let old = UserDefaults.standard.string(forKey: defaultKey)
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: defaultKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultKey)
            }
            if old != newValue {
                NotificationCenter.default.post(
                    name: .layoutDefaultProfileDidChange, object: nil)
            }
        }
    }

    // MARK: - Store operations with app-level side effects

    static func renameProfile(_ oldName: String, toRawName rawName: String) throws -> String? {
        guard let newName = LayoutProfileStore.validatedName(rawName) else {
            throw LayoutProfileStore.StoreError.invalidName(rawName)
        }
        guard newName != oldName else { return nil }
        try renameProfile(from: oldName, to: newName)
        return newName
    }

    /// The default pointer and every pin follow the profile.
    static func renameProfile(from oldName: String, to newName: String) throws {
        let wasDefault = defaultProfileName == oldName
        try store.renameProfile(from: oldName, to: newName)
        SyncStore.profileWasRenamed(from: oldName, to: newName)
        if wasDefault {
            defaultProfileName = newName
        }
        // Post both names. A bound session that still holds the old
        // name must resolve again. Otherwise its next save makes the
        // old folder again.
        postProfileChange(name: oldName, from: nil)
        postProfileChange(name: newName, from: nil)
    }

    static func deleteProfile(_ name: String) throws {
        let wasDefault = defaultProfileName == name
        try store.deleteProfile(name)
        SyncStore.profileWasDeleted(name)
        if wasDefault {
            defaultProfileName = nil
        }
        postProfileChange(name: name, from: nil)
    }

    static func postProfileChange(name: String, from origin: AnyObject?) {
        NotificationCenter.default.post(
            name: .layoutProfileDidChange, object: origin, userInfo: [profileNameKey: name])
    }

    static func postPinChange(gameID: String, from origin: AnyObject?) {
        NotificationCenter.default.post(
            name: .layoutPinDidChange, object: origin, userInfo: [gameIDKey: gameID])
    }

    static func writePin(
        _ pin: LayoutPin, for container: GameContainer, from origin: AnyObject?
    )
        throws
    {
        try store.writePin(pin, forGameFolder: container.url)
        postPinChange(gameID: container.id, from: origin)
    }

    nonisolated static func filtered(_ profiles: [String], query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return profiles }
        return profiles.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    static func createProfileFromBuiltins(rawName: String) throws {
        guard let name = LayoutProfileStore.validatedName(rawName) else {
            throw LayoutProfileStore.StoreError.invalidName(rawName)
        }
        try store.createProfile(
            name,
            touch: ProfileMaterializer.materialize(
                user: nil, manifest: nil, builtins: builtins(), metrics: .reference
            ).section)
    }

    // MARK: - Off-player materialization

    static func materializedLayout(for container: GameContainer) -> TouchSection {
        let manifestTouch = ControlsManifestLoader.load(
            gameRoot: container.gameURL, metrics: .reference)?.result.manifest?.touch
        let resolved = LayoutResolution.resolve(
            pin: store.loadPin(forGameFolder: container.url).pin,
            gameLayoutOccupied: manifestTouch != nil,
            store: store,
            defaultProfileName: defaultProfileName)

        switch resolved.provenance {
        case .pinnedProfile(let name), .defaultProfile(let name):
            let touch = store.readProfile(name)?.touch
            return ProfileMaterializer.materialize(
                user: touch, manifest: nil, builtins: builtins(), metrics: .reference
            ).section
        case .gameLayout:
            return ProfileMaterializer.materialize(
                user: nil, manifest: manifestTouch, builtins: builtins(), metrics: .reference
            ).section
        case .builtin:
            return ProfileMaterializer.materialize(
                user: nil, manifest: nil, builtins: builtins(), metrics: .reference
            ).section
        }
    }

    nonisolated static func builtins() -> ProfileMaterializer.Builtins {
        ProfileMaterializer.Builtins(keys: ControlsLayout.builtinKeys)
    }
}
