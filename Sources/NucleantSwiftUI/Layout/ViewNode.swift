//
//  ViewNode.swift
//  NucleantSwiftUI
//
//  One node of the laid-out tree. State lives in `StateStore`, not here, so
//  a node is cheap to throw away — and cheap to keep: a subtree whose view
//  came out equivalent on the next build is grafted into the new tree as is
//  (see `buildNode`). A class so `place` can write frames back for hit
//  testing without threading everything through inout, and so that graft is
//  a pointer swap.
//

@MainActor
final class ViewNode {

    let content: any NodeContent

    private(set) var children: [ViewNode]

    /// Where this node sits in its parent, so a scoped rebuild can put the
    /// replacement back in the same slot. Weak upward, strong downward — the
    /// tree owns its children.
    private(set) weak var parent: ViewNode?
    private(set) var indexInParent: Int = 0

    /// Where `place` put this node. Absolute window coordinates, in points.
    var frame: Rect = .zero

    /// The transform in effect when it was placed — hit testing has to undo it
    /// to map a window point into the node's own space.
    var transform: Transform = .identity

    /// Measurements taken so far, keyed by the proposal that produced them.
    ///
    /// Layout asks the same question repeatedly: a stack measures every child
    /// to decide the run, then `place` measures them again to position them,
    /// and each level above repeats that for its whole subtree. Uncached, a
    /// 195-node tree took 567 `sizeThatFits` calls.
    ///
    /// A node is only kept across passes when nothing that feeds its size
    /// changed — same view value, same environment, no dirty state below —
    /// so an entry stays valid for as long as the node does. What can grow
    /// is the *number* of proposals a long-lived node has seen (every window
    /// size during a drag-resize), hence the cap.
    private var measurements: [ProposedSize: Size] = [:]
    /// `flexibility(along:)` walks the subtree; cached alongside the sizes
    /// and dropped with them.
    private var flexibilities: [Axis: LayoutPriorityClass] = [:]

    init(content: any NodeContent, children: [ViewNode] = []) {
        self.content = content
        self.children = children
        PerfTrace.nodesBuilt += 1
        for (index, child) in children.enumerated() {
            child.parent = self
            child.indexInParent = index
        }
    }

    /// Swap `replacement` in for the child at `index` — how a scoped rebuild
    /// grafts a freshly built subtree onto the tree that is still standing.
    func replaceChild(at index: Int, with replacement: ViewNode) {
        guard children.indices.contains(index) else { return }
        children[index] = replacement
        replacement.parent = self
        replacement.indexInParent = index
    }

    /// Discard measurements that the swap above may have falsified.
    ///
    /// The new subtree starts with an empty cache of its own, but every
    /// ancestor cached a size that was computed *from* the old one — a stack
    /// that measured its run, the frame above it, and so on to the root.
    func invalidateMeasurementsUpwards() {
        var node: ViewNode? = self
        while let current = node {
            current.measurements.removeAll(keepingCapacity: true)
            current.flexibilities.removeAll(keepingCapacity: true)
            node = current.parent
        }
    }

    /// Children as the layout sees them: transparent nodes (`Group`, a
    /// `TupleView`, `ForEach`) dissolve into their own children, so a stack
    /// treats a group's contents as its own siblings — SwiftUI's rule.
    var layoutChildren: [ViewNode] {
        guard children.contains(where: { $0.content.isTransparent }) else { return children }
        return children.flatMap { child in
            child.content.isTransparent ? child.layoutChildren : [child]
        }
    }

    /// The single child a modifier node wraps.
    ///
    /// A modifier applied to a multi-child `Group` takes the first child only;
    /// SwiftUI would distribute the modifier over each. Worth knowing, but not
    /// worth a second layout mode — write the modifier inside the group.
    var singleChild: ViewNode? { layoutChildren.first }

    /// How this node competes for space in a stack — see `NodeContent`.
    func flexibility(along axis: Axis) -> LayoutPriorityClass {
        if let cached = flexibilities[axis] { return cached }
        let result = content.flexibility(along: axis, node: self)
        flexibilities[axis] = result
        return result
    }

