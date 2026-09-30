//
//  AnyLayout.swift
//  NucleantUI
//

/// A layout whose type is chosen at run time.
///
/// Switching the layout a container uses keeps its subviews — their
/// identity, their `@State` — because the container is the same view
/// throughout; only the arrangement changes, and under an animation the
/// subviews move to their new places.
///
/// ```swift
/// let layout = isCompact ? AnyLayout(VStackLayout()) : AnyLayout(HStackLayout())
/// layout {
///     Avatar(user)
///     Profile(user)
/// }
/// ```
///
/// Animation, under `withAnimation` or `.animation(_:value:)`, comes in two
/// kinds:
/// * Switching to a layout of another type moves each subview from its old
///   frame to its new one. The two layouts' values have nothing in common
///   to interpolate.
/// * Changing the parameters of the same type of layout animates its
///   `animatableData`, as if the layout were used directly. A radial layout
///   turning swings its subviews round the circle, instead of moving them
///   in straight lines.
public struct AnyLayout: Layout {
    let storage: AnyLayoutStorage

    public init<L: Layout>(_ layout: L) {
        if let erased = layout as? AnyLayout {
            storage = erased.storage
        } else {
            storage = LayoutStorage(layout)
        }
    }

    init(storage: AnyLayoutStorage) {
        self.storage = storage
    }

    /// The wrapped layout's cache.
    public struct Cache {
        let box: AnyLayoutCache
    }

    public typealias AnimatableData = EmptyAnimatableData

    /// What the wrapped layout stacks along — `layoutProperties` is static,
    /// and can't know.
    var stackOrientation: Axis? { storage.stackOrientation }

    public func makeCache(subviews: Subviews) -> Cache {
        Cache(box: storage.makeCache(subviews: subviews))
    }

    public func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = Cache(box: storage.updateCache(cache.box, subviews: subviews))
    }

    public func spacing(subviews: Subviews, cache: inout Cache) -> ViewSpacing {
        storage.spacing(subviews: subviews, cache: &cache)
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> Size {
        storage.sizeThatFits(proposal: proposal, subviews: subviews, cache: &cache)
    }

    public func placeSubviews(in bounds: Rect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        storage.placeSubviews(in: bounds, proposal: proposal, subviews: subviews, cache: &cache)
    }
}

extension AnyLayout: ViewInput {
    /// The same wrapped layout, with equivalent parameters — so a container
    /// whose parent re-runs keeps its node while the layout is unchanged.
    public func _isEquivalent(to other: AnyLayout) -> Bool {
        storage === other.storage || storage.isEquivalent(to: other.storage)
    }
}

// MARK: - Storage

/// A layout's cache behind a common class, for `AnyLayout.Cache`.
@MainActor
class AnyLayoutCache {}

@MainActor
final class LayoutCacheBox<L: Layout>: AnyLayoutCache {
    var cache: L.Cache

    init(_ cache: L.Cache) {
        self.cache = cache
    }
}

/// A layout behind a common class. Each method is overridden by
/// `LayoutStorage<L>`, the only subclass.
@MainActor
class AnyLayoutStorage {
    var stackOrientation: Axis? { fatalError("abstract") }

    func isEquivalent(to other: AnyLayoutStorage) -> Bool { fatalError("abstract") }

    /// The wrapped layout as it shows in this frame — see `_LayoutView`.
    func animated(in context: BuildContext) -> (layout: AnyLayout, isFinished: Bool) { fatalError("abstract") }

    func makeCache(subviews: LayoutSubviews) -> AnyLayoutCache { fatalError("abstract") }

    func updateCache(_ cache: AnyLayoutCache, subviews: LayoutSubviews) -> AnyLayoutCache { fatalError("abstract") }

    func spacing(subviews: LayoutSubviews, cache: inout AnyLayout.Cache) -> ViewSpacing { fatalError("abstract") }

    func sizeThatFits(proposal: ProposedSize, subviews: LayoutSubviews, cache: inout AnyLayout.Cache) -> Size {
        fatalError("abstract")
    }

    func placeSubviews(in bounds: Rect, proposal: ProposedSize, subviews: LayoutSubviews, cache: inout AnyLayout.Cache) {
        fatalError("abstract")
    }
}

