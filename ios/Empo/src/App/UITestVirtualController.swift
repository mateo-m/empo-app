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
@MainActor
enum UITestVirtualController {
    private static var virtual: GCVirtualController?

    private static let mode = ProcessInfo.processInfo.environment["EMPO_UITEST_CONTROLLER"]

    private static let prefix = "sh.mateo.empo.uitest.pad."

    private static let commands: [String: (GCVirtualController) -> Void] = [
        "a.down": { $0.setValue(1, forButtonElement: GCInputButtonA) },
        "a.up": { $0.setValue(0, forButtonElement: GCInputButtonA) },
        "stick.right": { $0.setPosition(CGPoint(x: 1, y: 0), forDirectionPadElement: GCInputLeftThumbstick) },
        "stick.upright": {
            $0.setPosition(CGPoint(x: 0.7, y: 0.7), forDirectionPadElement: GCInputLeftThumbstick)
        },
        "stick.center": { $0.setPosition(.zero, forDirectionPadElement: GCInputLeftThumbstick) },
        "disconnect": { $0.disconnect() },
    ]

    static func connectIfRequested() {
        guard mode == "virtual", virtual == nil else { return }
        let configuration = GCVirtualController.Configuration()
        configuration.elements = [GCInputLeftThumbstick, GCInputButtonA, GCInputButtonB]
        configuration.isHidden = true
        let pad = GCVirtualController(configuration: configuration)
        virtual = pad
        for name in commands.keys {
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(), nil,
                padCommandCallback,
                (prefix + name) as CFString, nil, .deliverImmediately)
        }
        Task { try? await pad.connect() }
    }

    static func admits(_ controller: GCController) -> Bool {
        mode == nil || controller === virtual?.controller
    }

    fileprivate static func run(_ notification: String) {
        guard let virtual, let command = commands[String(notification.dropFirst(prefix.count))]
        else { return }
        command(virtual)
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
