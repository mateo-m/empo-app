import Foundation

/// The user's answer to the sheet of SPEC 13.19.
public enum BackupNotificationAnswer: Equatable, Sendable {
    case notNow
    case turnOn
}

/// What the answer does.
public struct BackupNotificationAskEffect: Equatable, Sendable {

    /// Whether Empo opens the system prompt now.
    public var showsTheSystemPrompt: Bool
    /// Whether Empo records that it spent its one chance at the
    /// system prompt.
    public var marksThePromptSpent: Bool
    /// Whether this sheet may come back by itself.
    public var showsTheSheetAgain: Bool

    public init(
        showsTheSystemPrompt: Bool, marksThePromptSpent: Bool, showsTheSheetAgain: Bool
    ) {
        self.showsTheSystemPrompt = showsTheSystemPrompt
        self.marksThePromptSpent = marksThePromptSpent
        self.showsTheSheetAgain = showsTheSheetAgain
    }
}

/// What the row above Backup history does, per SPEC 13.19.
public enum BackupNotificationRowAction: Equatable, Sendable {
    case showTheSystemPrompt
    case openTheSettingsApp
}

/// The one sheet that comes before the system prompt, per SPEC
/// 13.19.
///
/// iOS gives an app one chance at that prompt, and a user who taps
/// "Don't Allow" can only change it in the Settings app. So Empo
/// states the reason first, in its own sheet, and spends the one
/// chance only on a user who already said yes.
public enum BackupNotificationAsk {

    public static let title = "Empo can tell you when a backup stops"

    public static let body = """
        You get a message only when a backup stops and only you can start it again: \
        a service needs a new sign-in, a service is full, or this iPhone has no space left. \
        A backup that works stays quiet.
        """

    public static let notNowLabel = "Not now"
    public static let turnOnLabel = "Turn on"

    /// The row the Backups screen carries above Backup history while
    /// the permission is off.
    public static let rowLabel = "Turn on backup notifications"

    /// "Not now" opens nothing and spends nothing, and the sheet
    /// never comes back by itself.
    public static func effect(of answer: BackupNotificationAnswer)
        -> BackupNotificationAskEffect
    {
        switch answer {
        case .notNow:
            return BackupNotificationAskEffect(
                showsTheSystemPrompt: false, marksThePromptSpent: false,
                showsTheSheetAgain: false)
        case .turnOn:
            return BackupNotificationAskEffect(
                showsTheSystemPrompt: true, marksThePromptSpent: true,
                showsTheSheetAgain: false)
        }
    }

    /// The row shows the system prompt while iOS still allows it,
    /// and opens the Empo page in the Settings app after that.
    public static func rowAction(systemMayStillPrompt: Bool) -> BackupNotificationRowAction {
        systemMayStillPrompt ? .showTheSystemPrompt : .openTheSettingsApp
    }
}
