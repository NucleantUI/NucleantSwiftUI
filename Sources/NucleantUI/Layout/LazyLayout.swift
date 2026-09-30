//
//  LazyLayout.swift
//  NucleantUI
//
//  What makes `LazyVStack`, `LazyHStack`, `LazyVGrid` and `LazyHGrid` lazy.
//
//  The builder runs before layout, so a lazy container can't ask "what is
//  on screen?" while it builds. It keeps a *window* instead — the run of its
//  items that exist as views — in `@State`, and builds under it. Items are
//  counted in *units*: one per element of a `ForEach` whatever that element
//  flattens into, one per any other view. A `ForEach` reached through
//  nothing but transparent views (a `Group`, a `Section`, an `if`) builds
//  only the elements inside the window and stands a `LazyGapContent` in
//  for each run it skipped; everything else is built as usual.
//
//  Layout then sizes the gaps from the extents it measured for those units
//  before (or an average), finds which units fall inside the clip, and
//  moves the window when the clip is about to leave it. That write lands
//  like any other `@State` write: the next frame rebuilds the container,
//  and only it. The window reaches a viewport past the clip each way, so a
//  scroll is in built rows long before it would reach a gap.
//
//  A row's `@State` goes with it when it leaves the window, and its
//  `onAppear` runs again when it comes back — which is also what makes
//  "load more when the last row appears" work. Keep what must outlive the
//  scroll in a model.
//

/// The units of a lazy container that are built as views.
struct LazyWindow: Hashable {
    var units: Range<Int>

    /// Enough to fill a first screen before layout has said what it needs.
    static let initial = LazyWindow(units: 0..<32)
}

/// Carried down a lazy container's build, through the views that dissolve
/// into its layout, counting units as they are built.
@MainActor
final class LazyBuildCursor {
    /// The container's path, hashed — which gaps and tags are its own.
    let owner: Int
    let window: Range<Int>
    /// The unit the next item built will be.
    var position: Int

    init(owner: Int, window: Range<Int>, position: Int = 0) {
        self.owner = owner
        self.window = window
        self.position = position
    }

    /// What a view built at the cursor's current position depends on: the
    /// same window and the same starting unit build the same items.
    var key: LazyBuildKey {
        LazyBuildKey(owner: owner, window: window, start: position)
    }
}

/// Recorded with every view built under a lazy container, so a standing
/// view is only reused where it would build the same units — and so a
/// scoped rebuild of it builds under the same window.
struct LazyBuildKey: Equatable {
    let owner: Int
    let window: Range<Int>
    let start: Int
}

/// Which element of a lazy container's `ForEach` a node belongs to.
/// Every node an element flattens into carries it, so the container can
/// tell one element's nodes from the next.
struct LazyElementTag: Equatable {
    let owner: Int
    let unit: Int
}

/// Builtins a lazy container's cursor passes through: they dissolve into
/// the container's layout, so what they contain are the container's items.
/// Every other builtin is one item, and builds what is inside it eagerly.
@MainActor
protocol LazyPassThrough {}

extension TupleView: LazyPassThrough {}
extension Group: LazyPassThrough {}
extension EmptyView: LazyPassThrough {}
extension _ViewArray: LazyPassThrough {}
extension _ConditionalContent: LazyPassThrough {}
extension Optional: LazyPassThrough where Wrapped: View {}
extension AnyView: LazyPassThrough {}
extension ForEach: LazyPassThrough {}

/// Views that are containers of a lazy container's items rather than items
/// themselves — a `Section` holds rows. A `ForEach` of these builds every
/// element, and the `ForEach`es inside them build lazily: a list of months
/// is windowed by the photo, not by the month.
@MainActor
protocol LazyExpandable {}

extension Section: LazyExpandable {}

/// A run of `count` elements of a `ForEach`, starting at unit `start`, that
/// the window leaves unbuilt. Draws nothing; its container gives it the
/// extent those elements are expected to have.
struct LazyGapContent: NodeContent {
    let owner: Int
    let start: Int
    let count: Int

