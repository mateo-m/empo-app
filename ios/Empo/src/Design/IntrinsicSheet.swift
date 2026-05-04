import SwiftUI

/// Helpers for sheets that size themselves to their content's intrinsic
/// height, falling back to `.medium` while the first measurement is
/// pending. Three sheets in the app share this pattern (image sources,
/// player menu, build info), so the layout + detent boilerplate lives
/// here.
extension View {
    /// Apply to the sheet's inner content. Asks the view to size
    /// itself vertically and writes the measured height into `binding`.
    /// Caller controls padding so each sheet can pick its own gutter.
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
    /// falls back to `.medium` otherwise. Default allowance covers a
    /// standard nav bar + drag indicator.
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
