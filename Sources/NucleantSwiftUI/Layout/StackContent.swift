//
//  StackContent.swift
//  NucleantSwiftUI
//
//  The stack layout. Children are sized in flexibility order — least flexible
//  first — with each group offered an equal share of what is still unclaimed.
//  That is what makes `HStack { Text("a"); Spacer(); Text("b") }` put the texts
//  at their natural widths and give the rest to the spacer, rather than
//  splitting the width three ways.
//

struct StackContent: NodeContent {
    let axis: Axis
    /// `nil` means "the default gap", resolved at layout time.
    let spacing: Double?
    let horizontalAlignment: HorizontalAlignment
    let verticalAlignment: VerticalAlignment

    static let defaultSpacing: Double = 8

    private var resolvedSpacing: Double { spacing ?? Self.defaultSpacing }

    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        layout(proposal, children: node.layoutChildren).total
    }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        let children = node.layoutChildren
        guard !children.isEmpty else { return }

        // A stack fills the rect it was given, so that is what its children are
        // measured against — but each child is then *placed* with the very
        // proposal it was measured under, which `layout` hands back.
        let result = layout(ProposedSize(rect.size), children: children)
        let crossAxis = axis.cross

        // Extra room along the main axis when the children ended up smaller
        // than the rect (a stack of fixed-size views inside a bigger frame).
        let leftover = max(0, rect.size[axis] - result.total[axis])
        var cursor = rect.origin[axis] + mainAxisOffset(forLeftover: leftover)

        for (index, child) in children.enumerated() {
            let size = result.sizes[index]
            var origin = Point.zero
            origin[axis] = cursor
            origin[crossAxis] = rect.origin[crossAxis]
                + crossOffset(childExtent: size[crossAxis], containerExtent: rect.size[crossAxis])
            child.place(
                in: Rect(origin: origin, size: size),
                proposal: result.proposals[index],
                context: context,
                into: &list
            )
            cursor += size[axis] + resolvedSpacing
        }
    }

    /// Where the whole run of children starts when they don't fill the rect —
    /// governed by the *cross*-axis alignment's counterpart on the main axis,
    /// which for a stack is always centring in SwiftUI.
    private func mainAxisOffset(forLeftover leftover: Double) -> Double {
        switch axis {
        case .vertical:   return verticalAlignment.offset(childHeight: 0, in: leftover)
        case .horizontal: return horizontalAlignment.offset(childWidth: 0, in: leftover)
        }
    }

    private func crossOffset(childExtent: Double, containerExtent: Double) -> Double {
        switch axis {
        case .vertical:
            return horizontalAlignment.offset(childWidth: childExtent, in: containerExtent)
        case .horizontal:
            return verticalAlignment.offset(childHeight: childExtent, in: containerExtent)
        }
    }

    // MARK: - The measuring pass

    private struct LayoutResult {
        var sizes: [Size]
        /// The proposal each child was measured under — carried so placement
        /// can reuse it instead of re-deriving one from the child's own size.
        var proposals: [ProposedSize]
        var total: Size
    }

    private func layout(_ proposal: ProposedSize, children: [ViewNode]) -> LayoutResult {
        guard !children.isEmpty else {
            return LayoutResult(sizes: [], proposals: [], total: .zero)
        }

        let crossAxis = axis.cross
        let totalSpacing = resolvedSpacing * Double(children.count - 1)

        // What's left for the children themselves. An unspecified main axis
        // means nobody is constraining the stack, so each child sizes itself.
        var remaining = proposal[axis].map { max(0, $0 - totalSpacing) }
        var unplaced = children.count

        var sizes = [Size](repeating: .zero, count: children.count)
        var proposals = [ProposedSize](repeating: proposal, count: children.count)
        var sized = [Bool](repeating: false, count: children.count)

        // Least flexible first: a fixed `.frame` before a `Text` before a
        // `Spacer`, so each group only sees what the stricter ones left behind.
        for group in [LayoutPriorityClass.fixed, .content, .flexible] {
            for (index, child) in children.enumerated()
            where !sized[index] && child.content.flexibility(along: axis) == group {

                var childProposal = proposal
                if let remaining {
                    // An equal share of what's left, not the whole thing —
                    // otherwise the first greedy child eats everything.
                    childProposal[axis] = unplaced > 0 ? remaining / Double(unplaced) : 0
                }
                let size = child.sizeThatFits(childProposal)
                sizes[index] = size
                proposals[index] = childProposal
                sized[index] = true
                unplaced -= 1
                if remaining != nil {
                    remaining = max(0, remaining! - size[axis])
                }
            }
        }

        var total = Size.zero
        total[axis] = sizes.reduce(0) { $0 + $1[axis] } + totalSpacing
        total[crossAxis] = sizes.reduce(0) { max($0, $1[crossAxis]) }
        // Never claim more than was offered — a stack that overflowed still
        // reports the box it was given, and its children simply spill.
        if let limit = proposal[axis] { total[axis] = min(total[axis], max(limit, 0)) }
        if let limit = proposal[crossAxis] { total[crossAxis] = min(total[crossAxis], max(limit, 0)) }

        return LayoutResult(sizes: sizes, proposals: proposals, total: total)
    }
}

/// Depth-stacked children, all sharing one rect.
struct ZStackContent: NodeContent {
    let alignment: Alignment

    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        var result = Size.zero
        for child in node.layoutChildren {
            let size = child.sizeThatFits(proposal)
            result.width = max(result.width, size.width)
            result.height = max(result.height, size.height)
        }
        return result
    }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        // Every child of a ZStack is offered the whole rect, so that proposal
        // is both what sizes it and what it is placed under.
        let childProposal = ProposedSize(rect.size)
        for child in node.layoutChildren {
            let size = child.sizeThatFits(childProposal)
            child.place(
                in: alignment.position(size, in: rect),
                proposal: childProposal,
                context: context,
                into: &list
            )
        }
    }
}

extension Point {
    /// One axis of a point, so stack maths can be written once for both.
    subscript(axis: Axis) -> Double {
        get { axis == .horizontal ? x : y }
        set {
            if axis == .horizontal { x = newValue } else { y = newValue }
        }
    }
}
