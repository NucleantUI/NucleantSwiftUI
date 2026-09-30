//
//  LazyGridContent.swift
//  NucleantUI
//
//  The lazy grid layout, written once for both directions. `axis` is the
//  one the grid grows along (vertical for `LazyVGrid`); the tracks — its
//  `GridItem`s, expanded — divide the other. Cells fill a line of tracks,
//  then the next line; a section's header or footer takes a line to itself.
//  A line is as long as its longest built cell; a line of unbuilt units is
//  as long as it measured last time, or as the average line.
//

struct LazyGridContent: NodeContent {
    let axis: Axis
    let tracks: [GridItem]
    let alignment: Alignment
    /// Between lines; `nil` for the default.
    let spacing: Double?
    let pinnedViews: PinnedScrollableViews
    let owner: Int
    let window: Binding<LazyWindow>
    let memory: LazyLayoutMemory

    static let defaultSpacing: Double = 8
    /// What an unbuilt line is taken to measure before anything has been.
    static let fallbackExtent: Double = 44

    private var lineSpacing: Double { spacing ?? Self.defaultSpacing }

    /// Fills the axis its tracks divide; sized by its content along its own.
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

        let clip = context.compositeClip
        let visible = clip.map { clip -> ClosedRange<Double> in
            let span = clip.lazySpan(along: axis)
            return (span.lowerBound - origin)...(span.upperBound - origin)
        }
        var visibility: LazyVisibility? = LazyVisibility(visible: visible)
        memory.noteCrossExtent(rect.size[crossAxis])
        let arrangement = arrange(node: node, cross: rect.size[crossAxis], visibility: &visibility, records: true)

        if !context.freezesMotion, let request = visibility?.request(current: window.wrappedValue.units) {
            window.wrappedValue = LazyWindow(units: request)
        }

