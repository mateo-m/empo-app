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
    /// `measuredHeight + chromeAllowance`, or falls back to `.medium`
    /// while the first measurement is pending. Later changes animate
    /// the sheet to the new height.
    func intrinsicSheetDetent(
        measuredHeight: CGFloat,
        chromeAllowance: CGFloat = 64
    ) -> some View {
        modifier(
            IntrinsicSheetDetent(
                height: measuredHeight > 0 ? measuredHeight + chromeAllowance : 0))
    }
}

/// SwiftUI's `presentationDetents` snaps to a new height. UIKit's
/// `animateChanges` moves there. The first height goes through
/// SwiftUI so the sheet presents at the right size, and every change
/// after it goes through UIKit. SwiftUI's value never changes again,
/// so it never writes over the UIKit detent.
private struct IntrinsicSheetDetent: ViewModifier {
    let height: CGFloat

    @State private var firstHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .presentationDetents(firstHeight > 0 ? [.height(firstHeight)] : [.medium])
            .presentationDragIndicator(.visible)
            .background(DetentAnimator(height: height, firstHeight: $firstHeight))
    }
}

private struct DetentAnimator: UIViewRepresentable {
    let height: CGFloat
    @Binding var firstHeight: CGFloat

    final class Coordinator {
        var currentHeight: CGFloat = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        guard height > 0 else { return }
        if firstHeight == 0 {
            context.coordinator.currentHeight = height
            DispatchQueue.main.async { firstHeight = height }
            return
        }
        guard height != context.coordinator.currentHeight else { return }
        context.coordinator.currentHeight = height
        DispatchQueue.main.async {
            guard let sheet = Self.sheet(of: view) else { return }
            let id = UISheetPresentationController.Detent.Identifier("empo-\(Int(height))")
            let detent = UISheetPresentationController.Detent.custom(identifier: id) { context in
                // A custom detent measures above the bottom safe
                // area. SwiftUI's `.height` measures to the screen
                // edge. Take the safe area off so the two agree.
                height - context.containerTraitCollection.safeAreaBottom(of: view)
            }
            sheet.animateChanges {
                sheet.detents = [detent]
                sheet.selectedDetentIdentifier = id
            }
        }
    }

    private static func sheet(of view: UIView) -> UISheetPresentationController? {
        var responder: UIResponder? = view
        while let current = responder {
            if let controller = current as? UIViewController,
                let sheet = controller.sheetPresentationController
            {
                return sheet
            }
            responder = current.next
        }
        return nil
    }
}

extension UITraitCollection {
    fileprivate func safeAreaBottom(of view: UIView) -> CGFloat {
        view.window?.safeAreaInsets.bottom ?? 0
    }
}
