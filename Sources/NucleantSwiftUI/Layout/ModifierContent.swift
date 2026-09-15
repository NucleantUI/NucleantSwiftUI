//
//  ModifierContent.swift
//  NucleantSwiftUI
//
//  One node per modifier. Each wraps a single child (`node.singleChild`) and
//  changes either the box it gets, the context it draws under, or both.
//

/// `.frame(width:height:)` and `.frame(minWidth:…)`.
struct FrameContent: NodeContent {
    let width: Double?
    let height: Double?
    let minWidth: Double?
    let maxWidth: Double?
    let minHeight: Double?
    let maxHeight: Double?
    let alignment: Alignment

    /// A frame with a hard extent on an axis is immovable there — the stack
    /// must size it before anything that can stretch. On an axis it says
    /// nothing about, the child decides.
    func flexibility(along axis: Axis, node: ViewNode) -> LayoutPriorityClass {
        let fixed = axis == .horizontal ? width : height
        if fixed != nil { return .fixed }
        let maximum = axis == .horizontal ? maxWidth : maxHeight
        if maximum == .infinity { return .flexible }
        let minimum = axis == .horizontal ? minWidth : minHeight
        if maximum != nil || minimum != nil { return .content }
        return node.singleChild?.flexibility(along: axis) ?? .content
    }

    /// The proposal handed inward, the box this node reports outward, and the
    /// inner proposal itself — placement needs that last one so the child is
    /// positioned under the same proposal it was sized by.
    private func resolve(
        _ proposal: ProposedSize,
        childSize: (ProposedSize) -> Size
    ) -> (own: Size, child: Size, inner: ProposedSize) {
        var inner = proposal
        if let width { inner.width = width }
        if let height { inner.height = height }
        // An infinite maximum means "as much as offered", so the child is
        // proposed the container's extent rather than infinity itself.
        if let maxWidth, maxWidth != .infinity {
            inner.width = min(inner.width ?? maxWidth, maxWidth)
        }
        if let maxHeight, maxHeight != .infinity {
            inner.height = min(inner.height ?? maxHeight, maxHeight)
        }
        if let minWidth { inner.width = max(inner.width ?? minWidth, minWidth) }
        if let minHeight { inner.height = max(inner.height ?? minHeight, minHeight) }

        let child = childSize(inner)

        var own = child
        if let width { own.width = width }
        if let height { own.height = height }
        if let minWidth { own.width = max(own.width, minWidth) }
        if let minHeight { own.height = max(own.height, minHeight) }
        if let maxWidth {
            own.width = maxWidth == .infinity
                ? max(own.width, proposal.width ?? own.width)
                : min(own.width, maxWidth)
        }
        if let maxHeight {
            own.height = maxHeight == .infinity
                ? max(own.height, proposal.height ?? own.height)
                : min(own.height, maxHeight)
        }
        return (own, child, inner)
    }

    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        resolve(proposal) { inner in
            node.singleChild?.sizeThatFits(inner) ?? inner.replacingUnspecifiedDimensions()
        }.own
    }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        guard let child = node.singleChild else { return }
        // Resolve against the proposal that produced `rect` — re-deriving one
        // from `rect.size` re-applies any proposal-dependent sizing below.
        let sizes = resolve(proposal) { inner in child.sizeThatFits(inner) }
        child.place(
            in: alignment.position(sizes.child, in: rect),
            proposal: sizes.inner,
            context: context,
            into: &list
        )
    }
}

/// `.relativeSize(width:height:)` — an extent given as a fraction of what the
/// parent offered, rather than an absolute number.
///
/// SwiftUI expresses this with `GeometryReader`, which needs the child to be
/// *built* once its size is known — the tree here is built before layout runs,
/// so that is a larger change (it is on the Later list). A fraction covers the
/// common case a `GeometryReader` is usually reached for: a bar or fill sized
/// against its container.
struct RelativeSizeContent: NodeContent {
    let widthFraction: Double?
    let heightFraction: Double?

    private func resolve(_ proposal: ProposedSize) -> ProposedSize {
        var inner = proposal
        if let widthFraction, let width = proposal.width {
            inner.width = max(0, width * widthFraction)
        }
        if let heightFraction, let height = proposal.height {
            inner.height = max(0, height * heightFraction)
        }
        return inner
    }

    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        let inner = resolve(proposal)
        guard let child = node.singleChild else {
            return inner.replacingUnspecifiedDimensions()
        }
        var size = child.sizeThatFits(inner)
        // The fraction is the claim, not the child's own preference — a
        // capsule asked for 40% of the width reports 40%, even if it would
        // happily have taken everything.
        if let width = inner.width { size.width = width }
        if let height = inner.height { size.height = height }
        return size
    }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        // `rect` is already the fraction of the parent — the child fills it,
        // and is proposed exactly that, never the fraction a second time.
        node.singleChild?.place(
            in: rect,
            proposal: ProposedSize(rect.size),
            context: context,
            into: &list
        )
    }
}

/// `.padding(_:)`.
struct PaddingContent: NodeContent {
    let insets: EdgeInsets

