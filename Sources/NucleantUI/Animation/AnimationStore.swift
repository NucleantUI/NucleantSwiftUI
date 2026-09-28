//
//  AnimationStore.swift
//  NucleantUI
//
//  One view tree's animation clock and everything that animates against
//  it. The host stamps the time once per frame, so every value placed in
//  one pass is sampled at the same instant; anything still moving when the
//  pass ends asks for another frame, and the host lays out again — nothing
//  is rebuilt for it.
//
//  Four kinds of motion, all started by a pass that *built* something
//  (a commit pass) and only followed by the passes after:
//
//  * values — a modifier's own parameters (opacity, scale, rotation, a
//    fill color), filed here by path so a rebuild picks up where the last
//    build's value was;
//  * animatable data — an `Animatable` view's, shape's or modifier's own
//    `animatableData` (Animatable.swift): a shape redraws at each value, a
//    view is rebuilt at each, its path dirtied frame by frame until done;
//  * geometry — a node placed somewhere other than where it last stood
//    (`ViewNode.animate`, in NodeMotion.swift);
//  * transitions — a view inserted into, or removed from, an `if` or a
//    `ForEach`. A removed one stays drawn, out of layout, until it is gone.
//

import Foundation
import Dispatch

@MainActor
final class AnimationStore {

    /// The store of the host whose frame is in progress. Set for the
    /// whole of `ViewHost.update`, the way `ShaderHost.current` is for
    /// placement.
    static var current: AnimationStore?

    /// Seconds on a monotonic clock, fixed for the frame.
    private(set) var now: Double = 0

    /// Bumped every frame, so a ghost reached twice in one pass is drawn
    /// once and a scoped change can tell "this frame" from "some frame".
    private(set) var frame = 0

    /// Whether this frame built anything. Only such a frame starts
    /// animations; the frames after only follow them.
    private(set) var isCommitPass = false

    /// The transaction the writes served this frame were made in.
    private(set) var transaction = Transaction()

    /// Something placed this pass is still moving.
    private var movedThisPass = false

    /// Whether the next frame should lay out again even if nothing
    /// changed — decided as the previous one ended.
    private(set) var wantsFrame = false

    // MARK: - Frames

    func beginFrame() {
        now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        frame += 1
    }

    /// A pass that builds under `transaction`, or only lays out again.
    func beginPass(transaction: Transaction?, isCommit: Bool) {
        self.transaction = transaction ?? Transaction()
        isCommitPass = isCommit
        movedThisPass = false
        pending += self.transaction.completions
    }

    /// Called by whatever is still between two values as it is placed.
    func requestFrame() {
        movedThisPass = true
    }

    /// An animation began in this pass: whichever `withAnimation`
    /// completions ride on the pass wait for it.
    func noteStarted(_ run: AnimationRun) {
        for completion in transaction.completions {
            completion.runs.append(run)
        }
    }

    func endPass() {
        for completion in transaction.completions {
            completion.isScheduled = true
        }
        // A repeat that never ends never completes; waiting on it would
        // only keep the clock running.
        pending.removeAll { completion in
            completion.isScheduled && completion.runs.contains { $0.isEndless }
        }
        transaction = Transaction()
        isCommitPass = false
        wantsFrame = movedThisPass || !pending.isEmpty
    }

    // MARK: - Completions

    /// `withAnimation(completion:)` callbacks whose frame has run.
    private var pending: [AnimationCompletion] = []

    /// The callbacks now due — their animations over, or a body that
    /// changed nothing.
    func takeDueCompletions() -> [AnimationCompletion] {
        var due = AnimationCompletion.unclaimed
        AnimationCompletion.unclaimed.removeAll()
        pending.removeAll { completion in
            guard completion.isScheduled, completion.runs.allSatisfy({ $0.isDone(at: now) }) else { return false }
            due.append(completion)
            return true
        }
        return due
    }

    // MARK: - Values

    /// Which of a node's parameters a value is — one node, one modifier,
    /// so the kinds never collide at a path.
    enum Slot: Hashable {
        case opacity, rotation, scale, fill, stroke, textColor
    }

    private var values: [[Int]: [Slot: AnimatedVector]] = [:]

    /// The value for `slot` of the view at `path`, moved to `target` — at
    /// once, or over `animation` from wherever it is now.
    func value(at path: [Int], slot: Slot, target: [Double], animation: Animation?) -> AnimatedVector {
        if let existing = values[path]?[slot] {
            existing.update(to: target, animation: animation, in: self)
            return existing
        }
        let created = AnimatedVector(target)
        values[path, default: [:]][slot] = created
        return created
    }

    // MARK: - Implicit animation values

    /// The last value `.animation(_:value:)` saw at each path.
    private var observed: [[Int]: OpaqueValue] = [:]

    /// Whether `value` differs from the one last seen at `path`. The first
    /// sighting — or a value of another type, a different view now standing
    /// there — is not a change.
    func valueChanged<V: Equatable>(_ value: V, at path: [Int]) -> Bool {
        let previous = observed[path]?.value(as: V.self)
        guard previous != value else { return false }
        observed[path] = OpaqueValue(value)
        return previous != nil
    }

    // MARK: - Animatable data

    /// Each `Animatable` view's or shape's data on its way somewhere, by
    /// path — an `AnimatableDataState` of the type's own data.
    var animatableData: [[Int]: OpaqueReference] = [:]

    /// `Animatable` views still between values: rebuilt next frame, at the
    /// value that frame shows.
    private var animating: Set<[Int]> = []

