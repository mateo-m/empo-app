import SwiftUI

extension View {
    func sheetToolbar<Title: View>(@ViewBuilder title: () -> Title, done: @escaping () -> Void) -> some View {
        modifier(SheetToolbar(done: done, title: title()))
    }
}

/// The navigation bar gives a principal title the space between the
/// leading edge and Done, and centers the title in that space. With no
/// leading item, a wide title then sits left of the sheet's center.
/// The inset makes the space symmetric around the sheet's center.
///
/// The bar sizes the title's space from the title's ideal width, so an
/// ideal width that follows the inset never settles. A fixed ideal width
/// wider than the bar keeps the space still. An infinite one crashes
/// UIKit ("NSLayoutConstraint constant is not finite").
private struct SheetToolbar<Title: View>: ViewModifier {
    let done: () -> Void
    let title: Title
    @State private var centerX: CGFloat = 0
    @State private var titleSpace: CGRect = .zero

    private var offCenter: CGFloat {
        guard centerX > titleSpace.minX, centerX < titleSpace.maxX else { return 0 }
        return (centerX - titleSpace.minX) - (titleSpace.maxX - centerX)
    }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) {
                $0.frame(in: .global).midX
            } action: {
                centerX = $0
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    title
                        .padding(.leading, max(0, offCenter))
                        .padding(.trailing, max(0, -offCenter))
                        .frame(idealWidth: 2 * centerX, maxWidth: .infinity)
                        .onGeometryChange(for: CGRect.self) {
                            $0.frame(in: .global)
                        } action: {
                            titleSpace = $0
                        }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: done)
                        .tint(.brand)
                }
            }
    }
}