    func sizeThatFits(_ proposal: ProposedSize) -> Size {
        if let cached = measurements[proposal] { return cached }
        PerfTrace.sizeCalls += 1
        let size = content.sizeThatFits(proposal, node: self)
        if measurements.count >= 16 { measurements.removeAll(keepingCapacity: true) }
        measurements[proposal] = size
        return size
    }

    /// Position this node in `rect`.
    ///
    /// `proposal` is the proposal that *produced* `rect`, carried alongside it
    /// rather than re-derived from `rect.size`. A node whose size is a function
    /// of its proposal — `.relativeSize`, say — would otherwise have that
    /// function applied a second time to its own output: a 82% fill measured at
    /// 541pt would be re-measured against 541 and come out 443. SwiftUI threads
    /// the proposal through placement for the same reason.
    func place(
        in rect: Rect,
        proposal: ProposedSize,
        context: DrawContext,
        into list: inout DisplayList
    ) {
        frame = rect
        transform = context.transform
        content.place(node: self, in: rect, proposal: proposal, context: context, into: &list)
    }
}

/// What a node actually *is* — the layout and drawing behaviour behind it.
/// Every builtin view maps to one of these.
@MainActor
protocol NodeContent {

    /// True when the node contributes its children to the parent's layout
    /// rather than laying them out itself.
    var isTransparent: Bool { get }

    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size

    func place(
        node: ViewNode,
        in rect: Rect,
        proposal: ProposedSize,
        context: DrawContext,
        into list: inout DisplayList
    )

    /// A tap handler, if this node has one. Hit testing walks the placed tree
    /// back-to-front looking for these.
    var hitTarget: HitTarget? { get }

    /// True for a subtree kept in the tree but off screen (`._parked`). Its
    /// nodes still carry the frames from when they were last placed, and hit
    /// testing must not trust them.
    var isParked: Bool { get }

    /// True when this node clips its children to its own frame — a
    /// `ScrollView`, `.clipped()`, `.cornerRadius()`. What is not drawn must
    /// not be hit either: a row scrolled up under a navigation bar would
    /// otherwise take the tap meant for the bar.
    var clipsChildren: Bool { get }

    /// How eagerly this node consumes leftover space along `axis` — a stack
    /// sizes its least flexible children first so a greedy sibling can't
    /// squeeze a `Text`. Takes the node so a wrapper can answer for what it
    /// wraps and a stack for its children.
    func flexibility(along axis: Axis, node: ViewNode) -> LayoutPriorityClass
}

extension NodeContent {
    var isTransparent: Bool { false }
    var hitTarget: HitTarget? { nil }
    var isParked: Bool { false }
    var clipsChildren: Bool { false }

    /// Most nodes are as flexible as whatever they wrap — a padded, tinted,
    /// tappable fixed frame is still fixed. Only a `Spacer` (fully flexible),
    /// a `.frame` (whatever it constrains to) and the stacks (their children)
    /// say otherwise; a leaf with nothing inside is content-sized.
    func flexibility(along axis: Axis, node: ViewNode) -> LayoutPriorityClass {
        node.singleChild?.flexibility(along: axis) ?? .content
    }

    /// Default sizing: pass the proposal through to the wrapped child, or take
    /// the whole proposal when there is nothing inside.
    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        guard let child = node.singleChild else {
            return proposal.replacingUnspecifiedDimensions()
        }
        return child.sizeThatFits(proposal)
    }

    /// Default placement: hand the whole rect, and the proposal that made it,
    /// to the wrapped child.
    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        node.singleChild?.place(in: rect, proposal: proposal, context: context, into: &list)
    }
}

/// A node that draws nothing and lays nothing out — it exists to hold
/// children. `EmptyView`, `TupleView`, `Group`, `ForEach` and the builder's
/// conditional wrappers all become one.
struct GroupContent: NodeContent {
    var isTransparent: Bool { true }

    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        // Only reached when a group is the *root* or the sole child of a
        // modifier — otherwise the parent flattened it away. Behave like a
        // ZStack so multiple children still get a sensible box.
        let children = node.layoutChildren
        guard !children.isEmpty else { return .zero }
        var result = Size.zero
        for child in children {
            let size = child.sizeThatFits(proposal)
            result.width = max(result.width, size.width)
            result.height = max(result.height, size.height)
        }
        return result
    }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        for child in node.layoutChildren {
            child.place(in: rect, proposal: proposal, context: context, into: &list)
        }
    }
}

