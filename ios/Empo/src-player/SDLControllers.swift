// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import AppKit

@MainActor
final class SDLControllers {
    static let shared = SDLControllers()

    /// The mappings that the user made in Settings > Controller, one SDL
    /// mapping line for each controller.
    static let savedMappingsURL = URL.applicationSupportDirectory.appending(path: "controller-mappings.txt")

    private var listeners: [UUID: (SDL_Event) -> Void] = [:]
    private var pump: Timer?
    /// The mapping line that SDL has now for each controller GUID.
    private var appliedMappings: [String: String] = [:]

    private init() {
        // SDL catches SIGINT and SIGTERM to post its own quit event, and
        // Empo Player would then not quit on them.
        SDL_SetHint(SDL_HINT_NO_SIGNAL_HANDLERS, "1")
        guard SDL_Init(SDL_INIT_GAMEPAD) else {
            NSLog("[controllers] SDL did not start: %@", String(cString: SDL_GetError()))
            return
        }
        if let list = Bundle.main.path(forResource: "gamecontrollerdb", ofType: "txt") {
            SDL_AddGamepadMappingsFromFile(list)
        }
        add(mappings: Self.savedMappingLines())
    }

    /// Calls `handler` with each SDL event until `removeListener`.
    func addListener(_ handler: @escaping (SDL_Event) -> Void) -> UUID {
        if listeners.isEmpty {
            // A new listener reads the state of each pad itself, so the
            // events that came while no one listened are old.
            SDL_PumpEvents()
            SDL_FlushEvents(SDL_EVENT_FIRST.rawValue, SDL_EVENT_LAST.rawValue)
            // SDL reads the pads only when the app pumps its events. It
            // has no callback for new input.
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
                MainActor.assumeIsolated { SDLControllers.shared.pumpEvents() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pump = timer
        }
        let id = UUID()
        listeners[id] = handler
        return id
    }

    func removeListener(_ id: UUID) {
        listeners[id] = nil
        if listeners.isEmpty {
            pump?.invalidate()
            pump = nil
        }
    }

    private func pumpEvents() {
        var event = SDL_Event()
        while SDL_PollEvent(&event) {
            for listener in listeners.values {
                listener(event)
            }
        }
    }

    /// SDL reloads the open pads of a mapping each time it gets that
    /// mapping, also when the line is the same, and a reload reads each
    /// trigger as released.
    func add(mappings: [String]) {
        for line in mappings where appliedMappings[Self.guid(ofMapping: line)] != line {
            if SDL_AddGamepadMapping(line) >= 0 {
                appliedMappings[Self.guid(ofMapping: line)] = line
            }
        }
    }

    private static func guid(ofMapping line: String) -> String {
        String(line.prefix { $0 != "," })
    }

    /// The connected joysticks, or with `gamepadsOnly` the connected
    /// joysticks that have a mapping.
    static func connected(gamepadsOnly: Bool) -> [SDL_JoystickID] {
        var count: Int32 = 0
        guard let ids = gamepadsOnly ? SDL_GetGamepads(&count) : SDL_GetJoysticks(&count) else { return [] }
        defer { SDL_free(ids) }
        return (0..<Int(count)).map { ids[$0] }.filter(isShown)
    }

    static func isShown(_ id: SDL_JoystickID) -> Bool {
        #if DEBUG
        UITestVirtualController.admits(id)
        #else
        true
        #endif
    }

    static func guid(of id: SDL_JoystickID) -> String {
        var text = [CChar](repeating: 0, count: 33)
        SDL_GUIDToString(SDL_GetJoystickGUIDForID(id), &text, Int32(text.count))
        return String(cString: text)
    }

    private static let optionalButtons: [SDL_GamepadButton] = [
        SDL_GAMEPAD_BUTTON_LEFT_PADDLE1, SDL_GAMEPAD_BUTTON_LEFT_PADDLE2,
        SDL_GAMEPAD_BUTTON_RIGHT_PADDLE1, SDL_GAMEPAD_BUTTON_RIGHT_PADDLE2,
        SDL_GAMEPAD_BUTTON_TOUCHPAD,
    ]

    /// The paddles and the touchpad that the mapping of `gamepad` has.
    static func optionalElements(of gamepad: OpaquePointer) -> Set<String> {
        Set(
            optionalButtons.filter { SDL_GamepadHasButton(gamepad, $0) }
                .compactMap { SDL_GetGamepadStringForButton($0).map { String(cString: $0) } })
    }

    static func savedMappingLines() -> [String] {
        let text = (try? String(contentsOf: savedMappingsURL, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    /// Saves a mapping line in the SDL format, and applies it now. SDL
    /// then reports the controller as a gamepad, or as remapped.
    func save(mapping: String) throws {
        guard SDL_AddGamepadMapping(mapping) >= 0 else {
            throw MappingRefused(reason: String(cString: SDL_GetError()))
        }
        let guid = Self.guid(ofMapping: mapping)
        appliedMappings[guid] = mapping
        var lines = Self.savedMappingLines().filter { !$0.hasPrefix(guid + ",") }
        lines.append(mapping)
        try FileManager.default.createDirectory(
            at: Self.savedMappingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(
            to: Self.savedMappingsURL, atomically: true, encoding: .utf8)
    }

    struct MappingRefused: Error {
        let reason: String
    }
}
