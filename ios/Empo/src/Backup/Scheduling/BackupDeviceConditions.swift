import Foundation
import GameProbe
import UIKit

/// What the device and the app are doing, for the gates of SPEC 7.5
/// and 7.6.
///
/// The rules live in `ResourcePolicy`, inside GameProbe, where
/// `swift test` reaches them. This file reads the values only iOS
/// can answer.
@MainActor
enum BackupDeviceConditions {

    /// A play session is live. A paused session still counts as
    /// live, per 7.6, because a background pause keeps the player
    /// view mounted. `EngineSessionCoordinator` is the gate, and
    /// every caller reads it through here.
    static var isSessionLive: Bool {
        EngineSessionCoordinator.shared.isSessionLive
    }

    static func now(isManual: Bool = false) -> BackupConditions {
        BackupConditions(
            isSessionLive: isSessionLive,
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: thermalState,
            isManual: isManual)
    }

    static var thermalState: DeviceThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .serious
        }
    }

    /// The name the storage notification of 7.11 uses: "iPhone" or
    /// "iPad".
    static var deviceName: String {
        UIDevice.current.model
    }
}

extension EngineSessionCoordinator {

    /// Whether a play session is live, per SPEC 7.6.
    ///
    /// This is invariant 5, and it is a hard stop and not a QoS
    /// demotion: the engine shares Empo's process, and the
    /// contention is disk I/O. No staging runs while this is true.
    ///
    /// The delegate holds the selected game and the paused game, and
    /// `AppState` clears both when the engine terminates. So a game
    /// that is paused to the library still reads live, which is what
    /// 7.6 asks for.
    var isSessionLive: Bool {
        delegate?.coordinatorActiveSessionGame != nil
    }

    /// The game the player is in, whether it plays or sits paused in
    /// the library. The Backup sheet of 13.17 names it in the one
    /// footer line that says why the actions wait.
    var openGameName: String? {
        delegate?.coordinatorActiveSessionGame?.title
    }
}
