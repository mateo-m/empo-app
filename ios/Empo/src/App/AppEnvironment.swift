// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

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

#if os(iOS)
private struct AppStateKey: EnvironmentKey {
    static let defaultValue: AppState = MainActor.assumeIsolated { .shared }
}
#endif

private struct AppSettingsKey: EnvironmentKey {
    static let defaultValue: AppSettings = MainActor.assumeIsolated { .shared }
}

#if os(iOS)
private struct EngineStateKey: EnvironmentKey {
    static let defaultValue: EngineState = MainActor.assumeIsolated { .shared }
}
#endif

#if os(iOS)
private struct PauseManagerKey: EnvironmentKey {
    static let defaultValue: PauseManager = MainActor.assumeIsolated { .shared }
}
#endif

private struct GameLibraryKey: EnvironmentKey {
    static let defaultValue: GameLibrary = MainActor.assumeIsolated { .shared }
}

#if os(iOS)
private struct ControlsLayoutKey: EnvironmentKey {
    static let defaultValue: ControlsLayout = MainActor.assumeIsolated { .shared }
}
#endif

#if os(iOS)
private struct HintStoreKey: EnvironmentKey {
    static let defaultValue: HintStore = MainActor.assumeIsolated { .shared }
}
#endif

extension EnvironmentValues {
    #if os(iOS)
    var appState: AppState {
        get { self[AppStateKey.self] }
        set { self[AppStateKey.self] = newValue }
    }
    #endif

    var appSettings: AppSettings {
        get { self[AppSettingsKey.self] }
        set { self[AppSettingsKey.self] = newValue }
    }

    #if os(iOS)
    var engineState: EngineState {
        get { self[EngineStateKey.self] }
        set { self[EngineStateKey.self] = newValue }
    }
    #endif

    #if os(iOS)
    var pauseManager: PauseManager {
        get { self[PauseManagerKey.self] }
        set { self[PauseManagerKey.self] = newValue }
    }
    #endif

    var gameLibrary: GameLibrary {
        get { self[GameLibraryKey.self] }
        set { self[GameLibraryKey.self] = newValue }
    }

    #if os(iOS)
    var controlsLayout: ControlsLayout {
        get { self[ControlsLayoutKey.self] }
        set { self[ControlsLayoutKey.self] = newValue }
    }
    #endif

    #if os(iOS)
    var hintStore: HintStore {
        get { self[HintStoreKey.self] }
        set { self[HintStoreKey.self] = newValue }
    }
    #endif
}

enum EmpoLink {
    static let support = URL(string: "https://empo.mateo.sh/community/")!
    static let privacy = URL(string: "https://empo.mateo.sh/privacy/")!
    static let terms = URL(string: "https://empo.mateo.sh/terms/")!
    static let sourceCode = URL(string: "https://github.com/mateo-m/empo-app")!
    static let twitter = URL(string: "https://x.com/gridplay_")!
}