/// Reduce any view to a layout node, evaluating `body` until a builtin is
/// reached. This is the single seam between the declarative surface and
/// everything below it.
///
/// Before building, ask whether the subtree standing at this position from
/// the last pass will do. It will if the view is the same view — same type
/// and call site — with equivalent inputs, built under an equivalent
/// environment and stack axis, and nothing at or beneath it was dirtied by a
/// state write. Then the old node is grafted in and `body` is never run.
/// Every one of those conditions is necessary: the inputs are what `body`
/// reads, the environment and axis are what the builtins read, and a dirty
/// descendant is a view whose own reads changed under it.
@MainActor
func buildNode<V: View>(_ view: V, _ context: inout BuildContext) -> ViewNode {
    let path = context.path
    let identity = ViewIdentity(type: ObjectIdentifier(V.self), viewID: view._viewID)

    if let candidate = context.records.candidate(at: path) {
        let standing = candidate.entry
        let reason: String?
        if standing.identity != identity {
            reason = "identity"
        } else if standing.stackAxis != context.stackAxis {
            reason = "stack axis"
        } else if context.isDirty(under: path) {
            reason = "dirty"
        } else if !standing.environment._isEquivalent(to: context.environment) {
            reason = "environment"
        } else if !standing.isEquivalent(view) {
            reason = "inputs"
        } else {
            reason = nil
        }
        if reason == nil {
            context.records.reuse(candidate, at: path)
            PerfTrace.nodesReused += 1
            PerfTrace.trace("reuse \(path) \(V.self)")
            return standing.node
        }
        PerfTrace.trace("build \(path) \(V.self) — \(reason!)")

        // A fresh build replaces what stood here. Its reader registrations
        // are stale from this moment — the reads are about to happen again —
        // and its state is only carried over if this is still the same view.
        let replaced = context.records.replace(candidate)
        for storage in replaced.reads {
            storage.readers.removeValue(forKey: path)
        }
        if replaced.identity != identity {
            context.store.release(replaced.stateKeys)
            context.effects.forget(paths: [path])
        }
    } else {
        PerfTrace.trace("build \(path) \(V.self) — new")
    }

    // Wire up @State / @Environment before anything reads `body`.
    let stateKeys = context.bindDynamicProperties(of: view)

    // Publish this view's identity for the duration of its own evaluation, so
    // any `@State` read below is attributed to it — that attribution is what
    // lets a later write rebuild only this subtree.
    DependencyTracker.shared.push(path)
    defer { DependencyTracker.shared.pop() }

    let node: ViewNode
    if let builtin = view as? BuiltinView {
        node = builtin.makeNode(&context)
    } else {
        // The body's `@Observable` reads belong to this view. Only the body
        // itself is inside the scope — the child it returns is built after,
        // in a scope of its own — so a change rebuilds from here, not from
        // every ancestor that happened to be mid-build.
        let body = trackingObservation(at: path) { view.body }
        node = context.child(0) { sub in buildNode(body, &sub) }
    }

    // Remember how to rebuild exactly this view in exactly this position, and
    // how to recognise it next time. Both closures capture the concrete view
    // value: a scoped rebuild re-runs it without walking down from the root,
    // and a parent that re-runs compares its new child against it.
    context.records.record(
        RebuildRecords.Entry(
            identity: identity,
            environment: context.environment,
            stackAxis: context.stackAxis,
            rebuild: { sub in buildNode(view, &sub) },
            isEquivalent: { candidate in
                guard let candidate = candidate as? V else { return false }
                return view._isEquivalent(to: candidate)
            },
            node: node,
            stateKeys: stateKeys,
            reads: DependencyTracker.shared.takeReads(for: path)
        ),
        at: path
    )
    return node
}
