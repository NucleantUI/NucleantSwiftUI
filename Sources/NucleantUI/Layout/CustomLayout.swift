//
//  CustomLayout.swift
//  NucleantUI
//
//  SwiftUI's `Layout` protocol: a container whose sizing and placement are
//  written by the app. A layout used as a view (`MyLayout { … }`) becomes
//  one node, `CustomLayoutContent`, whose children are its subviews. Its
//  `sizeThatFits` answers the node's; its `placeSubviews` records where each
//  subview goes through `LayoutSubview.place`, and the node then places them
//  there — every child at the proposal the layout gave it, as the stacks do.
//

/// The proposal a container makes to a view — SwiftUI's name for it.
public typealias ProposedViewSize = ProposedSize

/// A container that sizes and places its subviews by rules of its own.
///
/// ```swift
/// struct EqualWidthHStack: Layout {
///     func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> Size {
///         let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
///         let tallest = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
///         return Size(width: widest * Double(subviews.count), height: tallest)
///     }
///
///     func placeSubviews(in bounds: Rect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
///         let width = bounds.width / Double(max(subviews.count, 1))
///         for (index, subview) in subviews.enumerated() {
///             subview.place(
///                 at: Point(x: bounds.minX + width * (Double(index) + 0.5), y: bounds.midY),
///                 anchor: .center,
///                 proposal: ProposedViewSize(width: width, height: bounds.height)
///             )
///         }
///     }
/// }
///
/// EqualWidthHStack {
///     Button("Cancel") { … }
///     Button("Save changes") { … }
/// }
/// ```
///
/// A subview the layout doesn't place is centred in its bounds at its
/// ideal size. `animatableData` animates like any `Animatable`: a layout
/// whose parameters change under an animation is laid out at each value in
/// between.
@MainActor @preconcurrency
public protocol Layout: Animatable {
    /// How the container behaves toward what's inside it — a `Spacer` or
    /// `Divider` in one follows `stackOrientation`.
    static var layoutProperties: LayoutProperties { get }

    /// Whatever the layout wants to keep between calls — measurements it
    /// would otherwise repeat. `Void` when it keeps nothing.
    associatedtype Cache = Void

    typealias Subviews = LayoutSubviews

    /// A fresh cache, made the first time the layout is asked anything.
    func makeCache(subviews: Subviews) -> Cache

    /// Brings `cache` up to date after the subviews changed.
    func updateCache(_ cache: inout Cache, subviews: Subviews)

    /// The spacing this container asks of whatever sits next to it.
    func spacing(subviews: Subviews, cache: inout Cache) -> ViewSpacing

    /// The size the container takes under `proposal`.
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> Size

    /// Places each subview inside `bounds` with `LayoutSubview.place`.
    /// `bounds` is in the same space as the positions given to `place`, and
    /// `proposal` is the one that produced it.
    func placeSubviews(in bounds: Rect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache)
}

extension Layout {
    public static var layoutProperties: LayoutProperties { LayoutProperties() }

    public func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    public func spacing(subviews: Subviews, cache: inout Cache) -> ViewSpacing {
        var spacing = ViewSpacing()
        for subview in subviews {
            spacing.formUnion(subview.spacing)
        }
        return spacing
    }
}

extension Layout where Cache == () {
    public func makeCache(subviews: Subviews) -> Cache { () }
}

extension Layout {
    /// Lays `content` out with this layout.
    ///
    /// ```swift
    /// let layout = isWide ? AnyLayout(HStackLayout()) : AnyLayout(VStackLayout())
    /// layout {
    ///     Avatar()
    ///     Details()
    /// }
    /// ```
    public func callAsFunction<V: View>(
        _viewID: ViewID = #viewID,
        @ViewBuilder _ content: () -> V
    ) -> some View {
        _LayoutView(layout: self, content: content(), _viewID: _viewID)
    }
}

/// What a container says about how it lays out.
public struct LayoutProperties: Sendable {
    public init() {}

    /// The axis the container stacks along, if it stacks along one — what a
    /// `Spacer` or `Divider` inside it stretches or draws across.
    public var stackOrientation: Axis?
}

// MARK: - Subviews

