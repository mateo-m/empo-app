import SwiftUI

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

    init(_ systemName: String, style: Style = .outline, size: CGFloat = AppSize.toolbarButton, tint: Color? = nil) {
        self.systemName = systemName
        self.style = style
        self.size = size
        self.tint = tint
        self.contentTransition = .identity
        self.action = nil
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
        case .outline: return .primary.opacity(0.7)
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
            content.glassEffect(.regular.tint(.brand.opacity(0.1)).interactive(), in: .circle)
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
