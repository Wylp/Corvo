import SwiftUI

/// A row of things that wraps onto the next line when it runs out of width.
///
/// Written rather than reached for because SwiftUI has no wrapping stack and the
/// two alternatives are both worse here. A fixed-height box does not wrap, it
/// *overflows* — a `VStack` under a `.frame(maxHeight:)` with no `ScrollView`
/// draws straight over whatever is beneath it, which is how seven tags on one
/// clipping used to paint across the field and the buttons of the sheet that
/// listed them. A horizontal `ScrollView` fits everything and shows some of it,
/// which is the wrong trade for a set the user is reading to find out what is
/// there.
///
/// Height is a consequence here, not a setting. That is the point: whatever is
/// put in is visible, and the container grows to say so.
struct Flow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout Void) -> CGSize {
        let lines = lines(subviews, within: proposal.width ?? .infinity)
        let height = lines.reduce(0) { $0 + $1.height }
            + lineSpacing * CGFloat(max(0, lines.count - 1))
        // Claims the width it was offered when there is one. A wrapping row that
        // reported its longest line instead would re-wrap every time the parent
        // asked it a narrower question.
        return CGSize(width: proposal.width ?? (lines.map(\.width).max() ?? 0),
                      height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout Void) {
        var y = bounds.minY
        for line in lines(subviews, within: bounds.width) {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y),
                                      anchor: .topLeading,
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// Measured once per pass and used by both callers, so what is placed is
    /// laid out to the same breaks that were measured.
    private func lines(_ subviews: Subviews, within width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extended = line.indices.isEmpty ? size.width
                                                : line.width + spacing + size.width
            // A single item wider than the line stays on its own line rather
            // than starting an empty one before it.
            if !line.indices.isEmpty, extended > width {
                lines.append(line)
                line = Line()
            }
            line.width = line.indices.isEmpty ? size.width
                                              : line.width + spacing + size.width
            line.height = max(line.height, size.height)
            line.indices.append(index)
        }
        guard !line.indices.isEmpty else { return lines }
        lines.append(line)
        return lines
    }
}
