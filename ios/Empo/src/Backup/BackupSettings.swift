import Foundation
import GameProbe

/// The app-wide backup settings of SPEC 13.14.
///
/// "Back up over cellular" lives in `BackupNetwork`, because the
/// policy reads it. This file holds the rest.
enum BackupSettings {

    /// The retention preset of 5.10. One app-wide value, with no
    /// per-game control.
    static var retention: RetentionPreset {
        get {
            UserDefaults.standard.string(forKey: DefaultsKey.backupRetention)
                .flatMap(RetentionPreset.init(rawValue:)) ?? .standard
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: DefaultsKey.backupRetention) }
    }
}

extension RetentionPreset {

    var label: String {
        switch self {
        case .small: return "Small"
        case .standard: return "Standard"
        case .deep: return "Deep"
        }
    }

    var line: String {
        switch self {
        case .small: return "Keeps about half the history of Standard."
        case .standard: return "Keeps the last 10 snapshots, 7 days, and 4 weeks."
        case .deep: return "Keeps about twice the history of Standard."
        }
    }
}
