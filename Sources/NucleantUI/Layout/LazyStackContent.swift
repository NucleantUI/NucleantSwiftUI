//
//  LazyStackContent.swift
//  NucleantUI
//
//  The lazy stack layout. Simpler than `StackContent` on purpose, as
//  SwiftUI's is: every child gets its ideal extent along the axis — there
//  is no share of a fixed length to hand out, since a lazy stack is sized
//  by its content inside a scroll view — and the stack fills the cross axis
//  it is offered. Unbuilt units are sized as they measured last time, or
//  as the average of those that were; see `LazyLayout.swift`.
//

struct LazyStackContent: NodeContent {
    let axis: Axis
    let alignment: Alignment
    /// `nil` means the default gap.
    let spacing: Double?
    let pinnedViews: PinnedScrollableViews
    let owner: Int
    let window: Binding<LazyWindow>
    let memory: LazyLayoutMemory

    static let defaultSpacing: Double = 8
    /// What an unbuilt unit is taken to measure before anything has been.
    static let fallbackExtent: Double = 44

    private var resolvedSpacing: Double { spacing ?? Self.defaultSpacing }

    /// Fills the cross axis; sized by its content along its own.
    func flexibility(along axis: Axis, node: ViewNode) -> LayoutPriorityClass {
        axis == self.axis ? .content : .flexible
    }

    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        var visibility: LazyVisibility?
        return arrange(node: node, cross: proposal[axis.cross], visibility: &visibility, records: false).total
    }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        let crossAxis = axis.cross
        let origin = rect.origin[axis]

        // The clip along the axis, in the stack's own offsets: what is on
        // screen of it, and so which units it needs built.
        let clip = context.compositeClip
        let visible = clip.map { clip -> ClosedRange<Double> in
            let span = clip.lazySpan(along: axis)
            return (span.lowerBound - origin)...(span.upperBound - origin)
        }
        var visibility: LazyVisibility? = LazyVisibility(visible: visible)
        memory.noteCrossExtent(rect.size[crossAxis])
        let arrangement = arrange(node: node, cross: rect.size[crossAxis], visibility: &visibility, records: true)

        // Move the window when the clip is about to leave it. The write
        // rebuilds this stack next frame; a capture or an exiting copy only
        // draws what is there.
        if !context.freezesMotion, let request = visibility?.request(current: window.wrappedValue.units) {
            window.wrappedValue = LazyWindow(units: request)
        }

        // Section headers and footers held at the edges.
        var pinnedOffsets: [Int: Double] = [:]
        if !pinnedViews.isEmpty, let visible {
            let placed = arrangement.placed.enumerated().compactMap { index, entry -> LazyPinning.Placed? in
                guard let tag = entry.node.sectionTag else { return nil }
                return LazyPinning.Placed(index: index, tag: tag, lo: entry.offset, hi: entry.offset + entry.size[axis])
            }
            if !placed.isEmpty {
                pinnedOffsets = LazyPinning.pinnedOffsets(
                    spans: arrangement.spans,
                    placed: placed,
                    pinnedViews: pinnedViews,
                    visible: visible
                )
            }
        }

        func put(_ entry: Arrangement.Placed, at offset: Double) {
            var origin = Point.zero
            origin[axis] = rect.origin[axis] + offset
            origin[crossAxis] = rect.origin[crossAxis] + crossOffset(entry.size[crossAxis], in: rect.size[crossAxis])
            entry.node.place(
                in: Rect(origin: origin, size: entry.size),
                proposal: entry.proposal,
                context: context,
                into: &list
            )
        }

        // The rows, then what is pinned over them — drawn last, so on top.
        for (index, entry) in arrangement.placed.enumerated() where pinnedOffsets[index] == nil {
            put(entry, at: entry.offset)
        }
        var pinned: Set<ObjectIdentifier> = []
        for (index, entry) in arrangement.placed.enumerated() {
            guard let offset = pinnedOffsets[index] else { continue }
            put(entry, at: offset)
            pinned.insert(ObjectIdentifier(entry.node))
        }
        memory.pinned = pinned
    }

    /// Pinned nodes are drawn after the rest, so they are hit before them.
    func hitTestOrder(node: ViewNode) -> [ViewNode]? {
        let pinned = memory.pinned
        guard !pinned.isEmpty else { return nil }
        let children = node.layoutChildren
        return children.filter { !pinned.contains(ObjectIdentifier($0)) }
            + children.filter { pinned.contains(ObjectIdentifier($0)) }
    }

    private func crossOffset(_ extent: Double, in container: Double) -> Double {
        switch axis {
        case .vertical:   return alignment.horizontal.offset(childWidth: extent, in: container)
        case .horizontal: return alignment.vertical.offset(childHeight: extent, in: container)
        }
    }

    // MARK: - Arranging

    struct Arrangement {
        struct Placed {
            let node: ViewNode
            /// From the stack's leading edge along its axis.
            let offset: Double
            let size: Size
            let proposal: ProposedSize
        }
        var placed: [Placed] = []
        /// Every item's span along the axis, with its section tag — what
        /// pinning reads the sections' reach from.
        var spans: [(tag: SectionTag?, lo: Double, hi: Double)] = []
        var total: Size = .zero
    }

    /// Lay the items end to end. `cross` is the extent offered across the
    /// axis — each child is offered it, and nothing along the axis.
    /// `records` saves what the built units measured, for their gaps later;
    /// only placement does, at the extent the stack was actually given.
    private func arrange(
        node: ViewNode,
        cross: Double?,
        visibility: inout LazyVisibility?,
        records: Bool
    ) -> Arrangement {
        let crossAxis = axis.cross
        let items = node.lazyItems(owner: owner)
        var childProposal = ProposedSize.unspecified
        if let cross, cross.isFinite { childProposal[crossAxis] = cross }

        // Measure what is built first: its average sizes the unbuilt units
        // that have never been measured.
        var sizes: [ObjectIdentifier: Size] = [:]
        var measuredTotal = 0.0
        var measuredCount = 0
        for item in items {
            guard case .built(let nodes) = item.kind else { continue }
            var extent = 0.0
            for (index, child) in nodes.enumerated() {
                let size = child.sizeThatFits(childProposal)
                sizes[ObjectIdentifier(child)] = size
                extent += size[axis] + (index > 0 ? resolvedSpacing : 0)
            }
            if records { memory.record(extent, for: item.units.lowerBound) }
            measuredTotal += extent
            measuredCount += 1
        }
        let estimate = memory.average
            ?? (measuredCount > 0 ? measuredTotal / Double(measuredCount) : Self.fallbackExtent)

        var result = Arrangement()
        var cursor = 0.0
        var crossMax = 0.0
        var first = true
        for item in items {
            switch item.kind {
            case .gap:
                for unit in item.units {
                    if !first { cursor += resolvedSpacing }
                    first = false
                    let extent = memory.extent(of: unit) ?? estimate
                    visibility?.visit(unit..<(unit + 1), from: cursor, to: cursor + extent)
                    result.spans.append((tag: nil, lo: cursor, hi: cursor + extent))
                    cursor += extent
                }
            case .built(let nodes):
                let start = cursor + (first ? 0 : resolvedSpacing)
                for child in nodes {
                    if !first { cursor += resolvedSpacing }
                    first = false
                    let size = sizes[ObjectIdentifier(child)] ?? child.sizeThatFits(childProposal)
                    result.placed.append(Arrangement.Placed(node: child, offset: cursor, size: size, proposal: childProposal))
                    result.spans.append((tag: child.sectionTag, lo: cursor, hi: cursor + size[axis]))
                    cursor += size[axis]
                    crossMax = max(crossMax, size[crossAxis])
                }
                visibility?.visit(item.units, from: start, to: cursor)
            }
        }

        result.total[axis] = cursor
        if let cross, cross.isFinite {
            result.total[crossAxis] = max(cross, 0)
        } else {
            result.total[crossAxis] = crossMax
        }
        return result
    }
}