@MainActor
final class LayoutStorage<L: Layout>: AnyLayoutStorage {
    let layout: L

    init(_ layout: L) {
        self.layout = layout
    }

    override var stackOrientation: Axis? { L.layoutProperties.stackOrientation }

    override func isEquivalent(to other: AnyLayoutStorage) -> Bool {
        guard let other = other as? LayoutStorage<L> else { return false }
        return _areEquivalent(layout, other.layout)
    }

    override func animated(in context: BuildContext) -> (layout: AnyLayout, isFinished: Bool) {
        guard L.AnimatableData.self != EmptyAnimatableData.self else {
            return (AnyLayout(storage: self), true)
        }
        // Animated as `TypedLayoutData<L>` rather than as `L.AnimatableData`:
        // the store keeps one value per path, by type, and another layout
        // with the same kind of data (a `Double`, say) must not animate from
        // this one's.
        let result = context.animations.animated(
            TypedLayout(layout: layout),
            at: context.path,
            animation: context.transaction.animation
        )
        guard !result.isFinished else { return (AnyLayout(storage: self), true) }
        return (AnyLayout(result.value.layout), false)
    }

    override func makeCache(subviews: LayoutSubviews) -> AnyLayoutCache {
        LayoutCacheBox<L>(layout.makeCache(subviews: subviews))
    }

    override func updateCache(_ cache: AnyLayoutCache, subviews: LayoutSubviews) -> AnyLayoutCache {
        // A cache another layout made — the container switched layouts —
        // is no use to this one.
        guard let box = cache as? LayoutCacheBox<L> else { return makeCache(subviews: subviews) }
        layout.updateCache(&box.cache, subviews: subviews)
        return box
    }

    /// This layout's own cache out of `cache`, made fresh if `cache` was
    /// made by another.
    private func box(_ cache: inout AnyLayout.Cache, subviews: LayoutSubviews) -> LayoutCacheBox<L> {
        if let box = cache.box as? LayoutCacheBox<L> { return box }
        let box = LayoutCacheBox<L>(layout.makeCache(subviews: subviews))
        cache = AnyLayout.Cache(box: box)
        return box
    }

    override func spacing(subviews: LayoutSubviews, cache: inout AnyLayout.Cache) -> ViewSpacing {
        let box = box(&cache, subviews: subviews)
        return layout.spacing(subviews: subviews, cache: &box.cache)
    }

    override func sizeThatFits(proposal: ProposedSize, subviews: LayoutSubviews, cache: inout AnyLayout.Cache) -> Size {
        let box = box(&cache, subviews: subviews)
        return layout.sizeThatFits(proposal: proposal, subviews: subviews, cache: &box.cache)
    }

    override func placeSubviews(in bounds: Rect, proposal: ProposedSize, subviews: LayoutSubviews, cache: inout AnyLayout.Cache) {
        let box = box(&cache, subviews: subviews)
        layout.placeSubviews(in: bounds, proposal: proposal, subviews: subviews, cache: &box.cache)
    }
}

// MARK: - Animating the wrapped layout

/// A layout seen as an `Animatable` whose data carries the layout's type.
@MainActor
struct TypedLayout<L: Layout>: Animatable {
    var layout: L

    var animatableData: TypedLayoutData<L> {
        get { TypedLayoutData(value: layout.animatableData) }
        set { layout.animatableData = newValue.value }
    }
}

/// `L.AnimatableData`, as a type of its own for each `L`.
struct TypedLayoutData<L: Layout>: VectorArithmetic {
    var value: L.AnimatableData

    static var zero: Self { Self(value: .zero) }
    static func + (lhs: Self, rhs: Self) -> Self { Self(value: lhs.value + rhs.value) }
    static func - (lhs: Self, rhs: Self) -> Self { Self(value: lhs.value - rhs.value) }
    static func += (lhs: inout Self, rhs: Self) { lhs.value += rhs.value }
    static func -= (lhs: inout Self, rhs: Self) { lhs.value -= rhs.value }
    mutating func scale(by rhs: Double) { value.scale(by: rhs) }
    var magnitudeSquared: Double { value.magnitudeSquared }
}
