import SwiftUI

/// Size scale for `IconButton`. Mirrors `ButtonSize` so call sites can
/// pick a semantic scale instead of hardcoding points. The enum
/// resolves to a frame side length; the SF Symbol scales with it via
/// the existing 0.42 ratio in `IconButton.icon`.
enum IconButtonSize {
    case sm, md, lg

    var points: CGFloat {
        switch self {
        case .sm: 32
        case .md: AppSize.toolbarButton   // 38, the default
        case .lg: 44
        }
    }
}

struct IconButton: View {
    let systemName: String
    let style: Style
    let size: CGFloat
    let tint: Color?
    let contentTransition: ContentTransition
    private let action: (() -> Void)?

    enum Style { case primary, secondary, outline }

    init(_ systemName: String, style: Style = .outline, size: CGFloat = AppSize.toolbarButton, tint: Color? = nil, contentTransition: ContentTransition = .identity, action: @escaping () -> Void) {
        self.systemName = systemName
        self.style = style
        self.size = size
        self.tint = tint
        self.contentTransition = contentTransition
        self.action = action
    }

    init(_ systemName: String, style: Style = .outline, size: IconButtonSize, tint: Color? = nil, contentTransition: ContentTransition = .identity, action: @escaping () -> Void) {
        self.init(systemName, style: style, size: size.points, tint: tint, contentTransition: contentTransition, action: action)
    }

    init(_ systemName: String, style: Style = .outline, size: CGFloat = AppSize.toolbarButton, tint: Color? = nil) {
        self.systemName = systemName
        self.style = style
        self.size = size
        self.tint = tint
        self.contentTransition = .identity
        self.action = nil
    }

    init(_ systemName: String, style: Style = .outline, size: IconButtonSize, tint: Color? = nil) {
        self.init(systemName, style: style, size: size.points, tint: tint)
    }

    var body: some View {
        if let action {
            Button(action: action) { icon }
                .buttonStyle(IconPressStyle())
        } else {
            icon
        }
    }

    private var foregroundColor: Color {
        if let tint { return tint }
        switch style {
        case .primary: return .white
        case .secondary: return .brand
        case .outline: return .primary.opacity(Alpha.textMuted)
        }
    }

    private var icon: some View {
        Image(systemName: systemName)
            .contentTransition(contentTransition)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(foregroundColor)
            .frame(width: size, height: size)
            .background {
                if style == .outline {
                    Circle().strokeBorder(.quaternary.opacity(0.5), lineWidth: 1)
                }
            }
            .modifier(IconGlassModifier(style: style, hasAction: action != nil))
    }
}

private struct IconGlassModifier: ViewModifier {
    let style: IconButton.Style
    let hasAction: Bool

    func body(content: Content) -> some View {
        switch style {
        case .primary:
            content.glassEffect(.regular.tint(.brand).interactive(), in: .circle)
        case .secondary:
            content.glassEffect(.regular.tint(.brand.opacity(Alpha.brandTintBackground)).interactive(), in: .circle)
        case .outline:
            content.glassEffect(hasAction ? .regular.interactive() : .regular, in: .circle)
        }
    }
}

private struct IconPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { Haptics.tap() }
            }
    }
}
