import SwiftUI

/// Helpers for sheets that size themselves to the intrinsic height of
/// their content. They fall back to `.medium` while the first
/// measurement is pending. Several sheets share this pattern (image
/// sources, player menu, build info, save recovery), so the layout
/// and detent boilerplate lives here. The full sheet rules - surface,
/// anatomy, alignment, metrics - are in `ios/Empo/docs/sheet-design.md`.
extension View {
    /// Apply to the sheet's inner content. Asks the view to size
    /// itself vertically and writes the measured height into `binding`.
    /// The caller controls padding so each sheet can pick its own gutter.
    func intrinsicSheetContent(measuredHeight binding: Binding<CGFloat>) -> some View {
        self
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .top)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { newHeight in
                binding.wrappedValue = newHeight
            }
    }

    /// Apply to the sheet's outermost view. Sizes the sheet to
    /// `measuredHeight + chromeAllowance` once measurement settles, or
    /// falls back to `.medium` otherwise. The default allowance covers
    /// a standard nav bar and drag indicator.
    func intrinsicSheetDetent(
        measuredHeight: CGFloat,
        chromeAllowance: CGFloat = 64
    ) -> some View {
        self
            .presentationDetents(
                measuredHeight > 0
                    ? [.height(measuredHeight + chromeAllowance)]
                    : [.medium]
            )
            .presentationDragIndicator(.visible)
    }
}
