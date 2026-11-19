import AppKit

/// What the toolbar does with its own glass items, measured from macOS 27's and copied here so pills drawn
/// by `GlassToolbarItem` sit where the system's would.
public enum GlassToolbarMetrics {
    /// Left clear beside one of the system's glass items, on each side that does not face a space.
    public static let edgeMargin: CGFloat = 4
    /// The narrowest slot the toolbar gives an item with a view of its own, whatever the view's width; a
    /// narrower view is centred in it.
    public static let minimumSlotWidth: CGFloat = 36
}

extension GlassToolbarItem {

    /// Room kept clear between the edges of the item's slot and its pills.
    public struct EdgeMargins: Equatable, Sendable {
        public var leading: CGFloat
        public var trailing: CGFloat

        public init(leading: CGFloat, trailing: CGFloat) {
            self.leading = leading
            self.trailing = trailing
        }
    }

    /// Where an item's `EdgeMargins` come from.
    public enum EdgeMarginRule: Equatable, Sendable {
        /// The system's rule for its own glass items, from the item's neighbours in the toolbar:
        /// `GlassToolbarMetrics.edgeMargin` on each side, except where the nearest item that is not hidden
        /// is a fixed or flexible space. A separator, a text item, another glass item and the end of the
        /// toolbar all get the margin, so two glass items side by side end up 8pt apart.
        case automatic
        /// These, whatever is next to the item.
        case fixed(EdgeMargins)
    }
}

/// The layout rules, apart from the views they are applied to.
enum GlassToolbarLayout {

    /// As much of a toolbar item as the margins depend on.
    struct Neighbour: Equatable {
        var identifier: NSToolbarItem.Identifier
        var isHidden: Bool
    }

    /// The margins the system would give a glass item at `index` among `items`.
    static func margins(forItemAt index: Int, among items: [Neighbour]) -> GlassToolbarItem.EdgeMargins {
        func margin(beside neighbours: some Sequence<Neighbour>) -> CGFloat {
            // Hidden items take no room, so the one that counts is the nearest that shows; none is the
            // end of the toolbar.
            guard let neighbour = neighbours.first(where: { !$0.isHidden }) else { return GlassToolbarMetrics.edgeMargin }
            return isSpace(neighbour.identifier) ? 0 : GlassToolbarMetrics.edgeMargin
        }
        guard items.indices.contains(index) else {
            return .init(leading: GlassToolbarMetrics.edgeMargin, trailing: GlassToolbarMetrics.edgeMargin)
        }
        return .init(leading: margin(beside: items[..<index].reversed()),
                     trailing: margin(beside: items[(index + 1)...]))
    }

    static func isSpace(_ identifier: NSToolbarItem.Identifier) -> Bool {
        identifier == .space || identifier == .flexibleSpace
    }

    /// The slot for pills reaching `extent` from the first of them, with `margins` either side: whole
    /// points, as the toolbar lays items out. Nothing for no pills.
    ///
    /// Rounded up, but not for the last twentieth of a point: a spring's final ripples pass a hair over
    /// the width it settles at, which would make the slot a point wider for a frame or two and nudge
    /// every item beside it there and back.
    static func slotWidth(forPillsSpanning extent: CGFloat, margins: CGFloat) -> CGFloat {
        guard extent > 0.001 else { return 0 }
        return (extent + margins - slotRoundingSlack).rounded(.up)
    }

    static let slotRoundingSlack: CGFloat = 0.05
}