    var units: Range<Int> { start..<(start + count) }

    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size { .zero }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {}
}

extension ViewNode {
    /// How many layout children this node stands for — what an item built
    /// under a lazy cursor adds to its count.
    var lazyLayoutCount: Int {
        content.isTransparent ? layoutChildren.count : 1
    }

    /// Tag every node `self` flattens into as part of one element.
    func tagLazyElement(_ tag: LazyElementTag) {
        if content.isTransparent {
            for child in children where child.removal == nil {
                child.tagLazyElement(tag)
            }
        } else {
            lazyTag = tag
        }
    }
}

// MARK: - ForEach under a window

extension ForEach {
    /// Build only the elements inside `cursor`'s window; each run outside
    /// it becomes one gap. The elements themselves are built as ever —
    /// keyed by id, so a row keeps its state while it stays in the window.
    func makeLazyNode(_ context: inout BuildContext, cursor: LazyBuildCursor) -> ViewNode {
        if Content.self is any LazyExpandable.Type {
            return makeExpandedLazyNode(&context, cursor: cursor)
        }
        let path = context.path
        let count = data.count
        let start = cursor.position
        let lower = min(max(cursor.window.lowerBound - start, 0), count)
        let upper = min(max(cursor.window.upperBound - start, lower), count)

        // What a row contains is built eagerly: it is one item.
        var rows = context
        rows.lazyCursor = nil

        var built: [(index: Int, node: ViewNode, isNew: Bool)] = []
        built.reserveCapacity(upper - lower)
        var position = data.index(data.startIndex, offsetBy: lower)
        for offset in lower..<upper {
            let element = data[position]
            position = data.index(after: position)
            let index = identify(element).hashValue
            let isNew = rows.isNewChild(at: index)
            let node = rows.child(index) { ctx in
                let row = trackingObservation(at: path) { build(element) }
                return buildNode(row, &ctx)
            }
            node.tagLazyElement(LazyElementTag(owner: cursor.owner, unit: start + offset))
            built.append((index: index, node: node, isNew: isNew))
        }

        var children: [ViewNode] = []
        if lower > 0 {
            children.append(ViewNode(content: LazyGapContent(owner: cursor.owner, start: start, count: lower)))
        }
        children += rows.structuralChildren(built)
        if upper < count {
            children.append(ViewNode(content: LazyGapContent(owner: cursor.owner, start: start + upper, count: count - upper)))
        }
        cursor.position = start + count
        return ViewNode(content: GroupContent(), children: children)
    }

    /// Every element built, under the cursor: each is a section whose own
    /// rows are what the window is over, and which count their own units.
    private func makeExpandedLazyNode(_ context: inout BuildContext, cursor: LazyBuildCursor) -> ViewNode {
        let path = context.path
        let built = data.map { element in
            let index = identify(element).hashValue
            let isNew = context.isNewChild(at: index)
            let node = context.child(index) { ctx in
                let row = trackingObservation(at: path) { build(element) }
                return buildNode(row, &ctx)
            }
            return (index: index, node: node, isNew: isNew)
        }
        return ViewNode(content: GroupContent(), children: context.structuralChildren(built))
    }
}

// MARK: - Reading a container's items back

/// One item of a lazy container as layout sees it: the nodes one element
/// (or one plain view) flattened into, or a gap of unbuilt units.
struct LazyItem {
    enum Kind {
        case built([ViewNode])
        case gap
    }
    let kind: Kind
    let units: Range<Int>
}

