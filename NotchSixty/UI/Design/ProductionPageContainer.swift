import SwiftUI

/// The one page container every sidebar page uses (AGENTS.md section 13).
///
/// It supplies the scroll view, the same side padding and top spacing everywhere, and one maximum content width.
/// Content is aligned leading, never centred, so a sparse page does not float in the middle of a wide window.
/// Pages set no page-level maximum width of their own; control-level widths (a text field, a picker) are fine.
struct ProductionPageContainer<Content: View>: View {
    /// The single page content width limit, in points.
    static var maxContentWidth: CGFloat { 1_500 }

    private let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        ScrollView {
            content
                .padding(DesignSpacing.xl.pt)
                .frame(maxWidth: Self.maxContentWidth, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}
