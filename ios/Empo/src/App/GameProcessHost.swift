import ExtensionFoundation
import ExtensionKit
import UIKit

extension AppExtensionPoint {
    @Definition
    static var gameProcess: AppExtensionPoint {
        Name("game-process")
        UserInterface(true)
    }
}

/// Runs each game in its own process, the GameProcess extension, and
/// shows that process's screen at the bottom of `AppWindow`.
@MainActor
enum GameProcessHost {
    private static var monitor: AppExtensionPoint.Monitor?
    private static var controller: EXHostViewController?
    private static let delegate = Delegate()
    private static var session = 0
    private static var lastExit: Task<Void, Never>?

    /// The view that shows the game, while a game process runs.
    static var gameView: UIView? { controller?.viewIfLoaded }

    static func start(framework: String) {
        EmpoGameProcessClient.begin(withFramework: framework)
        session += 1
        let current = session
        let previousExit = lastExit
        Task {
            // When a launch comes before the old process is gone, the
            // system connects the launch to the old process, which then
            // quits.
            await previousExit?.value
            guard current == session else { return }
            guard let identity = await identity() else {
                EngineSessionCoordinator.shared.note("The GameProcess extension is not in the app.")
                EmpoGameProcessClient.processLost()
                return
            }
            guard current == session else { return }
            show(identity)
        }
    }

    /// Returns when the last game process is gone, or after the time
    /// limit of `EmpoGameProcessClient.end`.
    static func waitForExit() async {
        await lastExit?.value
    }

    static func end() {
        session += 1
        let ending = controller
        controller = nil
        if let ending {
            ending.willMove(toParent: nil)
            ending.view.removeFromSuperview()
            ending.removeFromParent()
        }
        let exited = AsyncStream<Void> { continuation in
            EmpoGameProcessClient.end {
                continuation.finish()
            }
        }
        lastExit = Task {
            for await _ in exited {}
        }
    }

    private static func identity() async -> AppExtensionIdentity? {
        if let found = monitor?.identities.first { return found }
        do {
            let monitor = try await AppExtensionPoint.Monitor(appExtensionPoint: .gameProcess)
            self.monitor = monitor
            return monitor.identities.first
        } catch {
            EngineSessionCoordinator.shared.note("No extension monitor: \(error)")
            return nil
        }
    }

    private static func show(_ identity: AppExtensionIdentity) {
        guard let root = AppWindow.rootViewController, let hostView = root.viewIfLoaded else {
            EmpoGameProcessClient.processLost()
            return
        }
        let controller = EXHostViewController()
        controller.delegate = delegate
        let placeholder = UIView()
        placeholder.backgroundColor = .black
        controller.placeholderView = placeholder
        controller.configuration = .init(appExtension: identity, sceneID: "game")
        root.addChild(controller)
        controller.view.frame = hostView.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hostView.insertSubview(controller.view, at: 0)
        controller.didMove(toParent: root)
        self.controller = controller
    }

    private final class Delegate: NSObject, EXHostViewControllerDelegate {
        func hostViewControllerDidActivate(_ viewController: EXHostViewController) {
            MainActor.assumeIsolated {
                guard viewController === GameProcessHost.controller else { return }
                do {
                    EmpoGameProcessClient.attach(try viewController.makeXPCConnection())
                } catch {
                    EngineSessionCoordinator.shared.note("No connection to the game process: \(error)")
                    EmpoGameProcessClient.processLost()
                }
            }
        }

        func hostViewControllerWillDeactivate(_ viewController: EXHostViewController, error: (any Error)?) {
            MainActor.assumeIsolated {
                guard viewController === GameProcessHost.controller, let error else { return }
                EngineSessionCoordinator.shared.note("The game process stopped: \(error)")
                EmpoGameProcessClient.processLost()
            }
        }
    }
}
