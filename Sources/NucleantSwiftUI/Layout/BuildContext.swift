//
//  BuildContext.swift
//  NucleantSwiftUI
//
//  The state carried *down* a build pass. A value type: `child(_:_:)` hands a
//  copy to a subtree, so an environment change made inside it can't leak back
//  out to a sibling. The state store is the one shared thing, and it is a
//  class for exactly that reason.
//

@MainActor
public struct BuildContext {

    /// The structural path to the view being built — one index per level.
    /// `@State` identity is derived from it.
    var path: [Int] = []

    /// The identity of the view whose `makeNode` is running — type and
    /// stamped call site — so a builtin that owns a render node can key it
    /// by the same identity the builder keys reuse by, not by path alone.
    /// Set by `buildNode` just before it asks the view for its node.
    var viewIdentity = ViewIdentity(type: ObjectIdentifier(Never.self), viewID: .unknown)

    var environment: EnvironmentValues

    /// The axis of the innermost enclosing stack, if any. `Spacer` and
    /// `Divider` are the two views whose whole shape depends on it, and they
    /// are built before the stack ever lays out — so it travels down here
    /// rather than being inferred later.
    var stackAxis: Axis?

    let store: StateStore

    /// `onAppear` actions collected during this pass, run once the tree is
    /// built. Reference-boxed so a copied context still appends to one list.
    let effects: EffectQueue

    /// Where each view's "how to rebuild me here" entry is filed.
    let records: RebuildRecords

    /// Every path some state write dirtied this frame — owners and readers.
    /// A standing subtree is only reused if none of these fall inside it.
    let dirtyPaths: PathTrie<Void>

    init(
        environment: EnvironmentValues,
        store: StateStore,
        effects: EffectQueue,
        records: RebuildRecords,
        dirtyPaths: Set<[Int]> = []
    ) {
        self.environment = environment
        self.store = store
        self.effects = effects
        self.records = records
        let trie = PathTrie<Void>()
        for path in dirtyPaths { trie.set((), at: path) }
        self.dirtyPaths = trie
    }

    /// Build a subtree at child slot `index`.
    func child<R>(_ index: Int, _ body: (inout BuildContext) -> R) -> R {
        var sub = self
        sub.path.append(index)
        return body(&sub)
    }

    /// Whether a state write dirtied exactly `path` this frame — the view
    /// there is where the change originated.
    func isDirty(at path: [Int]) -> Bool {
        dirtyPaths.value(at: path) != nil
    }

    /// Whether anything at or below `path` was dirtied this frame.
    func isDirty(under path: [Int]) -> Bool {
        // The trie only has nodes along dirty paths, so a node existing at
        // `path` means some dirty path runs through or ends there.
        dirtyPaths.node(at: path) != nil
    }

    /// Bind every `@State` / `@Environment` on `view` before its `body` runs.
    /// Returns the keys bound, so the view's record can release them when the
    /// view goes away. The view does the walking — statically if `@View`
    /// generated it, by reflection otherwise.
    func bindDynamicProperties<V: View>(of view: V) -> [StateKey] {
        let binder = DynamicPropertyBinder(
            store: store,
            environment: environment,
            path: path,
            viewType: ObjectIdentifier(V.self),
            viewID: view._viewID
        )
        view._bindDynamicProperties(binder)
        return binder.keys.keys
    }
}

/// Deferred work a build pass produced — currently just `onAppear` bodies.
@MainActor
final class EffectQueue {
    /// Identities that have already run their `onAppear`, so it fires once per
    /// appearance rather than once per rebuild.
    private var appeared: Set<StateKey> = []
    private var pending: [() -> Void] = []

    func onAppear(_ key: StateKey, _ action: @escaping () -> Void) {
        guard !appeared.contains(key) else { return }
        appeared.insert(key)
        pending.append(action)
    }

    /// Hand back the actions queued this pass.
    func endPass() -> [() -> Void] {
        defer { pending.removeAll(keepingCapacity: true) }
        return pending
    }

    /// Forget the views at `paths`, so one that comes back appears again.
    func forget(paths: Set<[Int]>) {
        guard !appeared.isEmpty else { return }
        appeared = appeared.filter { !paths.contains($0.path) }
    }
}


/// What "the same view" means to the builder: the type, and the call site
/// when the view carries one. Hashable so a render node can be keyed by it.
struct ViewIdentity: Hashable {
    let type: ObjectIdentifier
    let viewID: ViewID
}

/// A tree keyed by path components. Everything the builder files is keyed
/// by structural path, and everything it does with those files is by
/// *subtree* — take this one out, put that one back, drop whatever is left.
/// In a flat dictionary each of those is a scan of every key; here each is
/// one pointer, found by walking the path.
final class PathTrie<Value> {

    final class Node {
        var value: Value?
        var children: [Int: Node] = [:]

        /// Every value in this subtree, with its path relative to `base`.
        func collect(base: [Int], into result: inout [([Int], Value)]) {
            if let value { result.append((base, value)) }
            for (index, child) in children {
                child.collect(base: base + [index], into: &result)
            }
        }
    }

    let root = Node()

    func node(at path: [Int]) -> Node? {
        var node = root
        for index in path {
            guard let next = node.children[index] else { return nil }
            node = next
        }
        return node
    }

    /// The node at `path`, created along with any missing ancestors.
    func makeNode(at path: [Int]) -> Node {
        var node = root
        for index in path {
            if let next = node.children[index] {
                node = next
            } else {
                let next = Node()
                node.children[index] = next
                node = next
            }
        }
        return node
    }

    func value(at path: [Int]) -> Value? { node(at: path)?.value }

    func set(_ value: Value, at path: [Int]) {
        makeNode(at: path).value = value
    }

