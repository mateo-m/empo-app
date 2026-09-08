import SwiftUI

/// The Empo bottom-sheet vocabulary. `StandardSheet` owns the
/// chrome every sheet used to repeat - navigation title, the
/// one-surface background, intrinsic sizing, brand tint - and the
/// `Sheet*` pieces below are the building blocks its content
/// composes. A sheet built from these cannot spell the chrome
/// wrong. The rules they encode live in `docs/sheet-design.md`.
///
/// Composition works like slots: the sheet declares WHAT it
/// shows, the vocabulary decides HOW it looks.
///
/// ```swift
/// StandardSheet(title: "Saves recovered", emblem: "checkmark.seal") {
///     SheetBodyText("What happened and why.")
///     SheetCard { /* rows */ }
///     SheetFootnote("The fine print.")
///     SheetPrimaryButton("Done") { dismiss() }
/// }
/// ```

/// The icon in the sheet's top-trailing corner. Close is the safe
/// exit of the first step. Back returns to the step before.
struct SheetBarAction {
    enum Symbol { case close, back }

    let label: String
    let symbol: Symbol
    let action: () -> Void

    init(_ label: String, symbol: Symbol = .close, action: @escaping () -> Void) {
        self.label = label
        self.symbol = symbol
        self.action = action
    }
}

/// The sheet's surface treatment.
enum SheetSurface {
    /// One opaque grouped surface across the whole sheet - title
    /// area, content, and the stretch region a pull-up reveals.
    /// The default for every library and settings sheet.
    case grouped
    /// The system's translucent material. Only for sheets that
    /// float over a running game and must keep it visible
    /// (`PlayerMoreSheet`).
    case material
}

/// The standard content-sized Empo sheet.
///
/// Two title styles:
///
///   - No emblem: the title sits at the top of the content,
///     leading, with the corner icon beside it.
///   - With `emblem:`: the title joins the symbol as ONE centered
///     identity block (welcome-sheet style). The icon, when there
///     is one, floats in a top corner over that block.
///
/// A multi-step sheet swaps the title, the icon and the content in
/// one `withAnimation`. The detent follows the measured height with
/// the same motion, so the sheet grows and shrinks with each step.
struct StandardSheet<Content: View>: View {
    let title: String
    /// SF Symbol name for the identity block. A nil value keeps the
    /// title leading at the top of the content.
    var emblem: String?
    var surface: SheetSurface = .grouped
    /// Optional corner icon action.
    var barAction: SheetBarAction?
    @ViewBuilder var content: Content

    @State private var measuredHeight: CGFloat = 0

    var body: some View {
        switch surface {
        case .grouped:
            core.presentationBackground(Color(.systemGroupedBackground))
        case .material:
            core
        }
    }

    private var core: some View {
        // The scroll container does two jobs: content taller than
        // the screen scrolls instead of clipping, and a sheet
        // pulled past its detent keeps the content pinned to the
        // top (a bare VStack centers in the stretched space).
        ScrollView {
            stack
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .top)
                // A view on its way out still takes its space until
                // its transition ends, so the visible stack is the
                // wrong thing to measure during a step change. The
                // copy below has no animation, so it is already the
                // size of the next step when the change begins.
                .background {
                    stack
                        .hidden()
                        .accessibilityHidden(true)
                        .transaction { $0.animation = nil }
                        .intrinsicSheetContent(measuredHeight: $measuredHeight)
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        // During a detent change UIKit sizes this view to the new
        // height at once and animates only the sheet's frame. With
        // clipping on, the scroll view cuts the old step off in one
        // frame. With it off, the sheet's moving edge does the cut.
        .scrollClipDisabled()
        .intrinsicSheetDetent(measuredHeight: measuredHeight, chromeAllowance: 0)
        .tint(.brand)
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            header
            content
        }
        .padding([.horizontal, .top], Spacing.xl)
        .padding(.top, Spacing.md)
        // The home indicator's safe area already pads the bottom. A
        // full gutter under it reads as a hole.
        .padding(.bottom, Spacing.sm)
    }

