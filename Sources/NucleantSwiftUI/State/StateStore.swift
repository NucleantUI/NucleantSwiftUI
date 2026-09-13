//
//  StateStore.swift
//  NucleantSwiftUI
//
import Foundation

/// Type-erased handle on one `@State` slot, so the store can hold slots of
/// mixed value types in one dictionary — and so `Invalidator` can talk about a
/// slot's identity without knowing its value type.
@MainActor
protocol AnyStateStorage: AnyObject {
    /// Bumped on every write.
    var version: UInt32 { get }

    /// The view that declared this state — the subtree a write invalidates.
    var ownerPath: [Int] { get }

    /// Every view that read this slot while its `body` ran, by path, with
    /// the key paths it read through — `[]` for the whole value, `[\.[3],
    /// \.level]` for a read through `$tracks[3].level`. A write dirties each
    /// reader whose chain overlaps the written one, which is what stops a
    /// view whose *inputs* look unchanged from being reused while the state
    /// behind its binding moved — and what lets the other rows be reused
    /// when it is only row 3 that moved.
    var readers: [[Int]: [[AnyKeyPath]]] { get set }
}

/// One `@State` value, living across rebuilds.
@MainActor
final class StateStorage<Value>: AnyStateStorage {

    private(set) var value: Value
    private(set) var version: UInt32 = 0

    let ownerPath: [Int]

    var readers: [[Int]: [[AnyKeyPath]]] = [:]

    init(_ value: Value, ownerPath: [Int]) {
        self.value = value
        self.ownerPath = ownerPath
    }

    /// The single write path — `@State`'s setter and any `Binding` derived from
    /// it both come through here, so neither can bump the version without also
    /// invalidating, or invalidate without bumping.
    ///
    /// `chain` is the key path the write came through, `[]` for the whole
    /// value. A reader is affected when its chain and the written one are
    /// nested either way: a write to `[3].level` reaches a reader of the whole
    /// array and a reader of `[3].level`, not a reader of `[2].level`.
    ///
    /// The owner is always dirtied, reader or not: some reads happen outside
    /// any body — a `ScrollView` reads its offset during layout — and the
    /// owner's rebuild is the safe floor. The readers are what make reuse
    /// correct on top of that.
    func set(_ newValue: Value, via chain: [AnyKeyPath] = []) {
        value = newValue
        version &+= 1
        Invalidator.shared.invalidate(owner: ownerPath)
        for (reader, chains) in readers {
            guard chains.contains(where: { $0.starts(with: chain) || chain.starts(with: $0) }) else {
                continue
            }
            Invalidator.shared.invalidate(owner: reader)
        }
    }

    /// Read during a body evaluation: records the dependency on whatever view
    /// is currently being built. `chain` is the key path the read came
    /// through, `[]` for the whole value.
    func read(via chain: [AnyKeyPath] = []) -> Value {
        DependencyTracker.shared.recordRead(self, via: chain)
        return value
    }

    /// Read with no dependency recorded — for a write's read-modify-write,
    /// which must not make the *writer* a dependent.
    func peek() -> Value { value }
}

/// All the `@State` in one view tree, keyed by structural identity.
///
/// Slots are released by the view that declared them going away — the
/// builder knows exactly which keys each view bound (`RebuildRecords`), so
/// there is no end-of-pass sweep to get wrong for a scoped rebuild.
@MainActor
public final class StateStore {

    private var slots: [StateKey: any AnyStateStorage] = [:]

    init() {}

    /// The slot for `key`, created from `initialValue` the first time it is
    /// asked for. A type mismatch (the tree changed shape enough that a
    /// different view now sits at this position) discards the old slot rather
    /// than trapping.
    func slot<Value>(for key: StateKey, initialValue: () -> Value) -> StateStorage<Value> {
        if let existing = slots[key] as? StateStorage<Value> {
            return existing
        }
        let created = StateStorage(initialValue(), ownerPath: key.path)
        slots[key] = created
        return created
    }

    /// Drop the state a departed view declared.
    func release(_ keys: [StateKey]) {
        for key in keys {
            slots.removeValue(forKey: key)
        }
    }
}

/// Attributes each `@State` read to the view whose `body` is running.
///
/// A read has to be attributed to the view being built, and that view is not a
/// parameter of `@State`'s getter — so the builder publishes the identity it is
/// currently working on here, and the getter reports against it. The same shape
/// as `ViewGraphBuilder.currentBuildNode` in TouchBay's older framework.
///
/// Two things come out of a read: the slot learns it has a reader (so a write
/// can dirty that view), and the view's record learns which slots it read (so
/// the registration can be undone when the view is rebuilt or goes away).
@MainActor
final class DependencyTracker {
    static let shared = DependencyTracker()

    private init() {}

    /// The view identity currently having its `body` evaluated, innermost last.
    private var stack: [[Int]] = []

    /// Slots read by each view still being built, collected until the
    /// builder takes them.
    private var reads: [[Int]: [ObjectIdentifier: any AnyStateStorage]] = [:]

    func push(_ path: [Int]) {
        stack.append(path)
    }

    func pop() {
        stack.removeLast()
    }

    func recordRead(_ storage: any AnyStateStorage, via chain: [AnyKeyPath]) {
        guard let path = stack.last else { return }
        var chains = storage.readers[path] ?? []
        if !chains.contains(chain) {
            chains.append(chain)
            storage.readers[path] = chains
        }
        reads[path, default: [:]][ObjectIdentifier(storage)] = storage
    }

    /// The slots the view at `path` read, handed over once for its record.
    func takeReads(for path: [Int]) -> [any AnyStateStorage] {
        guard let taken = reads.removeValue(forKey: path) else { return [] }
        return Array(taken.values)
    }
}

/// The seam between "some state changed" and "the window redraws".
///
/// Writes name the view that owns the state, so a rebuild can start there
/// instead of at the root. `needsFullRebuild` is the fallback for the cases a
/// scoped rebuild can't serve — a resize, or a dirty path the builder has no
/// record for because the tree changed shape.
@MainActor
public final class Invalidator {
    public static let shared = Invalidator()

    private(set) var dirtyPaths: Set<[Int]> = []
    private(set) var needsFullRebuild = false

    private init() {}

    /// Invalidate the subtree rooted at the view that owns the written state.
    func invalidate(owner path: [Int]) {
        dirtyPaths.insert(path)
    }

    /// Invalidate everything — a resize, or an explicit host-level request.
    public func invalidate() {
        needsFullRebuild = true
    }

    var isDirty: Bool { needsFullRebuild || !dirtyPaths.isEmpty }

    /// Take the accumulated work and clear it.
    func consume() -> (full: Bool, paths: Set<[Int]>) {
        defer {
            needsFullRebuild = false
            dirtyPaths.removeAll(keepingCapacity: true)
        }
        return (needsFullRebuild, dirtyPaths)
    }
}
