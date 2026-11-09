import SwiftUI

struct PlusBadge: View {
    var body: some View {
        // A Label moves the row separator of a List row to its own text.
        HStack(spacing: Spacing.xs) {
            Image(systemName: "lock.fill").foregroundStyle(.brand)
            plusWord.plusShine()
        }
    }
}

/// Give the view that holds the text `.plusShine()` for the light.
/// Not for a button title: orange on an orange button cannot be read.
let plusWord = Text(verbatim: "Plus").fontWeight(.bold).foregroundStyle(.brand)
    .customAttribute(PlusMark())

private struct PlusMark: TextAttribute {}

extension View {
    func plusShine() -> some View { modifier(PlusShine(shape: nil)) }

    /// For a button with a white title, which would hide the light.
    func plusShine(over shape: some Shape) -> some View { modifier(PlusShine(shape: AnyShape(shape))) }
}

private struct PlusShine: ViewModifier {
    let shape: AnyShape?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0.0

    func body(content: Content) -> some View {
        let phase = reduceMotion ? 0 : phase
        Group {
            if let shape {
                content.modifier(PlusGlint(phase: phase, shape: shape))
            } else {
                content.textRenderer(PlusShineRenderer(phase: phase))
            }
        }
        .onAppear {
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { self.phase = 0 }
            withAnimation(.easeInOut(duration: 0.9).delay(0.35)) { self.phase = 1 }
        }
    }
}

/// The band is tilted, so it starts and ends past the corners of
/// `rect`. Otherwise light stays on a corner at phase 0 and 1.
private enum PlusBand {
    static let gradient = Gradient(colors: [.white.opacity(0), .white.opacity(0.5), .white.opacity(0)])
    private static let direction = CGVector(
        dx: cos(Angle.degrees(22).radians), dy: sin(Angle.degrees(22).radians))

    static func ends(in rect: CGRect, phase: Double) -> (start: CGPoint, end: CGPoint) {
        let width = rect.width * 0.6
        let first = along(CGPoint(x: rect.minX, y: rect.minY))
        let last = along(CGPoint(x: rect.maxX, y: rect.maxY))
        let start = first - width + (last - first + width) * phase
        return (point(at: start), point(at: start + width))
    }

    private static func along(_ point: CGPoint) -> Double {
        point.x * direction.dx + point.y * direction.dy
    }

    private static func point(at distance: Double) -> CGPoint {
        CGPoint(x: distance * direction.dx, y: distance * direction.dy)
    }
}

private struct PlusShineRenderer: TextRenderer, Animatable {
    var phase: Double

    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                guard run[PlusMark.self] != nil else {
                    context.draw(run)
                    continue
                }
                context.drawLayer { layer in
                    layer.draw(run)
                    let bounds = run.typographicBounds.rect
                    let band = PlusBand.ends(in: bounds, phase: phase)
                    layer.blendMode = .sourceAtop
                    layer.fill(
                        Path(bounds),
                        with: .linearGradient(PlusBand.gradient, startPoint: band.start, endPoint: band.end))
                }
            }
        }
    }
}

/// A plain overlay whose gradient points change with the state did not
/// animate on the location screen.
private struct PlusGlint: ViewModifier, Animatable {
    var phase: Double
    let shape: AnyShape
    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { proxy in
                let size = CGSize(width: max(proxy.size.width, 1), height: max(proxy.size.height, 1))
                let band = PlusBand.ends(in: CGRect(origin: .zero, size: size), phase: phase)
                LinearGradient(
                    gradient: PlusBand.gradient,
                    startPoint: UnitPoint(x: band.start.x / size.width, y: band.start.y / size.height),
                    endPoint: UnitPoint(x: band.end.x / size.width, y: band.end.y / size.height))
            }
            .clipShape(shape)
            .allowsHitTesting(false)
        }
    }
}
