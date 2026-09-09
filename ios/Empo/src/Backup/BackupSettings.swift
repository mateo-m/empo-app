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
        case .small: return "Less"
        case .standard: return "Standard"
        case .deep: return "More"
        }
    }

    var line: String {
        switch self {
        case .small: return "Keeps the last 5 backups, one a day for 3 days, and one a week for 2 weeks."
        case .standard: return "Keeps the last 10 backups, one a day for 7 days, and one a week for 4 weeks."
        case .deep: return "Keeps the last 20 backups, one a day for 14 days, and one a week for 8 weeks."
        }
    }
}