/// The views a `Layout` arranges, in order.
///
/// A `ForEach` or `Group` among them contributes each of its views, as in a
/// stack.
public struct LayoutSubviews: Equatable, RandomAccessCollection {
    public typealias SubSequence = LayoutSubviews
    public typealias Element = LayoutSubview
    public typealias Index = Int
    public typealias Indices = Range<Int>
    public typealias Iterator = IndexingIterator<LayoutSubviews>

    private let elements: [LayoutSubview]
    public let startIndex: Int
    public let endIndex: Int

    init(_ elements: [LayoutSubview]) {
        self.init(elements, range: elements.indices)
    }

    private init(_ elements: [LayoutSubview], range: Range<Int>) {
        self.elements = elements
        self.startIndex = range.lowerBound
        self.endIndex = range.upperBound
    }

    public subscript(index: Int) -> LayoutSubview { elements[index] }

    /// Shares its indices with this collection, as any slice does.
    public subscript(bounds: Range<Int>) -> LayoutSubviews {
        LayoutSubviews(elements, range: bounds)
    }

    /// The subviews at `indices`, in that order, indexed from zero.
    public subscript<S: Sequence>(indices: S) -> LayoutSubviews where S.Element == Int {
        LayoutSubviews(indices.map { elements[$0] })
    }

    public static func == (lhs: LayoutSubviews, rhs: LayoutSubviews) -> Bool {
        lhs.endIndex - lhs.startIndex == rhs.endIndex - rhs.startIndex
            && zip(lhs.elements[lhs.startIndex..<lhs.endIndex], rhs.elements[rhs.startIndex..<rhs.endIndex])
                .allSatisfy { $0 == $1 }
    }
}

/// One view a `Layout` arranges: something to measure and to place.
@MainActor
public struct LayoutSubview: Equatable {
    let node: ViewNode
    /// Where placements go while the layout is placing; `nil` while it is
    /// only measuring, when `place` has nothing to do.
    let placements: LayoutPlacements?
    let index: Int

    /// The value this subview set for `key` with `.layoutValue(key:value:)`,
    /// or the key's default.
    public subscript<K: LayoutValueKey>(key: K.Type) -> K.Value {
        node.layoutValues?.value(for: key) ?? K.defaultValue
    }

    /// The size the subview takes under `proposal`.
    public func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        node.sizeThatFits(proposal)
    }

    /// The subview's size under `proposal`, with its alignment guides.
    public func dimensions(in proposal: ProposedViewSize) -> ViewDimensions {
        ViewDimensions(size: node.sizeThatFits(proposal))
    }

    /// The spacing the subview asks of its neighbours: the default gap, or
    /// what a custom layout says for itself.
    public var spacing: ViewSpacing {
        (node.content as? LayoutSpacingSource)?.spacing(node: node) ?? ViewSpacing()
    }

    /// Puts the subview's `anchor` at `position`, sized as it chooses under
    /// `proposal`. Only meaningful inside `placeSubviews`.
    public func place(at position: Point, anchor: UnitPoint = .topLeading, proposal: ProposedViewSize) {
        placements?.record(LayoutPlacement(position: position, anchor: anchor, proposal: proposal), at: index)
    }

    nonisolated public static func == (a: LayoutSubview, b: LayoutSubview) -> Bool {
        a.node === b.node && a.index == b.index
    }
}

/// A subview's size, and where its alignment guides fall within it.
public struct ViewDimensions: Equatable, Sendable {
    let size: Size

    public var width: Double { size.width }
    public var height: Double { size.height }

    public subscript(guide: HorizontalAlignment) -> Double {
        switch guide {
        case .leading:  return 0
        case .center:   return size.width / 2
        case .trailing: return size.width
        }
    }

    public subscript(guide: VerticalAlignment) -> Double {
        switch guide {
        case .top:    return 0
        case .center: return size.height / 2
        case .bottom: return size.height
        }
    }
}

/// The room a view asks for on each side of it, from what sits next to it.
///
/// Every view asks for the default gap — the same one a stack with no
/// `spacing:` leaves — unless it is a custom `Layout` that says otherwise.
public struct ViewSpacing: Equatable, Sendable {
    private var top: Double
    private var leading: Double
    private var bottom: Double
    private var trailing: Double

    /// The gap a stack leaves when given no `spacing:`.
    static let defaultGap: Double = 8

    /// No room asked on any side.
    public static let zero = ViewSpacing(all: 0)