extension ViewNode {
    /// The lazy container's layout children grouped back into its units.
    /// Plain views are numbered on from whatever came before them, so the
    /// numbering matches the one the build counted.
    func lazyItems(owner: Int) -> [LazyItem] {
        var items: [LazyItem] = []
        var next = 0
        for child in layoutChildren {
            if let gap = child.content as? LazyGapContent, gap.owner == owner {
                items.append(LazyItem(kind: .gap, units: gap.units))
                next = gap.units.upperBound
            } else if let tag = child.lazyTag, tag.owner == owner {
                if let last = items.last, last.units == tag.unit..<(tag.unit + 1), case .built(let nodes) = last.kind {
                    items[items.count - 1] = LazyItem(kind: .built(nodes + [child]), units: last.units)
                } else {
                    items.append(LazyItem(kind: .built([child]), units: tag.unit..<(tag.unit + 1)))
                }
                next = tag.unit + 1
            } else {
                items.append(LazyItem(kind: .built([child]), units: next..<(next + 1)))
                next += 1
            }
        }
        return items
    }
}

// MARK: - Deciding the window

/// Collects, during placement, which units lie in the visible stretch of
/// the container's main axis and which in the stretch a window should
/// cover. Offsets are the container's own, from its leading edge.
struct LazyVisibility {
    /// What must be built now: the clip and a margin.
    let need: ClosedRange<Double>
    /// What a new window covers: a viewport more each way.
    let want: ClosedRange<Double>
    private(set) var needUnits: Range<Int>?
    private(set) var wantUnits: Range<Int>?

    /// `visible` is the clip along the main axis in the container's offsets;
    /// `nil` when nothing clips it, which makes every unit visible.
    init(visible: ClosedRange<Double>?) {
        if let visible {
            let length = max(visible.upperBound - visible.lowerBound, 1)
            need = (visible.lowerBound - length / 2)...(visible.upperBound + length / 2)
            want = (visible.lowerBound - length)...(visible.upperBound + length)
        } else {
            need = -Double.infinity...Double.infinity
            want = need
        }
    }

    mutating func visit(_ units: Range<Int>, from lo: Double, to hi: Double) {
        guard !units.isEmpty else { return }
        if hi >= need.lowerBound, lo <= need.upperBound {
            needUnits = Self.union(needUnits, units)
        }
        if hi >= want.lowerBound, lo <= want.upperBound {
            wantUnits = Self.union(wantUnits, units)
        }
    }

    private static func union(_ a: Range<Int>?, _ b: Range<Int>) -> Range<Int> {
        guard let a else { return b }
        return min(a.lowerBound, b.lowerBound)..<max(a.upperBound, b.upperBound)
    }

    /// The window to ask for, or `nil` to keep `current`: it is kept while
    /// it covers what must be built and isn't holding far more than wanted.
    func request(current: Range<Int>) -> Range<Int>? {
        guard let needUnits else { return nil }
        let wanted = wantUnits ?? needUnits
        let covers = current.lowerBound <= needUnits.lowerBound && current.upperBound >= needUnits.upperBound
        let oversized = current.count > max(wanted.count * 3, 64)
        if covers && !oversized { return nil }
        return wanted == current ? nil : wanted
    }
}

/// What a lazy container remembers between passes: the extents it measured
/// for its units (so an unbuilt one is sized as it last was), and which of
/// its nodes are pinned over the rest.
@MainActor
final class LazyLayoutMemory {
    /// Main-axis extent by unit; NaN where never measured.
    private var extents: [Double] = []
    private var knownTotal = 0.0
    private var knownCount = 0
    /// The cross extent the extents were measured at — a wider stack wraps
    /// its text less, so they are dropped when it changes.
    private var crossExtent: Double?

    /// The nodes drawn pinned in the last pass, tested first for hits.
    var pinned: Set<ObjectIdentifier> = []

    func noteCrossExtent(_ extent: Double) {
        guard extent != crossExtent else { return }
        crossExtent = extent
        extents.removeAll()
        knownTotal = 0
        knownCount = 0
    }

    func extent(of unit: Int) -> Double? {
        guard unit < extents.count, !extents[unit].isNaN else { return nil }
        return extents[unit]
    }