        var pinnedOffsets: [Int: Double] = [:]
        if !pinnedViews.isEmpty, let visible {
            let placed = arrangement.placed.enumerated().compactMap { index, entry -> LazyPinning.Placed? in
                guard let tag = entry.node.sectionTag else { return nil }
                return LazyPinning.Placed(index: index, tag: tag, lo: entry.lineOffset, hi: entry.lineOffset + entry.lineExtent)
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

        func put(_ entry: Arrangement.Placed, lineOffset: Double) {
            // The cell's slot: its track across, its line along.
            var slotOrigin = Point.zero
            slotOrigin[axis] = rect.origin[axis] + lineOffset
            slotOrigin[crossAxis] = rect.origin[crossAxis] + entry.crossOffset
            var slotSize = Size.zero
            slotSize[axis] = entry.lineExtent
            slotSize[crossAxis] = entry.crossExtent
            let slot = Rect(origin: slotOrigin, size: slotSize)
            entry.node.place(
                in: entry.alignment.position(entry.size, in: slot),
                proposal: entry.proposal,
                context: context,
                into: &list
            )
        }

        for (index, entry) in arrangement.placed.enumerated() where pinnedOffsets[index] == nil {
            put(entry, lineOffset: entry.lineOffset)
        }
        var pinned: Set<ObjectIdentifier> = []
        for (index, entry) in arrangement.placed.enumerated() {
            guard let offset = pinnedOffsets[index] else { continue }
            put(entry, lineOffset: offset)
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

    // MARK: - Tracks

    struct Track {
        let extent: Double
        /// The gap after it.
        let spacing: Double
        let alignment: Alignment
    }

    /// The `GridItem`s expanded into tracks for `cross` — an adaptive item
    /// into as many as fit. Fixed items first; flexible and adaptive ones
    /// split what is left, a flexible one clamped to its bounds and the
    /// rest re-split among the others.
    func resolveTracks(cross: Double?) -> [Track] {
        guard !tracks.isEmpty else { return [] }
        let gaps = tracks.dropLast().reduce(0) { $0 + ($1.spacing ?? Self.defaultSpacing) }

        var sizes = [Double?](repeating: nil, count: tracks.count)
        var remaining = (cross ?? 0) - gaps
        for (index, item) in tracks.enumerated() {
            if case .fixed(let extent) = item.size {
                sizes[index] = extent
                remaining -= extent
            }
        }

        // Settle the flexible items that their bounds hold away from an
        // even share, until the share stops moving.
        var open = tracks.indices.filter { sizes[$0] == nil }
        var settled = false
        while !settled, !open.isEmpty {
            settled = true
            let share = remaining / Double(open.count)
            for index in open {
                guard case .flexible(let minimum, let maximum) = tracks[index].size else { continue }
                let clamped = min(max(share, minimum), maximum)
                if clamped != share {
                    sizes[index] = clamped
                    remaining -= clamped
                    settled = false
                }
            }
            open.removeAll { sizes[$0] != nil }
        }
        let share = open.isEmpty ? 0 : max(remaining / Double(open.count), 0)

        var result: [Track] = []
        for (index, item) in tracks.enumerated() {
            let gap = item.spacing ?? Self.defaultSpacing
            let alignment = item.alignment ?? .center
            switch item.size {
            case .fixed, .flexible:
                let extent: Double
                if let size = sizes[index] {
                    extent = size
                } else if case .flexible(let minimum, _) = item.size, cross == nil {
                    extent = minimum
                } else {
                    extent = share
                }
                result.append(Track(extent: max(extent, 0), spacing: gap, alignment: alignment))
            case .adaptive(let minimum, let maximum):
                // As many as fit at their minimum, then widened evenly into
                // the share — never past the maximum.
                let space = cross == nil ? minimum : share
                let count = max(1, Int(((space + gap) / (max(minimum, 1) + gap)).rounded(.down)))
                let each = min(max((space - gap * Double(count - 1)) / Double(count), minimum), maximum)
                for _ in 0..<count {
                    result.append(Track(extent: each, spacing: gap, alignment: alignment))
                }
            }
        }
        return result
    }

    // MARK: - Arranging

    struct Arrangement {
        struct Placed {
            let node: ViewNode
            /// Where its line starts along the axis, and how long it is.
            let lineOffset: Double
            let lineExtent: Double
            /// Where its slot starts across, and how wide it is.
            let crossOffset: Double
            let crossExtent: Double
            let size: Size
            let proposal: ProposedSize
            let alignment: Alignment
        }
        var placed: [Placed] = []
        var spans: [(tag: SectionTag?, lo: Double, hi: Double)] = []
        var total: Size = .zero
    }

    /// One line: its cells (a built node, or an unbuilt unit) in track
    /// order, or a header or footer across the whole grid.
    private enum Line {
        case cells([(node: ViewNode?, unit: Int)])
        case spanning(ViewNode, unit: Int)

        var units: Range<Int> {
            switch self {
            case .spanning(_, let unit):
                return unit..<(unit + 1)
            case .cells(let cells):
                guard let first = cells.first?.unit, let last = cells.last?.unit else { return 0..<0 }
                return first..<(last + 1)
            }
        }
    }

    private func arrange(
        node: ViewNode,
        cross: Double?,
        visibility: inout LazyVisibility?,
        records: Bool
    ) -> Arrangement {
        let crossAxis = axis.cross
        let finiteCross = cross.flatMap { $0.isFinite ? $0 : nil }
        let resolved = resolveTracks(cross: finiteCross)
        guard !resolved.isEmpty else { return Arrangement() }

        // Where each track starts across, and the whole run of them.
        var trackOffsets: [Double] = []
        var across = 0.0
        for (index, track) in resolved.enumerated() {
            trackOffsets.append(across)
            across += track.extent + (index < resolved.count - 1 ? track.spacing : 0)
        }
        let crossTotal = finiteCross ?? across
        // A run of tracks narrower than the grid sits in it by alignment.
        let lead: Double
        switch crossAxis {
        case .horizontal: lead = alignment.horizontal.offset(childWidth: across, in: crossTotal)
        case .vertical:   lead = alignment.vertical.offset(childHeight: across, in: crossTotal)
        }

        // Fill the lines.
        var lines: [Line] = []
        var current: [(node: ViewNode?, unit: Int)] = []
        func flush() {
            if !current.isEmpty { lines.append(.cells(current)) }
            current.removeAll()
        }
        for item in node.lazyItems(owner: owner) {
            switch item.kind {
            case .gap:
                for unit in item.units {
                    current.append((node: nil, unit: unit))
                    if current.count == resolved.count { flush() }
                }
            case .built(let nodes):
                for child in nodes {
                    if child.sectionTag != nil {
                        flush()
                        lines.append(.spanning(child, unit: item.units.lowerBound))
                    } else {
                        current.append((node: child, unit: item.units.lowerBound))
                        if current.count == resolved.count { flush() }
                    }
                }
            }
        }
        flush()

        // Measure the built lines; their average stands in for unbuilt
        // ones never measured.
        func cellProposal(_ track: Track) -> ProposedSize {
            var proposal = ProposedSize.unspecified
            proposal[crossAxis] = track.extent
            return proposal
        }
        var spanningProposal = ProposedSize.unspecified
        spanningProposal[crossAxis] = crossTotal
        var extents = [Double?](repeating: nil, count: lines.count)
        var measuredTotal = 0.0
        var measuredCount = 0
        for (index, line) in lines.enumerated() {
            var extent: Double?
            switch line {
            case .spanning(let child, _):
                extent = child.sizeThatFits(spanningProposal)[axis]
            case .cells(let cells):
                for (slot, cell) in cells.enumerated() {
                    guard let child = cell.node else { continue }
                    extent = max(extent ?? 0, child.sizeThatFits(cellProposal(resolved[slot]))[axis])
                }
            }
            guard let extent else { continue }
            extents[index] = extent
            if records { memory.record(extent, for: line.units.lowerBound) }
            measuredTotal += extent
            measuredCount += 1
        }
        let estimate = memory.average
            ?? (measuredCount > 0 ? measuredTotal / Double(measuredCount) : Self.fallbackExtent)

        var result = Arrangement()
        var cursor = 0.0
        for (index, line) in lines.enumerated() {
            if index > 0 { cursor += lineSpacing }
            let extent = extents[index] ?? memory.extent(of: line.units.lowerBound) ?? estimate
            visibility?.visit(line.units, from: cursor, to: cursor + extent)
            switch line {
            case .spanning(let child, _):
                let size = child.sizeThatFits(spanningProposal)
                result.placed.append(Arrangement.Placed(
                    node: child,
                    lineOffset: cursor,
                    lineExtent: extent,
                    crossOffset: 0,
                    crossExtent: crossTotal,
                    size: size,
                    proposal: spanningProposal,
                    alignment: alignment
                ))
                result.spans.append((tag: child.sectionTag, lo: cursor, hi: cursor + extent))
            case .cells(let cells):
                for (slot, cell) in cells.enumerated() {
                    guard let child = cell.node else { continue }
                    let track = resolved[slot]
                    let proposal = cellProposal(track)
                    result.placed.append(Arrangement.Placed(
                        node: child,
                        lineOffset: cursor,
                        lineExtent: extent,
                        crossOffset: lead + trackOffsets[slot],
                        crossExtent: track.extent,
                        size: child.sizeThatFits(proposal),
                        proposal: proposal,
                        alignment: track.alignment
                    ))
                }
                result.spans.append((tag: nil, lo: cursor, hi: cursor + extent))
            }
            cursor += extent
        }

        result.total[axis] = cursor
        result.total[crossAxis] = crossTotal
        return result
    }
}
