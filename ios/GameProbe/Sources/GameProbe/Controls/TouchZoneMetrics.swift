import Foundation

public struct TouchZoneMetrics: Sendable {
    /// Usable touch area per orientation, in points. The screen
    /// size is fine. Translators keep their own edge margins.
    public var portraitWidth: Double
    public var portraitHeight: Double
    public var landscapeWidth: Double
    public var landscapeHeight: Double

    /// Usable zone insets from the screen edge, in points. Host chrome
    /// (toolbar, safe area, portrait game rect) sits above or below
    /// these.
    public var portraitTopInset: Double
    public var portraitBottomInset: Double
    public var landscapeTopInset: Double
    public var landscapeBottomInset: Double

    /// Lateral insets, in points. When a phone is on its side, it
    /// reserves the notch and home-indicator edges, and the host
    /// clamps X there. A layout anchored at the raw screen edge
    /// gets pushed into its neighbors.
    public var portraitLeadingInset: Double
    public var portraitTrailingInset: Double
    public var landscapeLeadingInset: Double
    public var landscapeTrailingInset: Double

    public init(
        portraitWidth: Double,
        portraitHeight: Double,
        landscapeWidth: Double,
        landscapeHeight: Double,
        portraitTopInset: Double = 0,
        portraitBottomInset: Double = 0,
        landscapeTopInset: Double = 0,
        landscapeBottomInset: Double = 0,
        portraitLeadingInset: Double = 0,
        portraitTrailingInset: Double = 0,
        landscapeLeadingInset: Double = 0,
        landscapeTrailingInset: Double = 0
    ) {
        self.portraitWidth = portraitWidth
        self.portraitHeight = portraitHeight
        self.landscapeWidth = landscapeWidth
        self.landscapeHeight = landscapeHeight
        self.portraitTopInset = portraitTopInset
        self.portraitBottomInset = portraitBottomInset
        self.landscapeTopInset = landscapeTopInset
        self.landscapeBottomInset = landscapeBottomInset
        self.portraitLeadingInset = portraitLeadingInset
        self.portraitTrailingInset = portraitTrailingInset
        self.landscapeLeadingInset = landscapeLeadingInset
        self.landscapeTrailingInset = landscapeTrailingInset
    }

    /// Reference metrics for tests, and a fallback when the host
    /// passes nothing: 402x874 / 874x402 (iPhone 17 Pro points).
    /// The insets match typical host chrome: landscapeTopInset ≈96
    /// is the toolbar line, portraitTopInset ≈369 estimates the 4:3
    /// game bottom, and the bottom insets are ≈40.
    public static let reference = TouchZoneMetrics(
        portraitWidth: 402,
        portraitHeight: 874,
        landscapeWidth: 874,
        landscapeHeight: 402,
        portraitTopInset: 369,
        portraitBottomInset: 40,
        landscapeTopInset: 96,
        landscapeBottomInset: 40,
        portraitLeadingInset: 0,
        portraitTrailingInset: 0,
        landscapeLeadingInset: 59,
        landscapeTrailingInset: 59
    )

    public func width(isLandscape: Bool) -> Double {
        isLandscape ? landscapeWidth : portraitWidth
    }

    public func height(isLandscape: Bool) -> Double {
        isLandscape ? landscapeHeight : portraitHeight
    }

    public func topInset(isLandscape: Bool) -> Double {
        isLandscape ? landscapeTopInset : portraitTopInset
    }

    public func bottomInset(isLandscape: Bool) -> Double {
        isLandscape ? landscapeBottomInset : portraitBottomInset
    }

    public func leadingInset(isLandscape: Bool) -> Double {
        isLandscape ? landscapeLeadingInset : portraitLeadingInset
    }

    public func trailingInset(isLandscape: Bool) -> Double {
        isLandscape ? landscapeTrailingInset : portraitTrailingInset
    }

    /// The vertical span available for grid or cluster layout after
    /// the host insets and the translator edge margins on both sides.
    public func usableHeight(isLandscape: Bool, edgeMargin: Double) -> Double {
        let h = height(isLandscape: isLandscape)
        return h - topInset(isLandscape: isLandscape) - bottomInset(isLandscape: isLandscape)
            - 2 * edgeMargin
    }
}