    /// The default gap on every side.
    public init() {
        self.init(all: Self.defaultGap)
    }

    private init(all: Double) {
        top = all
        leading = all
        bottom = all
        trailing = all
    }

    /// Asks, on each of `edges`, for the larger of this and `other`.
    public mutating func formUnion(_ other: ViewSpacing, edges: Edge.Set = .all) {
        if edges.contains(.top) { top = max(top, other.top) }
        if edges.contains(.leading) { leading = max(leading, other.leading) }
        if edges.contains(.bottom) { bottom = max(bottom, other.bottom) }
        if edges.contains(.trailing) { trailing = max(trailing, other.trailing) }
    }

    public func union(_ other: ViewSpacing, edges: Edge.Set = .all) -> ViewSpacing {
        var copy = self
        copy.formUnion(other, edges: edges)
        return copy
    }

    /// The gap between this view and `next` after it along `axis`: the
    /// larger of what the two ask of the side they share.
    public func distance(to next: ViewSpacing, along axis: Axis) -> Double {
        switch axis {
        case .horizontal: return max(trailing, next.leading)
        case .vertical:   return max(bottom, next.top)
        }
    }
}

// MARK: - Layout values

/// A value a view hands the `Layout` it sits in, read through
/// `LayoutSubview[key]`.
///
/// ```swift
/// struct Rank: LayoutValueKey {
///     static let defaultValue = 1
/// }
///
/// PodiumLayout {
///     ForEach(runners) { runner in
///         Text(runner.name).layoutValue(key: Rank.self, value: runner.place)
///     }
/// }
/// ```
public protocol LayoutValueKey {
    associatedtype Value
    static var defaultValue: Value { get }
}

extension View {
    /// Hands `value` for `key` to the `Layout` this view sits in.
    public func layoutValue<K: LayoutValueKey>(key: K.Type, value: K.Value) -> some View {
        _LayoutValueModifier<K, Self>(content: self, value: value)
    }
}

/// The layout values set on one view, by key. Values set further out
/// replace those set further in.
struct LayoutValues {
    private var values: [ObjectIdentifier: OpaqueValue] = [:]

    func value<K: LayoutValueKey>(for key: K.Type) -> K.Value? {
        values[ObjectIdentifier(key)]?.value(as: K.Value.self)
    }

    mutating func set<K: LayoutValueKey>(_ value: K.Value, for key: K.Type) {
        values[ObjectIdentifier(key)] = OpaqueValue(value)
    }
}

/// `.layoutValue(key:value:)`: the view's own node, marked. A group's value
/// goes on each view in it, since each is a subview.
@View
struct _LayoutValueModifier<K: LayoutValueKey, Content: View>: View {
    let content: Content
    let value: K.Value

    var body: Never { bodyUnavailable() }
}

extension _LayoutValueModifier: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        let node = context.child(0) { ctx in buildNode(content, &ctx) }
        mark(node)
        return node
    }

    private func mark(_ node: ViewNode) {
        if node.content.isTransparent {
            for child in node.layoutChildren { mark(child) }
        } else {
            var values = node.layoutValues ?? LayoutValues()
            values.set(value, for: K.self)
            node.layoutValues = values
        }
    }
}

// MARK: - The view and its node

/// A `Layout` applied to content: `MyLayout { … }`.
@View
struct _LayoutView<L: Layout, Content: View>: View {
    let layout: L
    let content: Content

    var body: Never { bodyUnavailable() }
}

extension _LayoutView: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        // A layout whose parameters are animating is laid out at each value
        // in between, rebuilding this node — only this node; its subviews
        // are equivalent and stand — each frame until it arrives.
        let animated = layout._animated(in: context)
        if !animated.isFinished {
            context.animations.rebuildNextFrame(context.path)
        }
        let layout = animated.value

        var inner = context
        inner.stackAxis = layout._stackOrientation
        let child = inner.child(0) { ctx in buildNode(content, &ctx) }
        return ViewNode(content: CustomLayoutContent(layout: layout), children: [child])
    }
}

extension Layout {
    /// This layout as it shows in this frame, and whether it has arrived.
    /// `AnyLayout` answers for the layout it holds (see `AnyLayout.swift`).
    func _animated(in context: BuildContext) -> (value: Self, isFinished: Bool) {
        if let erased = self as? AnyLayout {
            let result = erased.storage.animated(in: context)
            return (result.layout as! Self, result.isFinished)
        }
        return context.animations.animated(self, at: context.path, animation: context.transaction.animation)
    }