    private func shrink(_ proposal: ProposedSize) -> ProposedSize {
        ProposedSize(
            width: proposal.width.map { max(0, $0 - insets.horizontal) },
            height: proposal.height.map { max(0, $0 - insets.vertical) }
        )
    }

    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        let inner = node.singleChild?.sizeThatFits(shrink(proposal))
            ?? shrink(proposal).replacingUnspecifiedDimensions()
        return Size(
            width: inner.width + insets.horizontal,
            height: inner.height + insets.vertical
        )
    }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        let inner = rect.insetBy(insets)
        node.singleChild?.place(
            in: inner,
            proposal: shrink(proposal),
            context: context,
            into: &list
        )
    }
}

/// `.background(_:)` and `.overlay(_:)` — two children, painted either side of
/// each other. The *content* sizes the node; the decoration is stretched to it.
struct DecorationContent: NodeContent {
    enum Order: Hashable {
        /// Decoration painted first, behind the content.
        case background
        /// Decoration painted last, over the content.
        case overlay
    }

    let order: Order
    let alignment: Alignment

    /// Index into `node.children` — never `layoutChildren`, because the two
    /// slots are positional and flattening would merge a multi-child group.
    private func content(_ node: ViewNode) -> ViewNode? { node.children.first }
    private func decoration(_ node: ViewNode) -> ViewNode? {
        node.children.count > 1 ? node.children[1] : nil
    }

    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        content(node)?.sizeThatFits(proposal) ?? proposal.replacingUnspecifiedDimensions()
    }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        let contentNode = content(node)
        let decorationNode = decoration(node)
        // The decoration is stretched to the content's box, so the box is what
        // it is offered.
        let decorationProposal = ProposedSize(rect.size)

        func placeDecoration() {
            guard let decorationNode else { return }
            let size = decorationNode.sizeThatFits(decorationProposal)
            decorationNode.place(
                in: alignment.position(size, in: rect),
                proposal: decorationProposal,
                context: context,
                into: &list
            )
        }

        switch order {
        case .background:
            placeDecoration()
            contentNode?.place(in: rect, proposal: proposal, context: context, into: &list)
        case .overlay:
            contentNode?.place(in: rect, proposal: proposal, context: context, into: &list)
            placeDecoration()
        }
    }
}

/// `.opacity(_:)`.
struct OpacityContent: NodeContent {
    let opacity: Double

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        var inner = context
        inner.opacity *= opacity
        node.singleChild?.place(in: rect, proposal: proposal, context: inner, into: &list)
    }
}

/// `.hidden()` — laid out exactly as before, painted not at all.
struct HiddenContent: NodeContent {
    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        // Still placed, so `frame` is set and layout is unchanged; the child's
        // commands are simply thrown away.
        var discarded = DisplayList()
        node.singleChild?.place(in: rect, proposal: proposal, context: context, into: &discarded)
    }
}

/// `.offset(x:y:)` — moves the drawing without changing the layout.
struct OffsetContent: NodeContent {
    let offset: Point

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        node.singleChild?.place(
            in: rect.offsetBy(dx: offset.x, dy: offset.y),
            proposal: proposal,
            context: context,
            into: &list
        )
    }
}

/// `.rotationEffect(_:)` and `.scaleEffect(_:)` — a transform about an anchor
/// inside the node's own rect, again with no effect on layout.
struct TransformContent: NodeContent {
    enum Kind {
        case rotation(Angle)
        case scale(x: Double, y: Double)
    }

    let kind: Kind
    let anchor: UnitPoint

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        let base: Transform
        switch kind {
        case .rotation(let angle):
            base = .rotation(angle)
        case .scale(let x, let y):
            base = .scale(x: x, y: y)
        }
        var inner = context
        inner.transform = context.transform
            .concatenating(.around(anchor.resolved(in: rect), base))
        node.singleChild?.place(in: rect, proposal: proposal, context: inner, into: &list)
    }
}

/// `.clipped()` / `.cornerRadius(_:)`'s clipping half.
struct ClipContent: NodeContent {
    let cornerRadius: Double

    var clipsChildren: Bool { true }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        node.singleChild?.place(
            in: rect,
            proposal: proposal,
            context: context.clipped(to: rect, cornerRadius: cornerRadius),
            into: &list
        )
    }
}

/// `._parked(true)` — a subtree kept in the tree but taken off screen:
/// zero size, never placed, so nothing under it is drawn, hit tested or
/// given a GPU slot. Its views keep their identity and state, which is what
/// a `NavigationStack` wants for the screens under the top one.
struct ParkedContent: NodeContent {
    let isParked: Bool

    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        guard isParked else {
            return node.singleChild?.sizeThatFits(proposal) ?? proposal.replacingUnspecifiedDimensions()
        }
        return .zero
    }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        guard !isParked else { return }
        node.singleChild?.place(in: rect, proposal: proposal, context: context, into: &list)
    }
}

/// `.onTapGesture` and `Button`'s pointer handling.
struct InteractionContent: NodeContent {
    let target: HitTarget

    var hitTarget: HitTarget? { target }
}

/// `.environment(...)` and the sugar built on it (`.font`, `.foregroundColor`).
/// Almost entirely a build-time concern — by placement time the values are
/// baked into the leaves. The exception is the color scheme: dynamic colors
/// are resolved as they are drawn, so the scheme rides on the draw context
/// and is set here for the subtree.
struct EnvironmentContent: NodeContent {
    let colorScheme: ColorScheme

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        var inner = context
        inner.colorScheme = colorScheme
        node.singleChild?.place(in: rect, proposal: proposal, context: inner, into: &list)
    }
}
