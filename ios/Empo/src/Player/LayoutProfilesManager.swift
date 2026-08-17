import Foundation
import GameProbe

extension Notification.Name {
    /// Posted after a profile's content changes on disk. The object
    /// is the originator. Observers ignore their own posts. userInfo
    /// carries `name`.
    static let layoutProfileDidChange = Notification.Name("layoutProfileDidChange")

    /// Posted after a game's pin file changes. userInfo carries
    /// `gameID`.
    static let layoutPinDidChange = Notification.Name("layoutPinDidChange")

    /// Posted after the default profile is set, cleared, or renamed.
    /// The screen region follows the default live, so a silent
    /// UserDefaults write is not enough anymore.
    static let layoutDefaultProfileDidChange = Notification.Name(
        "layoutDefaultProfileDidChange")
}

/// App-side access to the layout-profile store, the default-profile
/// pointer, and the materializer's builtin defaults.
@MainActor
enum LayoutProfilesManager {
    static let profilesRootURL: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Profiles", isDirectory: true)

    /// A `let`: the getter used to run `createDirectory` on EVERY
    /// access, and resolution paths access it dozens of times per
    /// cycle. The directory is ensured once at first touch instead.
    static let store: LayoutProfileStore = {
        try? FileManager.default.createDirectory(
            at: profilesRootURL, withIntermediateDirectories: true)
        return LayoutProfileStore(
            profilesRoot: profilesRootURL, gamesRoot: GameContainer.rootURL)
    }()

    // MARK: - Default profile

    private static let defaultKey = "layoutProfiles.default"

    /// A dangling name resolves as unset.
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

    /// Rename keeps the default pointer and every pin following the
    /// profile.
    @discardableResult
    static func renameProfile(from oldName: String, to newName: String) -> Bool {
        let wasDefault = defaultProfileName == oldName
        guard store.renameProfile(from: oldName, to: newName) else { return false }
        if wasDefault {
            defaultProfileName = newName
        }
        // Post BOTH names: a bound session whose provenance still
        // holds the old name must re-resolve, or its next save
        // resurrects the deleted folder.
        postProfileChange(name: oldName, from: nil)
        postProfileChange(name: newName, from: nil)
        return true
    }

    /// Delete clears pins (store side) and the default pointer.
    @discardableResult
    static func deleteProfile(_ name: String) -> Bool {
        let wasDefault = defaultProfileName == name
        guard store.deleteProfile(name) else { return false }
        if wasDefault {
            defaultProfileName = nil
        }
        postProfileChange(name: name, from: nil)
        return true
    }

    static func postProfileChange(name: String, from origin: AnyObject?) {
        NotificationCenter.default.post(
            name: .layoutProfileDidChange, object: origin, userInfo: ["name": name])
    }

    static func postPinChange(gameID: String, from origin: AnyObject?) {
        NotificationCenter.default.post(
            name: .layoutPinDidChange, object: origin, userInfo: ["gameID": gameID])
    }

    /// Case-insensitive profile search, shared by the picker and
    /// the settings list.
    nonisolated static func filtered(_ profiles: [String], query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return profiles }
        return profiles.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    /// Creates a profile seeded from the builtin defaults. ONE
    /// home for the operation the settings list and the builtin
    /// viewer both offer.
    @discardableResult
    static func createProfileFromBuiltins(named name: String) -> Bool {
        store.createProfile(
            name,
            touch: ProfileMaterializer.materialize(
                user: nil, manifest: nil, builtins: builtins(), metrics: .reference
            ).section)
    }

    // MARK: - Off-player materialization

    /// The game's current resolved layout as a full profile section,
    /// for "Save this game's layout as a profile".
    static func materializedLayout(for container: GameContainer) -> TouchSection {
        let resolved = LayoutResolution.resolve(
            gameFolder: container.url,
            gameRoot: container.gameURL,
            store: store,
            defaultProfileName: defaultProfileName
        )
        let manifestTouch = ControlsManifestLoader.load(gameRoot: container.gameURL)?
            .result.manifest?.touch

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

    // MARK: - Builtins for the materializer

    /// The app's builtin default layouts as GameProbe values. The
    /// materializer needs concrete W3C-keyed layouts. GameProbe has
    /// no scancode table for the app's defaults.
    nonisolated static func builtins() -> ProfileMaterializer.Builtins {
        ProfileMaterializer.Builtins(
            portrait: builtinLayout(
                dpadCenter: ControlsLayout.defaultDPadCenterPortrait,
                buttons: ControlsLayout.defaultButtonsPortrait
            ),
            landscape: builtinLayout(
                dpadCenter: ControlsLayout.defaultDPadCenterLandscape,
                buttons: ControlsLayout.defaultButtonsLandscape
            )
        )
    }

    private nonisolated static func builtinLayout(
        dpadCenter: CGPoint,
        buttons: [ButtonModel]
    ) -> TouchLayout {
        TouchLayout(
            dpad: DPadSpec(
                x: Double(dpadCenter.x),
                y: Double(dpadCenter.y),
                size: Double(ControlsLayout.defaultDPadSize),
                opacity: 1.0
            ),
            buttons: buttons.compactMap { button in
                guard let key = KeyCodeTable.code(for: button.scancode) else { return nil }
                return ButtonSpec(
                    label: button.label,
                    key: key,
                    x: Double(button.relativeCenter.x),
                    y: Double(button.relativeCenter.y),
                    size: Double(button.size),
                    opacity: button.opacity
                )
            },
            actionButtons: []
        )
    }
}
