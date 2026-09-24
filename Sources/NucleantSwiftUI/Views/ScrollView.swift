//
//  ScrollView.swift
//  NucleantSwiftUI
//

/// A scrollable container. The content is measured unconstrained along the
/// scroll axes, then drawn shifted by the current offset and clipped to the
/// scroll view's own bounds.
@View
public struct ScrollView<Content: View>: View {
    public let axes: Axis.Set
    public let content: Content

    @State private var offset = Point.zero

    public init(_ axes: Axis.Set = .vertical, _viewID: ViewID = #viewID, @ViewBuilder content: () -> Content) {
        self.axes = axes
        self.content = content()
        self._viewID = _viewID
    }

    public var body: Never { bodyUnavailable() }
}

extension ScrollView: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        var inner = context
        // The content is not in a stack of its own; clear any inherited axis so
        // a `Spacer` inside doesn't stretch along the enclosing stack's.
        inner.stackAxis = nil
        let child = inner.child(0) { ctx in buildNode(content, &ctx) }
        return ViewNode(
            content: ScrollContent(axes: axes, offset: $offset),
            children: [child]
        )
    }
}

struct ScrollContent: NodeContent {
    let axes: Axis.Set
    let offset: Binding<Point>

    /// The content extent measured at the last `place`, so scrolling can be
    /// clamped without re-measuring on every wheel event.
    private let contentSize = ContentBox()

    final class ContentBox {
        var size: Size = .zero
        var viewport: Size = .zero
    }

    init(axes: Axis.Set, offset: Binding<Point>) {
        self.axes = axes
        self.offset = offset
    }

    /// A scroll view takes whatever it is offered — it is the clip, not the
    /// content, that decides its size.
    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        proposal.replacingUnspecifiedDimensions()
    }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        guard let child = node.singleChild else { return }

        // Unconstrained along each scrollable axis: that is what lets the
        // content be taller than the viewport.
        var contentProposal = ProposedSize(rect.size)
        if axes.contains(.vertical) { contentProposal.height = nil }
        if axes.contains(.horizontal) { contentProposal.width = nil }

        let size = child.sizeThatFits(contentProposal)
        contentSize.size = size
        contentSize.viewport = rect.size

        let clamped = clamp(offset.wrappedValue, content: size, viewport: rect.size)
        child.place(
            in: Rect(
                x: rect.minX - clamped.x,
                y: rect.minY - clamped.y,
                width: axes.contains(.horizontal) ? size.width : rect.width,
                height: axes.contains(.vertical) ? size.height : rect.height
            ),
            proposal: contentProposal,
            context: context.clipped(to: rect),
            into: &list
        )
    }

    private func clamp(_ point: Point, content: Size, viewport: Size) -> Point {
        Point(
            x: axes.contains(.horizontal)
                ? min(max(0, point.x), max(0, content.width - viewport.width))
                : 0,
            y: axes.contains(.vertical)
                ? min(max(0, point.y), max(0, content.height - viewport.height))
                : 0
        )
    }

    var clipsChildren: Bool { true }

    var hitTarget: HitTarget? {
        // Scroll only — a scroll view swallows no taps, so its children keep
        // receiving them (hit testing tries children first regardless).
        HitTarget(onScroll: { [offset, contentSize, axes] delta in
            var next = offset.wrappedValue
            if axes.contains(.horizontal) { next.x -= delta.x }
            if axes.contains(.vertical) { next.y -= delta.y }
            let clamped = Point(
                x: axes.contains(.horizontal)
                    ? min(max(0, next.x), max(0, contentSize.size.width - contentSize.viewport.width))
                    : 0,
                y: axes.contains(.vertical)
                    ? min(max(0, next.y), max(0, contentSize.size.height - contentSize.viewport.height))
                    : 0
            )
            guard clamped != offset.wrappedValue else { return }
            offset.wrappedValue = clamped
        })
    }
}
