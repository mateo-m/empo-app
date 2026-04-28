import SwiftUI

/// SwiftUI environment injection for app-wide services.
///
/// Views read services via `@Environment(\.appState)` etc. instead of
/// reaching into `AppState.shared`. A single composition root (RootView)
/// injects instances once; nested views inherit them automatically.
///
/// Non-UI code (C bridge callbacks, AppWindow statics, Haptics) still
/// uses `.shared` because SwiftUI environment isn't reachable from
/// those contexts.

private struct AppStateKey: EnvironmentKey {
    @MainActor static let defaultValue: AppState = .shared
}

private struct AppSettingsKey: EnvironmentKey {
    @MainActor static let defaultValue: AppSettings = .shared
}

private struct EngineStateKey: EnvironmentKey {
    @MainActor static let defaultValue: EngineState = .shared
}

private struct PauseManagerKey: EnvironmentKey {
    @MainActor static let defaultValue: PauseManager = .shared
}

private struct GameLibraryKey: EnvironmentKey {
    @MainActor static let defaultValue: GameLibrary = .shared
}

private struct ControlsLayoutKey: EnvironmentKey {
    @MainActor static let defaultValue: ControlsLayout = .shared
}

private struct HintStoreKey: EnvironmentKey {
    @MainActor static let defaultValue: HintStore = .shared
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
