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
    private let scrolls: Bool

    /// `scrolls: false` is for a page whose panes each scroll on their own (Dynamics): the content fills the page height
    /// and the page itself does not scroll, so there is one scroll bar per pane and none nested.
    init(scrolls: Bool = true, @ViewBuilder content: () -> Content) {
        self.scrolls = scrolls
        self.content = content()
    }

    var body: some View {
        if scrolls {
            ScrollView {
                content
                    .padding(DesignSpacing.xl.pt)
                    .frame(maxWidth: Self.maxContentWidth, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            content
                .padding(DesignSpacing.xl.pt)
                .frame(maxWidth: Self.maxContentWidth, maxHeight: .infinity, alignment: .topLeading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// Lays its children out in as many equal-width columns as fit `minColumnWidth`, each child going to the shortest column.
/// One column when the width is narrow. Used for control groups so wide windows use the width.
struct AdaptiveColumnsLayout: Layout {
    var minColumnWidth: CGFloat
    var spacing: CGFloat

    private func columnCount(_ width: CGFloat) -> Int {
        guard width.isFinite, width > 0 else { return 1 }
        return max(1, Int(((width + spacing) / (minColumnWidth + spacing)).rounded(.down)))
    }

    private func place(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        let columns = columnCount(width)
        let columnWidth = columns == 1 ? width : (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        var heights = [CGFloat](repeating: 0, count: columns)
        var frames: [CGRect] = []
        for view in subviews {
            let column = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            let size = view.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
            if heights[column] > 0 { heights[column] += spacing }
            frames.append(CGRect(x: CGFloat(column) * (columnWidth + spacing), y: heights[column], width: columnWidth, height: size.height))
            heights[column] += size.height
        }
        return (frames, heights.max() ?? 0)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minColumnWidth
        return CGSize(width: width, height: place(subviews, width: width).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = place(subviews, width: bounds.width)
        for (view, frame) in zip(subviews, result.frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                       proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}