    /// The title is centered. Back leads, close trails, level with
    /// the title's first line.
    @ViewBuilder private var header: some View {
        if let emblem {
            SheetIdentityBlock(systemName: emblem, title: title)
                .overlay(alignment: .top) {
                    if let barAction { placed(icon: barAction) }
                }
        } else {
            ZStack(alignment: .top) {
                Text(title)
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 44 + Spacing.lg)
                    .id(title)
                    .transition(.sheetStep)
                if let barAction { placed(icon: barAction) }
            }
        }
    }

    /// Back leads, close trails. A step change swaps one for the
    /// other with the same blur as the rest of the sheet.
    private func placed(icon action: SheetBarAction) -> some View {
        icon(action)
            .frame(maxWidth: .infinity, alignment: action.symbol == .back ? .leading : .trailing)
            .id(action.symbol)
            .transition(.sheetStep)
    }

    private func icon(_ action: SheetBarAction) -> some View {
        Button(action: action.action) {
            Image(systemName: action.symbol == .close ? "xmark.circle.fill" : "chevron.left.circle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44, alignment: .top)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.label)
    }
}

/// The sheet's identity: one brand-tinted symbol with the title
/// directly under it, centered as a single block, the way the
/// system's welcome sheets compose theirs. The identity block is
/// the only centered content on a sheet - everything below stays
/// leading. Rendered by `StandardSheet` when `emblem:` is set.
private struct SheetIdentityBlock: View {
    let systemName: String
    let title: String

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: systemName)
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(Color.brand)
            Text(title)
                .font(.title2.bold())
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, Spacing.md)
    }
}

/// Leading-aligned explanation text under the title.
struct SheetBodyText: View {
    let text: AttributedString

    init(_ text: String) { self.text = AttributedString(text) }

    /// `name` is the game or target the line talks about. It reads in
    /// the primary color and a heavier weight, so it stands out of
    /// the secondary text around it.
    init(_ text: String, naming name: String) {
        var attributed = AttributedString(text)
        for range in text.ranges(of: name) {
            guard let marked = Range(range, in: attributed) else { continue }
            attributed[marked].foregroundColor = .primary
            attributed[marked].font = .subheadline.weight(.semibold)
        }
        self.text = attributed
    }

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Leading-aligned fine print near the sheet's bottom.
struct SheetFootnote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Grouped card that hosts a sheet's rows. Destructive actions
/// get their own card, separate from the regular rows.
struct SheetCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: Radius.md))
    }
}

/// Hairline separator between card rows, indented past the row's
/// leading column so it only spans the text area.
struct SheetRowSeparator: View {
    /// Width of the leading column (thumbnail or icon) the indent
    /// clears.
    var leadingColumn: CGFloat = 44

    var body: some View {
        Divider()
            .padding(.leading, Spacing.lg + leadingColumn + Spacing.lg)
    }
}

/// The sheet's one full-width primary action, at the bottom.
struct SheetPrimaryButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryButtonStyle())
    }
}

/// The step toward a destructive answer, or any second choice that
/// needs no weight of its own. Plain text, full width, 44pt tall.
struct SheetQuietButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The one destructive answer of a confirmation step. Red, full
/// width, and never the brand primary.
struct SheetDestructiveButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(role: .destructive, action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryButtonStyle(tint: .destructive))
    }
}

/// The way one step of a sheet gives way to the next: the old
/// content blurs and fades out while the new one blurs and fades in.
private struct SheetStepFade: ViewModifier {
    let radius: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content.blur(radius: radius).opacity(opacity)
    }
}

extension AnyTransition {
    static let sheetStep = AnyTransition.modifier(
        active: SheetStepFade(radius: 12, opacity: 0),
        identity: SheetStepFade(radius: 0, opacity: 1))
}