    /// Cut the subtree at `path` out and hand it back; `nil` if nothing was
    /// filed there or beneath.
    func detach(at path: [Int]) -> Node? {
        guard let last = path.last else {
            let detached = Node()
            detached.value = root.value
            detached.children = root.children
            root.value = nil
            root.children.removeAll(keepingCapacity: true)
            return detached
        }
        guard let parent = node(at: Array(path.dropLast())) else { return nil }
        return parent.children.removeValue(forKey: last)
    }

    /// Graft `subtree` in at `path`, replacing whatever stood there.
    func attach(_ subtree: Node, at path: [Int]) {
        guard let last = path.last else {
            root.value = subtree.value
            root.children = subtree.children
            return
        }
        makeNode(at: Array(path.dropLast())).children[last] = subtree
    }
}

/// One entry per view position: everything needed to rebuild that view in
/// place without its parent re-running, and everything needed to decide
/// that it need not be rebuilt at all.
///
/// Rebuilding from the state's owner *downwards* is what makes a scoped
/// rebuild correct rather than merely cheap: nothing above it re-evaluates,
/// so nothing above it can have changed what it was given. Reuse is the
/// complement, for when a parent *does* re-run: a child it produces that is
/// equivalent to the one already standing — same identity, same inputs, same
/// environment, no dirty state beneath — keeps its subtree, and its body is
/// never asked for.
@MainActor
final class RebuildRecords {

    struct Entry {
        let identity: ViewIdentity
        let environment: EnvironmentValues
        let stackAxis: Axis?
        let rebuild: @MainActor (inout BuildContext) -> ViewNode
        /// Is this freshly built view equivalent to the one recorded?
        let isEquivalent: @MainActor (Any) -> Bool
        /// The node this position produced — what a rebuild splices out and
        /// what a reuse hands back. A pass-through wrapper (`Optional`, an
        /// `if`) records its child's node as its own; `replaceNode` keeps
        /// that true when the child is rebuilt on its own.
        var node: ViewNode
        /// `@State` / `@Environment` slots this view bound.
        let stateKeys: [StateKey]
        /// State this view read while its body ran; each slot has this
        /// view's path among its readers.
        let reads: [any AnyStateStorage]
        /// Whether this view draws into a render node of its own — see
        /// `RenderBoundaryContent`. Sticky: carried over every rebuild of
        /// the same view at this position.
        var isBoundary = false
    }

    /// Entries for the tree as it stands.
    private let live = PathTrie<Entry>()

    /// Entries for the subtree currently being rebuilt, as it stood before,
    /// rooted at that subtree's path. Each is either reused (moved back to
    /// `live`), replaced (a fresh build at the same path), or left over at
    /// the end — a view that vanished.
    private var previous: PathTrie<Entry>.Node?
    private var previousBase: [Int] = []

    /// Start rebuilding the subtree at `path`: everything at or beneath it
    /// becomes a candidate for reuse.
    func beginRebuild(under path: [Int]) {
        previous = live.detach(at: path)
        previousBase = path
    }

    private func previousNode(at path: [Int]) -> PathTrie<Entry>.Node? {
        guard var node = previous, path.starts(with: previousBase) else { return nil }
        for index in path.dropFirst(previousBase.count) {
            guard let next = node.children[index] else { return nil }
            node = next
        }
        return node
    }

    /// What stood at `path` before this rebuild began, as a handle the
    /// builder can either keep or replace — one walk of the trie, not three.
    func candidate(at path: [Int]) -> Candidate? {
        guard let node = previousNode(at: path), node.value != nil else { return nil }
        return Candidate(node: node)
    }

    struct Candidate {
        fileprivate let node: PathTrie<Entry>.Node
        var entry: Entry { node.value! }
    }

    /// Keep the standing subtree at `path`: its entries go back to `live`
    /// untouched — readers, state, `onAppear` marks and all.
    func reuse(_ candidate: Candidate, at path: [Int]) {
        if path == previousBase {
            previous = nil
        } else if let parent = previousNode(at: Array(path.dropLast())), let last = path.last {
            parent.children.removeValue(forKey: last)
        }
        live.attach(candidate.node, at: path)
    }

    /// Take the old entry at exactly `path` out of the running, because a
    /// fresh build is replacing it. Its descendants stay candidates.
    func replace(_ candidate: Candidate) -> Entry {
        defer { candidate.node.value = nil }
        return candidate.entry
    }

    func record(_ entry: Entry, at path: [Int]) {
        live.set(entry, at: path)
    }

    func entry(for path: [Int]) -> Entry? { live.value(at: path) }

    /// A scoped rebuild put `replacement` where `old` stood at `path`. Every
    /// ancestor that recorded `old` as its own node — a wrapper whose
    /// `makeNode` hands back its child's node — now stands for the
    /// replacement; left pointing at `old`, its next reuse would graft the
    /// stale subtree back in.
    func replaceNode(_ old: ViewNode, with replacement: ViewNode, above path: [Int]) {
        var ancestor = path
        while !ancestor.isEmpty {
            ancestor.removeLast()
            guard let node = live.node(at: ancestor), var entry = node.value, entry.node === old else { return }
            entry.node = replacement
            node.value = entry
        }
    }

    func node(for path: [Int]) -> ViewNode? { live.value(at: path)?.node }

    /// Finish the rebuild: whatever is still `previous` belonged to views that
    /// are no longer in the tree. Returned with their paths so the caller can
    /// release what they held.
    func endRebuild() -> [([Int], Entry)] {
        defer { previous = nil }
        guard let previous else { return [] }
        var departed: [([Int], Entry)] = []
        previous.collect(base: previousBase, into: &departed)
        return departed
    }
}
