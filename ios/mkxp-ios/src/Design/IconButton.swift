import SwiftUI

struct IconButton: View {
    let systemName: String
    let style: Style
    let size: CGFloat
    let contentTransition: ContentTransition
    private let action: (() -> Void)?

    enum Style { case outline, glass }

    init(_ systemName: String, style: Style = .outline, size: CGFloat = AppSize.toolbarButton, contentTransition: ContentTransition = .identity, action: @escaping () -> Void) {
        self.systemName = systemName
        self.style = style
        self.size = size
        self.contentTransition = contentTransition
        self.action = action
    }

    init(_ systemName: String, style: Style = .glass, size: CGFloat = AppSize.toolbarButton) {
        self.systemName = systemName
        self.style = style
        self.size = size
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

    private var icon: some View {
        Image(systemName: systemName)
            .contentTransition(contentTransition)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(style == .outline ? Color.primary.opacity(0.7) : .primary)
            .frame(width: size, height: size)
            .background {
                if style == .outline {
                    Circle().strokeBorder(.quaternary.opacity(0.5), lineWidth: 1)
                }
            }
            .glassEffect(
                action != nil ? .regular.interactive() : .regular,
                in: .circle
            )
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
