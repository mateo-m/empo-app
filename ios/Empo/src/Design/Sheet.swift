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
/// StandardSheet(title: "Saves Recovered") {
///     SheetEmblem(systemName: "checkmark.seal")
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
struct StandardSheet<Content: View>: View {
    let title: String
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
                content
            }
            .padding(Spacing.xl)
            .intrinsicSheetContent(measuredHeight: $measuredHeight)
            .navigationTitle(title)
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

/// The sheet's identity mark: one brand-tinted symbol, centered.
/// The emblem is the only centered element on a sheet - reading
/// content stays leading - and it gets extra top air so it reads
/// as its own zone, the way the system's welcome sheets treat
/// theirs.
struct SheetEmblem: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 48, weight: .medium))
            .foregroundStyle(Color.brand)
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