    func rebuildNextFrame(_ path: [Int]) {
        animating.insert(path)
    }

    // MARK: - Removed views

    /// Views removed with a transition still running, by the path of the
    /// container they were removed from and the child slot they held.
    private var ghosts: [[Int]: [Int: ViewNode]] = [:]

    var hasGhosts: Bool { !ghosts.isEmpty }

    func addGhost(_ node: ViewNode, container: [Int], index: Int) {
        ghosts[container, default: [:]][index] = node
    }

    /// The ghosts still fading out of `container`, less any whose slot a
    /// view came back to — that one replaces it rather than overlapping it.
    func ghosts(in container: [Int], excluding rebuilt: Set<Int>) -> [ViewNode] {
        guard var standing = ghosts[container] else { return [] }
        for index in rebuilt { standing[index] = nil }
        ghosts[container] = standing.isEmpty ? nil : standing
        return standing.keys.sorted().compactMap { standing[$0] }
    }

    func removeGhost(container: [Int], index: Int) {
        ghosts[container]?[index] = nil
        if ghosts[container]?.isEmpty == true { ghosts[container] = nil }
    }

    // MARK: - Timelines

    /// When each `TimelineView` wants its content rebuilt next.
    private var timelines: [[Int]: Date] = [:]

    func schedule(timelineAt path: [Int], next: Date?) {
        timelines[path] = next
    }

    /// Dirty every view that asked to be rebuilt this frame: a timeline
    /// whose moment has come, an `Animatable` view still on its way.
    /// Outside any transaction — each redraws; nothing new starts moving.
    func invalidateScheduledRebuilds() {
        for path in animating {
            Invalidator.shared.invalidate(owner: path)
        }
        animating.removeAll(keepingCapacity: true)
        guard !timelines.isEmpty else { return }
        let date = Date()
        for (path, due) in timelines where due <= date {
            timelines[path] = nil
            Invalidator.shared.invalidate(owner: path)
        }
    }

    // MARK: - Departure

    /// Drop what the views at `paths` held here — they left the tree.
    func forget(paths: Set<[Int]>) {
        for path in paths {
            values[path] = nil
            observed[path] = nil
            animatableData[path] = nil
            animating.remove(path)
            timelines[path] = nil
            ghosts[path] = nil
        }
    }
}

/// One animatable parameter of a node: a vector of numbers heading for
/// `target`. Shared by every build of the node at its path, so a value a
/// rebuild changes again mid-flight turns from where it is.
@MainActor
final class AnimatedVector {
    private(set) var target: [Double]
    private var from: [Double] = []
    private var run: AnimationRun?

    init(_ target: [Double]) {
        self.target = target
    }

    func update(to newTarget: [Double], animation: Animation?, in store: AnimationStore) {
        guard newTarget != target else { return }
        if let animation, newTarget.count == target.count {
            from = sample(at: store.now).value
            let run = AnimationRun(animation, start: store.now)
            self.run = run
            store.noteStarted(run)
        } else {
            run = nil
        }
        target = newTarget
    }

    /// The value to draw in the pass under way.
    func current() -> [Double] {
        guard let store = AnimationStore.current else { return target }
        let sample = sample(at: store.now)
        if sample.isFinished {
            run = nil
        } else {
            store.requestFrame()
        }
        return sample.value
    }

    private func sample(at now: Double) -> (value: [Double], isFinished: Bool) {
        guard let run else { return (target, true) }
        let progress = run.progress(at: now)
        guard !progress.isFinished else { return (target, true) }
        let t = progress.fraction
        return (zip(from, target).map { a, b in a + (b - a) * t }, false)
    }
}

// MARK: - Vectors for the animatable kinds

extension Color {
    /// Both appearances' components, so a dynamic color animates as one.
    var animatableVector: [Double] {
        let dark = resolved(for: .dark)
        return [red, green, blue, alpha, dark.red, dark.green, dark.blue, dark.alpha]
    }

    init(animatableVector v: [Double]) {
        func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
        let light = Color(red: clamp(v[0]), green: clamp(v[1]), blue: clamp(v[2]), opacity: clamp(v[3]))
        let dark = Color(red: clamp(v[4]), green: clamp(v[5]), blue: clamp(v[6]), opacity: clamp(v[7]))
        self = light == dark ? light : .dynamic(light: light, dark: dark)
    }
}

extension ShapeStyle {
    /// Only a flat color animates; a gradient changes at once.
    var animatableVector: [Double] {
        if case .color(let color) = self { return color.animatableVector }
        return []
    }
}

extension BuildContext {
    /// The animated value for `slot` of the view being built, moving to
    /// `target` under this build's transaction.
    func animatedValue(_ slot: AnimationStore.Slot, _ target: [Double]) -> AnimatedVector {
        animations.value(at: path, slot: slot, target: target, animation: transaction.animation)
    }

    /// The same for a paint: only a flat color has anything to animate.
    func animatedStyle(_ slot: AnimationStore.Slot, _ style: ShapeStyle?) -> AnimatedVector? {
        guard let style else { return nil }
        return animatedValue(slot, style.animatableVector)
    }
}

extension AnimatedVector {
    /// `style` as drawn this pass: its color where one is animating.
    func current(of style: ShapeStyle) -> ShapeStyle {
        guard case .color = style else { return style }
        let vector = current()
        guard vector.count == 8 else { return style }
        return .color(Color(animatableVector: vector))
    }
}