    func record(_ extent: Double, for unit: Int) {
        if unit >= extents.count {
            extents.append(contentsOf: repeatElement(.nan, count: unit - extents.count + 1))
        }
        let old = extents[unit]
        if old.isNaN {
            knownCount += 1
            knownTotal += extent
        } else {
            knownTotal += extent - old
        }
        extents[unit] = extent
    }

    /// The average of every extent measured so far.
    var average: Double? {
        knownCount > 0 ? knownTotal / Double(knownCount) : nil
    }
}

// MARK: - Pinned section headers and footers

/// Tags a `Section`'s header or footer node, so a lazy container with
/// `pinnedViews` can hold it at the edge while its section scrolls by.
struct SectionTag: Equatable {
    enum Role { case header, footer }
    let role: Role
    /// The section's position, hashed — pairs a header with its footer.
    let section: Int
}

/// Pinning in a lazy container: `natural` is where layout put each tagged
/// node, along the main axis, in the container's offsets; the result is
/// where each pinned one is drawn instead.
struct LazyPinning {
    struct Placed {
        let index: Int
        let tag: SectionTag
        let lo: Double
        let hi: Double
    }

    /// Every item's span with its section tag, in order — how far each
    /// section reaches is read off this.
    static func pinnedOffsets(
        spans: [(tag: SectionTag?, lo: Double, hi: Double)],
        placed: [Placed],
        pinnedViews: PinnedScrollableViews,
        visible: ClosedRange<Double>
    ) -> [Int: Double] {
        // How far each section reaches: from its header (or the end of the
        // section before) to its last item.
        var starts: [Int: Double] = [:]
        var ends: [Int: Double] = [:]
        var headerExtents: [Int: Double] = [:]
        var open: Int?
        var boundary = spans.first?.lo ?? 0
        for span in spans {
            if let tag = span.tag {
                switch tag.role {
                case .header:
                    open = tag.section
                    starts[tag.section] = span.lo
                    headerExtents[tag.section] = span.hi - span.lo
                    boundary = span.lo
                case .footer:
                    if starts[tag.section] == nil { starts[tag.section] = boundary }
                    ends[tag.section] = max(ends[tag.section] ?? span.hi, span.hi)
                    open = nil
                    boundary = span.hi
                    continue
                }
            }
            if let open {
                ends[open] = max(ends[open] ?? span.hi, span.hi)
            }
        }

        var offsets: [Int: Double] = [:]
        for item in placed {
            let extent = item.hi - item.lo
            switch item.tag.role {
            case .header where pinnedViews.contains(.sectionHeaders):
                let end = ends[item.tag.section] ?? item.hi
                // Held at the top edge, but never below its own section's
                // end — the next section's header pushes it off.
                let pinned = min(max(item.lo, visible.lowerBound), end - extent)
                offsets[item.index] = max(pinned, item.lo)
            case .footer where pinnedViews.contains(.sectionFooters):
                let start = starts[item.tag.section] ?? item.lo
                let header = pinnedViews.contains(.sectionHeaders) ? (headerExtents[item.tag.section] ?? 0) : 0
                let pinned = max(min(item.lo, visible.upperBound - extent), start + header)
                offsets[item.index] = min(pinned, item.lo)
            default:
                continue
            }
        }
        return offsets
    }
}

/// The views a lazy stack or grid keeps at the visible edge while their
/// section scrolls under them.
public struct PinnedScrollableViews: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Each section's header stays at the leading edge while any of its
    /// section is visible.
    public static let sectionHeaders = PinnedScrollableViews(rawValue: 1 << 0)

    /// Each section's footer stays at the trailing edge while any of its
    /// section is visible.
    public static let sectionFooters = PinnedScrollableViews(rawValue: 1 << 1)
}

extension Rect {
    /// The span along one axis, for code written once for both.
    func lazySpan(along axis: Axis) -> ClosedRange<Double> {
        axis == .horizontal ? minX...maxX : minY...maxY
    }
}
