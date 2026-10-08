/// Which profile a game's pin draws profile-owned files from (the
/// screen placement, the skin art). One rule, shared, so the screen
/// region and the skin can never disagree on the active profile.
public enum ProfileSource {
    /// nil means no profile applies: the game's own layout, or no
    /// default profile is set.
    public static func name(pin: LayoutPin, defaultProfileName: String?) -> String? {
        switch pin {
        case .profile(let name):
            return name
        case .gameLayout:
            return nil
        case .defaultProfile, .followChain:
            return defaultProfileName
        }
    }
}
