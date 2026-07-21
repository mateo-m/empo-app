import Foundation

public enum TouchSectionCompletion {
    /// Default d-pad centers and size in fraction / point units for each
    /// orientation. Host supplies Empo's built-in defaults.
    public struct DefaultDpadSpec: Sendable {
        public var portraitX: Double
        public var portraitY: Double
        public var landscapeX: Double
        public var landscapeY: Double
        public var size: Double

        public init(
            portraitX: Double,
            portraitY: Double,
            landscapeX: Double,
            landscapeY: Double,
            size: Double = 140
        ) {
            self.portraitX = portraitX
            self.portraitY = portraitY
            self.landscapeX = landscapeX
            self.landscapeY = landscapeY
            self.size = size
        }
    }

    /// When exactly one orientation key is present, derives the missing
    /// orientation in-memory. Both keys present (including explicit `{}`)
    /// are left unchanged.
    public static func complete(
        _ section: TouchSection,
        metrics: TouchZoneMetrics,
        defaultDpad: DefaultDpadSpec
    ) -> (section: TouchSection, involvedDerivation: Bool) {
        let hasPortrait = section.portrait != nil
        let hasLandscape = section.landscape != nil

        guard hasPortrait != hasLandscape else {
            return (section, false)
        }

        if hasPortrait, let portrait = section.portrait {
            let obstacle = defaultDpadInPoints(
                x: defaultDpad.landscapeX,
                y: defaultDpad.landscapeY,
                size: defaultDpad.size,
                metrics: metrics,
                isLandscape: true
            )
            let derived = OrientationDerivation.derive(
                from: portrait,
                sourceIsLandscape: false,
                metrics: metrics,
                defaultDpad: obstacle
            )
            return (TouchSection(portrait: portrait, landscape: derived), true)
        }

        if hasLandscape, let landscape = section.landscape {
            let obstacle = defaultDpadInPoints(
                x: defaultDpad.portraitX,
                y: defaultDpad.portraitY,
                size: defaultDpad.size,
                metrics: metrics,
                isLandscape: false
            )
            let derived = OrientationDerivation.derive(
                from: landscape,
                sourceIsLandscape: true,
                metrics: metrics,
                defaultDpad: obstacle
            )
            return (TouchSection(portrait: derived, landscape: landscape), true)
        }

        return (section, false)
    }

    private static func defaultDpadInPoints(
        x: Double,
        y: Double,
        size: Double,
        metrics: TouchZoneMetrics,
        isLandscape: Bool
    ) -> (x: Double, y: Double, size: Double) {
        let width = metrics.width(isLandscape: isLandscape)
        let height = metrics.height(isLandscape: isLandscape)
        return (x * width, y * height, size)
    }
}
