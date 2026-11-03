// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

struct ControllerSetupSection: View {
    @State private var controllers = ConnectedControllers()
    @State private var settingUp: ConnectedControllers.Controller?

    var body: some View {
        Section {
            if controllers.all.isEmpty {
                Text("No controller connected")
                    .foregroundStyle(.secondary)
            }
            ForEach(controllers.all) { controller in
                LabeledContent {
                    Button("Set Up…") { settingUp = controller }
                } label: {
                    Text(controller.name)
                    if !controller.isRecognized {
                        Text("Not recognized")
                    }
                }
            }
        } header: {
            Text("Controllers")
        } footer: {
            Text(
                "If a controller isn’t recognized or its buttons are mixed up, set it up by pressing each button."
            )
        }
        .onAppear { controllers.start() }
        .onDisappear { controllers.stop() }
        .onChange(of: controllers.all) {
            if let settingUp, !controllers.all.contains(settingUp) {
                self.settingUp = nil
            }
        }
        .sheet(item: $settingUp) { controller in
            ControllerSetupSheet(setup: ControllerSetup(controller: controller))
        }
    }
}

@MainActor @Observable
final class ConnectedControllers {
    struct Controller: Identifiable, Hashable {
        let id: SDL_JoystickID
        let guid: String
        let name: String
        let isRecognized: Bool
    }

    private(set) var all: [Controller] = []
    @ObservationIgnored private var listener: UUID?

    func start() {
        guard listener == nil else { return }
        listener = SDLControllers.shared.addListener { [weak self] event in
            switch event.type {
            case SDL_EVENT_JOYSTICK_ADDED.rawValue, SDL_EVENT_JOYSTICK_REMOVED.rawValue,
                SDL_EVENT_GAMEPAD_ADDED.rawValue:
                self?.refresh()
            default:
                break
            }
        }
        refresh()
    }

    func stop() {
        if let listener {
            SDLControllers.shared.removeListener(listener)
        }
        listener = nil
    }

    private func refresh() {
        all = SDLControllers.connected(gamepadsOnly: false).map {
            Controller(
                id: $0, guid: SDLControllers.guid(of: $0),
                name: SDL_GetJoystickNameForID($0).map { String(cString: $0) }
                    ?? String(localized: "Controller"),
                isRecognized: SDL_IsGamepad($0))
        }
    }
}

/// Asks for each button of the button list in turn, and saves what the
/// user pressed as an SDL gamepad mapping.
@MainActor @Observable
final class ControllerSetup {
    /// One control of the raw joystick, in the terms of an SDL mapping.
    enum Input: Hashable {
        case button(Int32)
        case hat(Int32, direction: UInt8)
        case axis(Int32, positive: Bool, rest: Int16)

        /// An axis that rests at one end is a trigger. SDL reads it
        /// over its full range.
        var mappingValue: String {
            switch self {
            case .button(let index):
                "b\(index)"
            case .hat(let index, let direction):
                "h\(index).\(direction)"
            case .axis(let index, _, let rest) where rest < Int16.min / 2:
                "a\(index)"
            case .axis(let index, _, let rest) where rest > Int16.max / 2:
                "a\(index)~"
            case .axis(let index, let positive, _):
                "\(positive ? "+" : "-")a\(index)"
            }
        }

        /// Two steps can't share one control. A stick axis gives one
        /// control for each direction, and a trigger gives one.
        var control: String {
            mappingValue.trimmingCharacters(in: ["~"])
        }
    }

    let controller: ConnectedControllers.Controller
    let steps: [BindingsCatalog.Row] = BindingsCatalog.sections(includingOptional: []).flatMap(\.elements)
    private(set) var stepIndex = 0
    private(set) var inputs: [String: Input] = [:]
    private(set) var saveFailed = false

    @ObservationIgnored private var joystick: OpaquePointer?
    @ObservationIgnored private var listener: UUID?
    /// The controls that are pressed now. A step waits until the user
    /// lets go of the control of the step before.
    @ObservationIgnored private var held: Set<String> = []

    init(controller: ConnectedControllers.Controller) {
        self.controller = controller
    }

    var step: BindingsCatalog.Row? { steps.indices.contains(stepIndex) ? steps[stepIndex] : nil }

    func start() {
        guard listener == nil else { return }
        // SDL sends the input events of a joystick only while it is open.
        joystick = SDL_OpenJoystick(controller.id)
        listener = SDLControllers.shared.addListener { [weak self] in self?.handle($0) }
    }

