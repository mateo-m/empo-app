import Foundation

public struct TouchZoneMetrics: Sendable {
    /// Usable touch area per orientation, in points (screen size is
    /// fine; translators keep their own edge margins).
    public var portraitWidth: Double
    public var portraitHeight: Double
    public var landscapeWidth: Double
    public var landscapeHeight: Double

    /// Usable zone insets from the screen edge, in points. Host chrome
    /// (toolbar, safe area, portrait game rect) lives above/below these.
    public var portraitTopInset: Double
    public var portraitBottomInset: Double
    public var landscapeTopInset: Double
    public var landscapeBottomInset: Double

    /// Lateral insets, in points. Landscape phones reserve the notch /
    /// home-indicator edges (the host clamps X there); layouts anchored
    /// at the raw screen edge get pushed into their neighbors.
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

    /// Reference metrics for tests and as a fallback when the host
    /// passes nothing: 402x874 / 874x402 (iPhone 17 Pro points).
    /// Insets mirror typical host chrome: landscape toolbar line ≈96,
    /// portrait 4:3 game-bottom estimate ≈369, bottoms ≈40.
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

    /// Vertical span available for grid/cluster layout after host
    /// insets and translator edge margins on both sides.
    public func usableHeight(isLandscape: Bool, edgeMargin: Double) -> Double {
        let h = height(isLandscape: isLandscape)
        return h - topInset(isLandscape: isLandscape) - bottomInset(isLandscape: isLandscape)
            - 2 * edgeMargin
    }
}
