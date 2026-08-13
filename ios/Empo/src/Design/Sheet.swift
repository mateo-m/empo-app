import SwiftUI

/// The Empo bottom-sheet vocabulary. `StandardSheet` owns the
/// chrome every sheet used to repeat - navigation title, the
/// one-surface background, intrinsic sizing, brand tint - and the
/// `Sheet*` pieces below are the building blocks its content
/// composes. A sheet built from these cannot spell the chrome
/// wrong; the rules they encode live in `docs/sheet-design.md`.
///
/// Composition works like slots: the sheet declares WHAT it
/// shows, the vocabulary decides HOW it looks.
///
/// ```swift
/// StandardSheet(title: "Saves Recovered", emblem: "checkmark.seal") {
///     SheetProse("What happened and why.")
///     SheetCard { /* rows */ }
///     SheetFootnote("The fine print.")
///     SheetPrimaryButton("Done") { dismiss() }
/// }
/// ```

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
/// Two title styles, matching the two system sheet shapes:
///
///   - No emblem: the title sits inline in the navigation bar
///     (activity-summary style - image sources, build info).
///   - With `emblem:`: the title joins the symbol as ONE centered
///     identity block at the top of the content (welcome-sheet
///     style). Splitting them - a bar title plus a floating
///     symbol - reads as two competing anchors; never do that.
struct StandardSheet<Content: View>: View {
    let title: String
    /// SF Symbol name for the identity block; nil keeps the title
    /// in the navigation bar.
    var emblem: String?
    var surface: SheetSurface = .grouped
    /// Extra height for navigation chrome; see
    /// `intrinsicSheetDetent`.
    var chromeAllowance: CGFloat = 64
    /// Optional top-trailing toolbar action ("Cancel", "Close").
    var trailingButton: (label: String, action: () -> Void)?
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
        NavigationStack {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                if let emblem {
                    SheetIdentityBlock(systemName: emblem, title: title)
                }
                content
            }
            .padding(Spacing.xl)
            .intrinsicSheetContent(measuredHeight: $measuredHeight)
            .navigationTitle(emblem == nil ? title : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let trailingButton {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(trailingButton.label, action: trailingButton.action)
                    }
                }
            }
        }
        .intrinsicSheetDetent(
            measuredHeight: measuredHeight,
            chromeAllowance: chromeAllowance
        )
        .tint(.brand)
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

/// Leading-aligned explanation prose under the emblem.
struct SheetProse: View {
    let text: String

    init(_ text: String) { self.text = text }

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
