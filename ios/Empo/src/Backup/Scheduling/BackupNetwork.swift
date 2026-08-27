import Foundation
import GameProbe
import Network

/// The one app-wide network switch of SPEC 7.4, and what the device
/// is connected to right now.
///
/// The rules live in `NetworkPolicy` and `ResourcePolicy`, inside
/// GameProbe. This file stores the switch and reads the path.
///
/// Ticket 016 puts the switch on the Backups screen. Until then it
/// stays off, which is the default 7.4 asks for.
enum BackupNetwork {

    /// "Back up over cellular". Off by default, and there is no
    /// per-target override.
    static var backsUpOverCellular: Bool {
        get { UserDefaults.standard.bool(forKey: DefaultsKey.backupOverCellular) }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.backupOverCellular) }
    }

    static var policy: NetworkPolicy {
        NetworkPolicy(backsUpOverCellular: backsUpOverCellular)
    }

    /// Whether the device's route costs money right now.
    ///
    /// The monitor answers the cellular question of 7.4. It does not
    /// gate the run: `allowsExpensiveNetworkAccess` on the session
    /// does that, and the system pauses the tasks rather than
    /// failing them.
    static var isOnCellular: Bool {
        monitor.currentPath.isExpensive
    }

    /// Low Data Mode, which Empo always respects and never toggles.
    static var isConstrained: Bool {
        monitor.currentPath.isConstrained
    }

    /// The line the UI shows while the system holds the tasks.
    static let waitingLine = ResourcePolicy.waitingForWiFiLine

    private static let monitor: NWPathMonitor = {
        let monitor = NWPathMonitor()
        monitor.start(queue: DispatchQueue(label: "sh.mateo.empo.backup.path"))
        return monitor
    }()

    /// Starts the path monitor, so the first read has an answer.
    static func start() {
        _ = monitor
    }
}
