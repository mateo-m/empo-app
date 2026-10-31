// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

/// The Empo bottom-sheet vocabulary. `StandardSheet` owns the
/// chrome every sheet used to repeat - navigation title, the
/// one-surface background, intrinsic sizing, brand tint - and the
/// `Sheet*` pieces below are the building blocks its content
/// composes. A sheet built from these cannot spell the chrome
/// wrong. The rules they encode live in the Sheets section of
/// `ios/Empo/docs/design-system.md`.
///
/// Composition works like slots: the sheet declares WHAT it
/// shows, the vocabulary decides HOW it looks.
///
/// ```swift
/// StandardSheet(title: "Saves recovered", emblem: "checkmark.seal") {
///     SheetBodyText("What happened and why.")
///     SheetCard { /* rows */ }
///     SheetFootnote("The fine print.")
/// } footer: {
///     SheetPrimaryButton("Done") { dismiss() }
/// }
/// ```

/// A navigation-bar action on a sheet ("Cancel", "Close").
struct SheetBarAction {
    let label: LocalizedStringResource
    let action: () -> Void

    init(_ label: LocalizedStringResource, action: @escaping () -> Void) {
        self.label = label
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
/// Two title styles, matching the two system sheet shapes:
///
///   - No emblem: the title sits inline in the navigation bar
///     (activity-summary style - image sources, build info).
///   - With `emblem:`: the title joins the symbol as ONE centered
///     identity block at the top of the content (welcome-sheet
///     style). Splitting them - a bar title plus a floating
///     symbol - reads as two competing anchors. Never do that.
struct StandardSheet<Content: View, Footer: View>: View {
    let title: LocalizedStringResource
    /// SF Symbol name for the identity block. A nil value keeps the
    /// title in the navigation bar.
    var emblem: String?
    var surface: SheetSurface = .grouped
    /// Extra height for navigation chrome. A nil value derives it from
    /// the bar: the full bar allowance with a bar, only the
    /// grabber zone without one.
    var chromeAllowance: CGFloat?
    /// Optional top-trailing toolbar action.
    var trailingButton: SheetBarAction?
    @ViewBuilder var content: Content
    /// Stays at the bottom while the content scrolls.
    @ViewBuilder var footer: Footer

    @State private var headerSize = IntrinsicSheetSize()
    @State private var contentSize = IntrinsicSheetSize()
    @State private var footerSize = IntrinsicSheetSize()
    @State private var fade = ScrollEdgeFade()

    /// An identity-block sheet with no toolbar action has an empty
    /// bar. Hiding it lets the sheet hug its content.
    private var barHidden: Bool {
        emblem != nil && trailingButton == nil
    }

    private var hasFooter: Bool { Footer.self != EmptyView.self }

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
            VStack(spacing: 0) {
                if let emblem {
                    SheetIdentityBlock(systemName: emblem, title: title)
                        .padding(Spacing.xl)
                        .intrinsicSheetContent(size: $headerSize)
                }
                // Content taller than the screen scrolls, and a sheet
                // pulled past its detent keeps the content at the top
                // and the footer at the bottom.
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.xl) {
                        content
                    }
                    .padding(.horizontal, Spacing.xl)
                    // The gaps to the header and the footer stay outside the
                    // scroll view, so scrolled content keeps clear of them.
                    .padding(.top, emblem == nil ? Spacing.xl : 0)
                    .padding(.bottom, hasFooter ? 0 : Spacing.xl)
                    .intrinsicSheetContent(size: $contentSize)
                }
                .scrollBounceBehavior(.basedOnSize)
                .onScrollGeometryChange(for: ScrollEdgeFade.self, of: ScrollEdgeFade.init) { _, new in
                    fade = new
                }
                // The content stays visible under the bar and the home
                // indicator, as in any scroll view.
                .mask { ScrollEdgeFadeMask(fade: fade).ignoresSafeArea() }
                if hasFooter {
                    VStack(spacing: 0) {
                        footer
                    }
                    .padding(Spacing.xl)
                    .intrinsicSheetContent(size: $footerSize)
                }
            }
            .navigationTitle(emblem == nil ? Text(title) : Text(verbatim: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(barHidden ? .hidden : .automatic, for: .navigationBar)
            .toolbar {
                if let trailingButton {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(trailingButton.label, action: trailingButton.action)
                    }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            headerSize.width = width
            contentSize.width = width
            footerSize.width = width
        }
        .intrinsicSheetDetent(
            measuredHeight: contentSize.height > 0
                ? headerSize.height + contentSize.height + footerSize.height : 0,
            chromeAllowance: chromeAllowance ?? (barHidden ? 28 : 64)
        )
        .tint(.brand)
    }
}

extension StandardSheet where Footer == EmptyView {
    init(
        title: LocalizedStringResource,
        emblem: String? = nil,
        surface: SheetSurface = .grouped,
        chromeAllowance: CGFloat? = nil,
        trailingButton: SheetBarAction? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title, emblem: emblem, surface: surface, chromeAllowance: chromeAllowance,
            trailingButton: trailingButton, content: content, footer: { EmptyView() })
    }
}

/// How far the content runs past each edge of a sheet's scroll view,
/// from 0 at the edge to 1 at `length` points or more.
private struct ScrollEdgeFade: Equatable {
    static let length: CGFloat = 24

    var top: CGFloat = 0
    var bottom: CGFloat = 0

    init() {}

    init(_ geometry: ScrollGeometry) {
        // `visibleRect` includes the safe area insets, and
        // `containerSize` does not.
        let hiddenAbove = geometry.visibleRect.minY
        let hiddenBelow = geometry.contentSize.height - geometry.visibleRect.maxY
        top = min(max(hiddenAbove / Self.length, 0), 1)
        bottom = min(max(hiddenBelow / Self.length, 0), 1)
    }
}

/// Fades the content out at an edge only as far as it runs past that
/// edge, so the fade grows as the user scrolls.
private struct ScrollEdgeFadeMask: View {
    let fade: ScrollEdgeFade

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [.black.opacity(1 - fade.top), .black], startPoint: .top, endPoint: .bottom
            )
            .frame(height: ScrollEdgeFade.length)
            Rectangle()
            LinearGradient(
                colors: [.black, .black.opacity(1 - fade.bottom)], startPoint: .top, endPoint: .bottom
            )
            .frame(height: ScrollEdgeFade.length)
        }
    }
}

/// The sheet's identity: one brand-tinted symbol with the title
/// directly under it, centered as a single block, the way the
/// system's welcome sheets compose theirs. The identity block is
/// the only centered content on a sheet - everything below stays
/// leading. Rendered by `StandardSheet` when `emblem:` is set.
private struct SheetIdentityBlock: View {
    let systemName: String
    let title: LocalizedStringResource

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

/// Leading-aligned explanation text under the emblem.
struct SheetBodyText: View {
    let text: LocalizedStringResource

    init(_ text: LocalizedStringResource) { self.text = text }

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
    let text: LocalizedStringResource

    init(_ text: LocalizedStringResource) { self.text = text }

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
    let title: LocalizedStringResource
    let action: () -> Void

    init(_ title: LocalizedStringResource, action: @escaping () -> Void) {
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
