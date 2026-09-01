import Foundation
import GameProbe
import Network

/// The one app-wide network switch of SPEC 7.4, and what the device
/// is connected to right now.
///
/// The rules live in `NetworkPolicy` and `ResourcePolicy`, inside
/// GameProbe. This file stores the switch and reads the path.
///
/// The Backups screen of 13.14 holds the switch.
enum BackupNetwork {

    /// "Back up over cellular". Off by default, and there is no
    /// per-target override.
    static var backsUpOverCellular: Bool {
        get { UserDefaults.standard.bool(forKey: DefaultsKey.backupOverCellular) }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.backupOverCellular) }
    }

    /// One run over cellular, per 7.4. The manual ask and the 21-day
    /// banner set it, it covers the whole run, and it never changes
    /// the stored switch. The run clears it at its end.
    ///
    /// The background session fixes its configuration at creation,
    /// so the per-request flags of `BackupTransferSession.request`
    /// are what carry this to the uploads in flight.
    static var allowsThisRunOverCellular = false

    static var policy: NetworkPolicy {
        NetworkPolicy(backsUpOverCellular: backsUpOverCellular || allowsThisRunOverCellular)
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
