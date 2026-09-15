//
//  LeafContent.swift
//  NucleantSwiftUI
//
//  The nodes that actually put something in the display list.
//

/// `Text`.
struct TextContent: NodeContent {
    let string: String
    let font: Font
    let color: Color
    let alignment: TextAlignment
    let lineLimit: Int?

    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        TextMeasurer.size(of: string, font: font, proposal: proposal, lineLimit: lineLimit)
    }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        guard !string.isEmpty else { return }
        // The half-point slack absorbs the difference between summed glyph
        // advances here and ThorVG's own layout.
        let fitsOneLine = TextMeasurer.width(of: string, font: font) <= rect.width + 0.5
        list.append(.text(TextDraw(
            string: string,
            frame: rect,
            font: font,
            color: context.resolve(color),
            alignment: alignment,
            lineLimit: lineLimit,
            // Only a single-line label can be ellipsised, and only when it
            // really is too wide.
            isTruncated: lineLimit == 1 && !fitsOneLine,
            // A string that fits one line is drawn as one line, whatever
            // ThorVG's layout would make of the exact-fit box.
            wraps: !fitsOneLine,
            transform: context.transform,
            clip: context.clip,
            clipCornerRadius: context.clipCornerRadius
        )))
    }
}

/// A filled and/or stroked shape. The shape itself is a closure so every
/// concrete `Shape` reduces to one node kind.
struct ShapeContent: NodeContent {
    /// Builds the path in *local* coordinates for a given size.
    let makePath: (Rect) -> Path
    let fill: ShapeStyle?
    let stroke: ShapeStyle?
    let strokeStyle: StrokeStyle
    /// A shape claims whatever it is offered; an unspecified axis collapses to
    /// nothing, matching SwiftUI (a `Circle()` in a `VStack` with no width
    /// proposal is empty, not infinite).
    let idealSize: Size?

    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        proposal.replacingUnspecifiedDimensions(by: idealSize ?? .zero)
    }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        guard rect.width > 0, rect.height > 0 else { return }
        guard fill != nil || stroke != nil else { return }
        list.append(.shape(ShapeDraw(
            path: makePath(rect),
            bounds: rect,
            fill: fill.map(context.resolve),
            stroke: stroke.map(context.resolve),
            strokeStyle: strokeStyle,
            transform: context.transform,
            clip: context.clip,
            clipCornerRadius: context.clipCornerRadius
        )))
    }
}

/// `Spacer` — takes every point the stack will give it along its axis.
struct SpacerContent: NodeContent {
    let minLength: Double
    /// Set by the stack when it places the spacer; `nil` outside a stack, where
    /// a spacer expands on both axes.
    let axis: Axis?

    /// Flexible along its stack's axis, and nothing at all across it — a
    /// spacer in an `HStack` has no height, so the row it is in must not
    /// look vertically flexible to the stack around that row.
    func flexibility(along axis: Axis, node: ViewNode) -> LayoutPriorityClass {
        guard let own = self.axis else { return .flexible }
        return axis == own ? .flexible : .fixed
    }

    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        var size = Size(width: minLength, height: minLength)
        switch axis {
        case .horizontal:
            size.width = max(minLength, proposal.width ?? minLength)
            size.height = 0
        case .vertical:
            size.height = max(minLength, proposal.height ?? minLength)
            size.width = 0
        case nil:
            size = proposal.replacingUnspecifiedDimensions(by: size)
        }
        return size
    }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {}
}

/// The layout flexibility a stack sorts by. A spacer is maximally flexible, a
/// fixed frame not at all — sizing the least flexible children first is what
/// keeps a `Text` from being squeezed by a greedy sibling.
enum LayoutPriorityClass: Int, Comparable {
    case fixed = 0
    case content = 1
    case flexible = 2

    static func < (lhs: LayoutPriorityClass, rhs: LayoutPriorityClass) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}