    func stop() {
        if let listener {
            SDLControllers.shared.removeListener(listener)
        }
        listener = nil
        SDL_CloseJoystick(joystick)
        joystick = nil
    }

    func skip() {
        guard let step else { return }
        inputs[step.id] = nil
        stepIndex += 1
    }

    func back() {
        guard stepIndex > 0 else { return }
        stepIndex -= 1
        if let step { inputs[step.id] = nil }
    }

    func save() -> Bool {
        let name = controller.name.replacingOccurrences(of: ",", with: " ")
        let fields = steps.compactMap { step in inputs[step.id].map { "\(step.id):\($0.mappingValue)" } }
        do {
            try SDLControllers.shared.save(
                mapping: ([controller.guid, name] + fields + ["platform:Mac OS X", ""]).joined(separator: ",")
            )
            GameLauncher.shared.sendLiveSettings()
            return true
        } catch {
            NSLog("[controllers] cannot save the setup: %@", "\(error)")
            saveFailed = true
            return false
        }
    }

    private func handle(_ event: SDL_Event) {
        // SDL reads pads also while Empo is in the background, for
        // example while the user plays a game in Empo Player.
        guard NSApp.isActive else { return }
        switch event.type {
        case SDL_EVENT_JOYSTICK_BUTTON_DOWN.rawValue where event.jbutton.which == controller.id:
            press(.button(Int32(event.jbutton.button)))
        case SDL_EVENT_JOYSTICK_BUTTON_UP.rawValue where event.jbutton.which == controller.id:
            held.remove(Input.button(Int32(event.jbutton.button)).control)
        case SDL_EVENT_JOYSTICK_HAT_MOTION.rawValue where event.jhat.which == controller.id:
            let hat = Int32(event.jhat.hat)
            for direction: UInt8 in [1, 2, 4, 8] where event.jhat.value & direction == 0 {
                held.remove(Input.hat(hat, direction: direction).control)
            }
            // A diagonal is two directions at once. It can't tell the
            // step which one the user means.
            if [1, 2, 4, 8].contains(event.jhat.value) {
                press(.hat(hat, direction: event.jhat.value))
            }
        case SDL_EVENT_JOYSTICK_AXIS_MOTION.rawValue where event.jaxis.which == controller.id:
            moveAxis(Int32(event.jaxis.axis), to: event.jaxis.value)
        default:
            break
        }
    }

    private func moveAxis(_ axis: Int32, to value: Int16) {
        var rest: Int16 = 0
        _ = SDL_GetJoystickAxisInitialState(joystick, axis, &rest)
        let offset = Int(value) - Int(rest)
        if abs(offset) < Int(Int16.max) / 4 {
            held.remove(Input.axis(axis, positive: true, rest: rest).control)
            held.remove(Input.axis(axis, positive: false, rest: rest).control)
        } else if abs(offset) > Int(Int16.max) / 2 {
            press(.axis(axis, positive: offset > 0, rest: rest))
        }
    }

    private func press(_ input: Input) {
        let wasIdle = held.isEmpty
        held.insert(input.control)
        guard wasIdle, let step,
            !inputs.values.contains(where: { $0.control == input.control })
        else { return }
        inputs[step.id] = input
        stepIndex += 1
    }
}

struct ControllerSetupSheet: View {
    @State var setup: ControllerSetup
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text("Set Up \(setup.controller.name)")
                .font(.headline)

            if let step = setup.step {
                VStack(spacing: 8) {
                    Text("Press this on your controller:")
                        .foregroundStyle(.secondary)
                    Text(step.label)
                        .font(.title2.weight(.semibold))
                    Text("\(setup.stepIndex + 1) of \(setup.steps.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity, minHeight: 110)
            } else {
                VStack(spacing: 8) {
                    Text("That’s every button.")
                        .font(.title2.weight(.semibold))
                    Text("Save to use this setup in your games.")
                        .foregroundStyle(.secondary)
                    if setup.saveFailed {
                        Text("Couldn’t save the setup. Try again.")
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 110)
            }

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Back") { setup.back() }
                    .disabled(setup.stepIndex == 0)
                if setup.step != nil {
                    Button(
                        String(
                            localized: "controller-setup.skip", defaultValue: "Skip",
                            comment: "Moves to the next button of the controller setup.")
                    ) { setup.skip() }
                } else {
                    Button("Save") {
                        if setup.save() { dismiss() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(setup.inputs.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
        // The button list behind the sheet would light up at each press.
        .onAppear {
            ControllerPressListener.shared.end()
            setup.start()
        }
        .onDisappear {
            setup.stop()
            ControllerPressListener.shared.begin()
        }
    }
}
