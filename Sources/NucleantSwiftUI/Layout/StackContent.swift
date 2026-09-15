//
//  StackContent.swift
//  NucleantSwiftUI
//
//  The stack layout. Children are sized in flexibility order — least flexible
//  first — and a group only ever sees what the stricter groups left behind:
//  a `Spacer` gets leftovers, never a share. Within the content group each
//  child is offered its ideal extent when all of them fit, and an equal share
//  of what is left when they don't. That is what makes
//  `HStack { Text("a"); Spacer(); Text("b") }` put the texts at their natural
//  widths and give the rest to the spacer, rather than splitting the width
//  three ways. A node's flexibility is that of what it wraps (a stack: its
//  most flexible child), so a padded row of fixed frames is fixed too.
//

struct StackContent: NodeContent {
    let axis: Axis
    /// `nil` means "the default gap", resolved at layout time.
    let spacing: Double?
    let horizontalAlignment: HorizontalAlignment
    let verticalAlignment: VerticalAlignment

    static let defaultSpacing: Double = 8

    private var resolvedSpacing: Double { spacing ?? Self.defaultSpacing }

    /// As flexible as the most flexible child: a row of fixed frames is fixed
    /// and must be sized before a sibling `Text`; one holding a `Spacer`
    /// soaks up whatever is left.
    func flexibility(along axis: Axis, node: ViewNode) -> LayoutPriorityClass {
        node.layoutChildren.map { $0.flexibility(along: axis) }.max() ?? .content
    }

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

        var sizes = [Size](repeating: .zero, count: children.count)
        var proposals = [ProposedSize](repeating: proposal, count: children.count)
        var sized = [Bool](repeating: false, count: children.count)

        // Least flexible first: a fixed `.frame` before a `Text` before a
        // `Spacer`, so each group only sees what the stricter ones left behind.
        for group in [LayoutPriorityClass.fixed, .content, .flexible] {
            let members = children.indices.filter {
                !sized[$0] && children[$0].flexibility(along: axis) == group
            }

            // Content children — text, mostly — are offered their ideal
            // extent when all of those fit in what is left, so a row of
            // labels and buttons that plainly fits never wraps one of them
            // just because it came first and was handed an equal share.
            // When they don't all fit, the equal share below decides who
            // shrinks. A child whose ideal is unbounded (a colour, a shape)
            // makes the sum infinite and lands in the same fallback.
            var ideals: [Int: Double] = [:]
            if group == .content, let remaining {
                var hi = proposal
                hi[axis] = .infinity
                var sum = 0.0
                for index in members {
                    let ideal = children[index].sizeThatFits(hi)[axis]
                    ideals[index] = ideal
                    sum += ideal
                }
                if !(sum <= remaining) { ideals.removeAll() }
            }

            var unsizedInGroup = members.count
            for index in members {
                let child = children[index]
                var childProposal = proposal
                if let ideal = ideals[index] {
                    childProposal[axis] = ideal
                } else if let remaining {
                    // An equal share of what's left among the children still
                    // to size *in this group* — not the whole thing, or the
                    // first greedy child eats everything; and not a share
                    // with the more flexible groups, which only ever get
                    // what is left over, the way a `Spacer` does in SwiftUI.
                    childProposal[axis] = remaining / Double(unsizedInGroup)
                }
                let size = child.sizeThatFits(childProposal)
                sizes[index] = size
                proposals[index] = childProposal
                sized[index] = true
                unsizedInGroup -= 1
                if remaining != nil {
                    remaining = max(0, remaining! - size[axis])
                }
            }
        }

        var total = Size.zero
        total[axis] = sizes.reduce(0) { $0 + $1[axis] } + totalSpacing
        total[crossAxis] = sizes.reduce(0) { max($0, $1[crossAxis]) }
        // Never claim more than was offered — a stack that overflowed still
        // reports the box it was given, and its children simply spill. The
        // exception is a run of fixed children: that is as immovable as a
        // fixed `.frame`, and reports its true extent so the stack around it
        // sizes the rest around *that* rather than around an equal share.
        let isFixedRun = children.allSatisfy { $0.flexibility(along: axis) == .fixed }
        if let limit = proposal[axis], !isFixedRun { total[axis] = min(total[axis], max(limit, 0)) }
        if let limit = proposal[crossAxis] { total[crossAxis] = min(total[crossAxis], max(limit, 0)) }

        return LayoutResult(sizes: sizes, proposals: proposals, total: total)
    }
}

/// Depth-stacked children, all sharing one rect.
struct ZStackContent: NodeContent {
    let alignment: Alignment

    func flexibility(along axis: Axis, node: ViewNode) -> LayoutPriorityClass {
        node.layoutChildren.map { $0.flexibility(along: axis) }.max() ?? .content
    }

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
