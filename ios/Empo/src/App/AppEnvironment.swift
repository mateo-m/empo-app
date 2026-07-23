import SwiftUI

/// SwiftUI environment injection for app-wide services.
///
/// Views read services via `@Environment(\.appState)` and the other
/// keys instead of a direct reach into `AppState.shared`. One
/// composition root (RootView) injects the instances once. Nested
/// views inherit them automatically.
///
/// Non-UI code (C bridge callbacks, AppWindow statics, Haptics) still
/// uses `.shared` because the SwiftUI environment is not reachable
/// from those contexts.
///
/// `EnvironmentKey.defaultValue` must be nonisolated, but our service
/// singletons are `@MainActor`-isolated. SwiftUI always queries
/// EnvironmentValues on the main actor, so `MainActor.assumeIsolated`
/// is sound here. It documents that runtime invariant and traps
/// loudly if a call ever comes from a non-main thread.

private struct AppStateKey: EnvironmentKey {
    static let defaultValue: AppState = MainActor.assumeIsolated { .shared }
}

private struct AppSettingsKey: EnvironmentKey {
    static let defaultValue: AppSettings = MainActor.assumeIsolated { .shared }
}

private struct EngineStateKey: EnvironmentKey {
    static let defaultValue: EngineState = MainActor.assumeIsolated { .shared }
}

private struct PauseManagerKey: EnvironmentKey {
    static let defaultValue: PauseManager = MainActor.assumeIsolated { .shared }
}

private struct GameLibraryKey: EnvironmentKey {
    static let defaultValue: GameLibrary = MainActor.assumeIsolated { .shared }
}

private struct ControlsLayoutKey: EnvironmentKey {
    static let defaultValue: ControlsLayout = MainActor.assumeIsolated { .shared }
}

private struct HintStoreKey: EnvironmentKey {
    static let defaultValue: HintStore = MainActor.assumeIsolated { .shared }
}

extension EnvironmentValues {
    var appState: AppState {
        get { self[AppStateKey.self] }
        set { self[AppStateKey.self] = newValue }
    }

    var appSettings: AppSettings {
        get { self[AppSettingsKey.self] }
        set { self[AppSettingsKey.self] = newValue }
    }

    var engineState: EngineState {
        get { self[EngineStateKey.self] }
        set { self[EngineStateKey.self] = newValue }
    }

    var pauseManager: PauseManager {
        get { self[PauseManagerKey.self] }
        set { self[PauseManagerKey.self] = newValue }
    }

    var gameLibrary: GameLibrary {
        get { self[GameLibraryKey.self] }
        set { self[GameLibraryKey.self] = newValue }
    }

    var controlsLayout: ControlsLayout {
        get { self[ControlsLayoutKey.self] }
        set { self[ControlsLayoutKey.self] = newValue }
    }

    var hintStore: HintStore {
        get { self[HintStoreKey.self] }
        set { self[HintStoreKey.self] = newValue }
    }
}
