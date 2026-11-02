// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

#if DEBUG
import GameController

/// A UI test sets `EMPO_UITEST_CONTROLLER` to `virtual` to play with a
/// virtual extended gamepad, or to `none` to play with no controller.
/// The test drives the virtual pad with Darwin notifications named
/// `sh.mateo.empo.uitest.pad.<command>`, one per entry in `commands`.
///
/// Every simulator publishes an MFi gamepad of its own: `backboardd`
/// creates the HID service `com.apple.SimulatorHID.GamePadService` at
/// boot, and GameController shows it as a connected `GCController`.
/// No setting removes it, so in both modes the app ignores every
/// controller except the virtual one.
///
/// macOS has no `GCVirtualController`, and a virtual HID device needs
/// the restricted `com.apple.developer.hid.virtual.device` entitlement.
/// `GCController.withExtendedGamepad()` works on both platforms, but
/// GameController never lists it in `GCController.controllers()` or
/// posts its connection, so this type does both.
@MainActor
enum UITestVirtualController {
    private(set) static var controller: GCController?

    private static let mode = ProcessInfo.processInfo.environment["EMPO_UITEST_CONTROLLER"]

    private static let prefix = "sh.mateo.empo.uitest.pad."

    private static let commands: [String: (GCExtendedGamepad) -> Void] = [
        "a.down": { $0.buttonA.setValue(1) },
        "a.up": { $0.buttonA.setValue(0) },
        "stick.right": { $0.leftThumbstick.setValueForXAxis(1, yAxis: 0) },
        "stick.upright": { $0.leftThumbstick.setValueForXAxis(0.7, yAxis: 0.7) },
        "stick.center": { $0.leftThumbstick.setValueForXAxis(0, yAxis: 0) },
    ]

    static func connectIfRequested() {
        guard mode == "virtual", controller == nil else { return }
        let pad = GCController.withExtendedGamepad()
        controller = pad
        for name in Array(commands.keys) + ["disconnect"] {
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(), nil,
                padCommandCallback,
                (prefix + name) as CFString, nil, .deliverImmediately)
        }
        NotificationCenter.default.post(name: .GCControllerDidConnect, object: pad)
    }

    static func admits(_ candidate: GCController) -> Bool {
        mode == nil || candidate === controller
    }

    fileprivate static func run(_ notification: String) {
        guard let controller else { return }
        let name = String(notification.dropFirst(prefix.count))
        if name == "disconnect" {
            Self.controller = nil
            NotificationCenter.default.post(name: .GCControllerDidDisconnect, object: controller)
        } else if let pad = controller.extendedGamepad, let command = commands[name] {
            command(pad)
        }
    }
}

private func padCommandCallback(
    _: CFNotificationCenter?, _: UnsafeMutableRawPointer?, name: CFNotificationName?,
    _: UnsafeRawPointer?, _: CFDictionary?
) {
    guard let name = name?.rawValue as String? else { return }
    // The Darwin center calls back on the main thread.
    MainActor.assumeIsolated { UITestVirtualController.run(name) }
}
#endif
