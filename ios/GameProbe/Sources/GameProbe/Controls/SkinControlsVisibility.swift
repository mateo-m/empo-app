/// How the touch controls show over profile skin art.
///
/// `mounted` decides whether the controls exist (and take touches).
/// `drawn` decides whether they paint anything. With art, the painted
/// buttons are the visible ones, so the controls stay mounted but
/// undrawn. Hiding (the eye toggle, or `OverlayVisibility` when a pad
/// connects) still removes them entirely, art or not, so a resting
/// hand cannot press anything while a controller is in use.
public struct SkinControlsVisibility: Equatable, Sendable {
    public let mounted: Bool
    public let drawn: Bool

    public static func resolve(
        hasArt: Bool, showButtonOutlines: Bool, editMode: Bool, controlsHidden: Bool
    ) -> SkinControlsVisibility {
        SkinControlsVisibility(
            // Edit mode always shows the controls: the player is
            // arranging them.
            mounted: !controlsHidden || editMode,
            drawn: !hasArt || showButtonOutlines || editMode
        )
    }
}