    /// The axis `Spacer`s inside it follow. An instance member rather than
    /// the static one so `AnyLayout` can answer for what it holds.
    var _stackOrientation: Axis? {
        (self as? AnyLayout)?.stackOrientation ?? Self.layoutProperties.stackOrientation
    }
}

/// Where a subview was put by `placeSubviews`.
struct LayoutPlacement {
    let position: Point
    let anchor: UnitPoint
    let proposal: ProposedSize
}

/// Collects the placements of one `placeSubviews` call.
@MainActor
final class LayoutPlacements {
    private(set) var placements: [LayoutPlacement?]

    init(count: Int) {
        placements = Array(repeating: nil, count: count)
    }

    func record(_ placement: LayoutPlacement, at index: Int) {
        guard placements.indices.contains(index) else { return }
        placements[index] = placement
    }
}

/// A node content that wants to know when its subtree was replaced beneath
/// it — a layout whose cache was made from the old one.
@MainActor
protocol LayoutCacheOwner {
    func subviewsChanged()
}

/// A node content with a say in `LayoutSubview.spacing`.
@MainActor
protocol LayoutSpacingSource {
    func spacing(node: ViewNode) -> ViewSpacing
}

/// The cache of one layout node, made on first use and brought up to date
/// when a scoped rebuild changes the subviews beneath it.
@MainActor
final class LayoutCacheStorage<L: Layout> {
    var cache: L.Cache?
    var isStale = false
}

/// A `Layout`'s node.
struct CustomLayoutContent<L: Layout>: NodeContent, LayoutCacheOwner, LayoutSpacingSource {
    let layout: L
    let storage = LayoutCacheStorage<L>()

    func subviewsChanged() {
        storage.isStale = true
    }

    private func subviews(of node: ViewNode, placements: LayoutPlacements? = nil) -> LayoutSubviews {
        LayoutSubviews(node.layoutChildren.enumerated().map { index, child in
            LayoutSubview(node: child, placements: placements, index: index)
        })
    }

    /// Runs `body` with the layout's cache, made or updated first as needed,
    /// and keeps whatever `body` left in it.
    private func withCache<R>(_ subviews: LayoutSubviews, _ body: (inout L.Cache) -> R) -> R {
        var cache: L.Cache
        if let existing = storage.cache {
            cache = existing
            if storage.isStale {
                layout.updateCache(&cache, subviews: subviews)
            }
        } else {
            cache = layout.makeCache(subviews: subviews)
        }
        storage.isStale = false
        let result = body(&cache)
        storage.cache = cache
        return result
    }

    /// As flexible as its most flexible subview, as a stack is — the layout
    /// itself says nothing a stack around it could use.
    func flexibility(along axis: Axis, node: ViewNode) -> LayoutPriorityClass {
        node.layoutChildren.map { $0.flexibility(along: axis) }.max() ?? .content
    }

    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        let subviews = subviews(of: node)
        return withCache(subviews) { cache in
            layout.sizeThatFits(proposal: proposal, subviews: subviews, cache: &cache)
        }
    }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        let children = node.layoutChildren
        guard !children.isEmpty else { return }
        let placements = LayoutPlacements(count: children.count)
        let subviews = subviews(of: node, placements: placements)
        withCache(subviews) { cache in
            layout.placeSubviews(in: rect, proposal: proposal, subviews: subviews, cache: &cache)
        }
        for (index, child) in children.enumerated() {
            // Not placed by the layout: centred, at its ideal size.
            let placement = placements.placements[index]
                ?? LayoutPlacement(position: rect.center, anchor: .center, proposal: .unspecified)
            let size = child.sizeThatFits(placement.proposal)
            let origin = Point(
                x: placement.position.x - size.width * placement.anchor.x,
                y: placement.position.y - size.height * placement.anchor.y
            )
            child.place(
                in: Rect(origin: origin, size: size),
                proposal: placement.proposal,
                context: context,
                into: &list
            )
        }
    }

    func spacing(node: ViewNode) -> ViewSpacing {
        let subviews = subviews(of: node)
        return withCache(subviews) { cache in
            layout.spacing(subviews: subviews, cache: &cache)
        }
    }
}
