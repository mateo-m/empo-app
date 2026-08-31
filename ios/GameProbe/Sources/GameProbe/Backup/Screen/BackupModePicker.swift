import Foundation

/// One row of the mode picker of SPEC 3.5.
public struct BackupModeOption: Equatable, Sendable {

    public var mode: BackupMode
    public var label: String
    /// The one line under the label.
    public var detail: String
    /// What this mode uploads for this game. The choice makes no
    /// sense without the figure, per 13.15.
    public var sizeBytes: Int64

    public init(mode: BackupMode, label: String, detail: String, sizeBytes: Int64) {
        self.mode = mode
        self.label = label
        self.detail = detail
        self.sizeBytes = sizeBytes
    }
}

/// The one picker behind two doors, per SPEC 3.5 and 13.15.
///
/// The first-backup ask and the mode row of the Backup sheet show
/// the same two rows and the same words. Build one picker and open
/// it from both.
public enum BackupModePicker {

    public static let title = "What gets backed up"

    /// A game above the threshold that was never asked reads this,
    /// per 13.15.
    public static let notChosenYet = "Not chosen yet"

    /// The row the ask carries beside the two options, per 3.7.
    public static let saveFileEditorLabel = "Choose save files"

    public static func options(fullBytes: Int64, slimBytes: Int64) -> [BackupModeOption] {
        [
            BackupModeOption(
                mode: .full,
                label: "The whole game",
                detail: "Puts the game back as it is now, on any device.",
                sizeBytes: fullBytes),
            BackupModeOption(
                mode: .slim,
                label: "Saves and settings only",
                detail: "Backs up your saves, settings, and control layouts.",
                sizeBytes: slimBytes),
        ]
    }

    public static func label(of mode: BackupMode?) -> String {
        guard let mode else { return notChosenYet }
        return mode == .full ? "The whole game" : "Saves and settings only"
    }

    public static func askTitle(gameName: String) -> String {
        "How much of \(gameName) do you want to back up?"
    }

    /// The ask fires against the lowest threshold among the enabled
    /// targets, and it names that target, per 3.5.
    ///
    /// `sizeText` and `thresholdText` carry the sizes in the words
    /// the caller formatted.
    public static func askBody(
        gameName: String, sizeText: String, targetLabel: String, thresholdText: String
    ) -> String {
        "\(gameName) is \(sizeText). \(targetLabel) asks about games over \(thresholdText)."
    }
}
