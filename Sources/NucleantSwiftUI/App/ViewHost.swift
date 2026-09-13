//
//  ViewHost.swift
//  NucleantSwiftUI
//
//  Owns one view tree: builds it, lays it out, hands the display list to the
//  renderer, and routes input into it. Everything here is platform-free — the
//  window feeds it sizes and events and asks it whether anything changed.
//

import Foundation
import Dispatch

@MainActor
public final class ViewHost {

    private let root: AnyView

    private let store = StateStore()
    private let effects = EffectQueue()

    /// The laid-out tree from the last build. Hit testing reads the frames it
    /// carries, so it outlives the build that produced it.
    private var rootNode: ViewNode?

    /// Values every view inherits — seeded by the window (display scale) and
    /// by whatever defaults the app sets.
    public var environment = EnvironmentValues()

    /// The window's content size in points.
    public private(set) var size: Size = .zero

    /// Where the display list goes. `nil` until the window's ThorVG node
    /// exists, which is after the first `on_size` on some platforms.
    public var renderer: ThorDisplayRenderer?

    /// GPU slots for `Shader` views, if the window has an engine yet.
    var shaderSlots: ShaderSlotRegistry?

    /// Everything needed to rebuild any single view in place.
    private let records = RebuildRecords()

    /// Forces the next `update()` to rebuild from the root.
    private var needsFullRebuild = true

    /// The gesture in flight between a press and its release. Held rather than
    /// re-hit-tested on release, so dragging off a button reaches the button
    /// that was actually pressed — and so a drag keeps reporting to its own
    /// view after the pointer has left it.
    private var activeGesture: HitResult?

    /// Where the in-flight gesture began, in the gesture view's own space.
    private var gestureStart: Point = .zero

    /// Whether the pointer has moved far enough for a drag to start reporting.
    private var dragPassedThreshold = false

    /// The last pointer position, in view coordinates — scroll events carry a
    /// delta but no location on macOS.
    private var pointerLocation: Point = .zero

    public init<Root: View>(root: Root) {
        self.root = AnyView(root)
    }

    // MARK: - Size

    public func setSize(_ size: Size) {
        guard size != self.size else { return }
        self.size = size
        // Every frame in the tree is derived from this, so layout has to run
        // from the root. The *views* are unchanged, though, so the rebuild
        // that starts there mostly reuses what is standing and re-places it.
        needsFullRebuild = true
    }

    // MARK: - The frame tick

    /// Rebuild and repaint if anything asked for it. Returns true when the
    /// canvas was redrawn, so the window knows to mark its render node dirty.
    @discardableResult
    public func update() -> Bool {
        let work = Invalidator.shared.consume()
        let full = needsFullRebuild || work.full
        guard full || !work.paths.isEmpty else { return false }
        guard size.width > 0, size.height > 0 else { return false }
        needsFullRebuild = false

        let started = PerfTrace.isEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        PerfTrace.reset()

        // What actually happened, not what was planned — a scoped attempt may
        // fall back, and a trace that reported the plan would hide exactly the
        // case worth seeing.
        let kind: String
        if full {
            rebuildAll(dirty: work.paths)
            kind = "full"
        } else if rebuildScoped(work.paths) {
            kind = "scoped(\(work.paths.count))"
        } else {
            // A dirty path with no record, or one whose node has since been
            // detached: the tree is not the shape the record described, so the
            // only safe answer is to build it again.
            rebuildAll(dirty: work.paths)
            kind = "fallback"
        }

        let built = PerfTrace.isEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        layoutAndRender()

        if PerfTrace.isEnabled {
            let now = DispatchTime.now().uptimeNanoseconds
            let elapsed = Double(now - started) / 1_000_000
            let building = Double(built - started) / 1_000_000
            PerfTrace.log("\(kind) \(String(format: "%.1f", elapsed))ms "
                + "(build \(String(format: "%.1f", building))ms) "
                + "built=\(PerfTrace.nodesBuilt) reused=\(PerfTrace.nodesReused) "
                + "measured=\(PerfTrace.sizeCalls) text=\(PerfTrace.textMeasures)")
        }

        // Deferred to here so an `onAppear` body can read the state it was
        // built alongside. One that writes state just marks the next frame
        // dirty — it does not re-enter this pass.
        for action in effects.endPass() {
            action()
        }
        return true
    }

    /// Force a full rebuild on the next `update()`.
    public func invalidate() {
        needsFullRebuild = true
        Invalidator.shared.invalidate()
    }

    // MARK: - Building

    /// Rebuild from the root. "Full" describes where the rebuild *starts*,
    /// not how much gets built: every child the root produces is still
    /// compared against what stood there, and kept if equivalent — which is
    /// why a resize, whose views are all unchanged, mostly reuses.
    private func rebuildAll(dirty: Set<[Int]>) {
        records.beginRebuild(under: [])
        var context = BuildContext(
            environment: environment,
            store: store,
            effects: effects,
            records: records,
            dirtyPaths: dirty
        )
        rootNode = buildNode(root, &context)
        releaseDeparted()
    }

    /// Rebuild just the subtrees whose state actually changed.
    ///
    /// Returns false when any dirty path can't be served this way, leaving the
    /// tree untouched so the caller can fall back to a full rebuild.
    private func rebuildScoped(_ paths: Set<[Int]>) -> Bool {
        guard rootNode != nil else { return false }

        // Outermost first, and skip any path already covered by an ancestor
        // being rebuilt — that rebuild subsumes it. Subsumed, not ignored:
        // the whole set travels down as `dirtyPaths`, so a view at one of
        // those paths can't be reused by the ancestor's rebuild either.
        let ordered = paths.sorted { $0.count < $1.count }
        var rebuilt: [[Int]] = []

        for path in ordered {
            if rebuilt.contains(where: { path.starts(with: $0) }) { continue }
            guard let record = records.entry(for: path) else { return false }
            let old = record.node
            // The root has no parent to splice into; treat it as a full rebuild.
            guard let parent = old.parent else { return false }

            records.beginRebuild(under: path)

            // The environment is the one captured when this view was first
            // built: nothing above it re-ran, so nothing above it changed.
            var context = BuildContext(
                environment: record.environment,
                store: store,
                effects: effects,
                records: records,
                dirtyPaths: paths
            )
            context.path = path
            context.stackAxis = record.stackAxis
            let replacement = record.rebuild(&context)
            releaseDeparted()

            parent.replaceChild(at: old.indexInParent, with: replacement)
            // Every ancestor cached a size computed from the subtree just
            // replaced.
            parent.invalidateMeasurementsUpwards()
            rebuilt.append(path)
        }
        return true
    }

    /// Let go of everything held by views that a rebuild did not put back:
    /// their `@State`, their `onAppear` marks, and the reader registrations
    /// that would otherwise keep dirtying paths no longer in the tree.
    private func releaseDeparted() {
        let departed = records.endRebuild()
        guard !departed.isEmpty else { return }
        for (path, entry) in departed {
            for storage in entry.reads {
                storage.readers.removeValue(forKey: path)
            }
            store.release(entry.stateKeys)
        }
        effects.forget(paths: Set(departed.map { $0.0 }))
    }

    private func layoutAndRender() {
        guard let node = rootNode else { return }

        // Shader views claim their slots during `place`; anything not claimed
        // by the end of the pass has left the tree.
        shaderSlots?.beginPass()
        ShaderHost.current = shaderSlots
        defer {
            ShaderHost.current = nil
            shaderSlots?.endPass()
        }

        var list = DisplayList()
        node.place(
            in: Rect(origin: .zero, size: size),
            proposal: ProposedSize(size),
            context: DrawContext(),
            into: &list
        )
        if LayoutTrace.isEnabled {
            LayoutTrace.dump(list)
        }
        renderer?.render(list)
    }

    // MARK: - Input

    public func pointerDown(at point: Point) {
        pointerLocation = point
        guard let hit = rootNode?.hitTest(point, matching: { $0.handlesPointer }) else {
            InputTrace.log("down \(point) — no target")
            activeGesture = nil
            return
        }
        InputTrace.log("down \(point) — hit \(hit.frame)")
        activeGesture = hit
        gestureStart = hit.localPoint
        dragPassedThreshold = hit.target.minimumDragDistance <= 0
        hit.target.onPress?(hit.localPoint)
        // A zero-threshold drag reports on press as well, so tapping a fader
        // jumps it to where you touched instead of waiting for movement.
        if dragPassedThreshold {
            reportDrag(gesture: hit, at: hit.localPoint, ended: false)
        }
    }

    public func pointerUp(at point: Point) {
        pointerLocation = point
        guard let gesture = activeGesture else {
            InputTrace.log("up \(point) — no gesture in flight")
            return
        }
        InputTrace.log("up \(point) — inside \(gesture.contains(point))")
        activeGesture = nil
        let inside = gesture.contains(point)
        let local = gesture.localPoint(for: point) ?? gesture.localPoint
        if dragPassedThreshold {
            reportDrag(gesture: gesture, at: local, ended: true)
        }
        dragPassedThreshold = false
        gesture.target.onRelease?(local, inside)
        if inside {
            gesture.target.onTap?(local)
        }
    }

    public func pointerMoved(to point: Point) {
        pointerLocation = point
        // Movement only means something to the gesture that is already in
        // flight: a drag must keep reporting to the view it started on, even
        // once the pointer has left that view's bounds.
        guard let gesture = activeGesture,
              let local = gesture.localPoint(for: point)
        else { return }

        if !dragPassedThreshold {
            let dx = local.x - gestureStart.x
            let dy = local.y - gestureStart.y
            let threshold = gesture.target.minimumDragDistance
            guard (dx * dx + dy * dy).squareRoot() >= threshold else { return }
            dragPassedThreshold = true
        }
        reportDrag(gesture: gesture, at: local, ended: false)
    }

    private func reportDrag(gesture: HitResult, at local: Point, ended: Bool) {
        let action = ended ? gesture.target.onDragEnded : gesture.target.onDragChanged
        guard let action else { return }
        action(DragGesture.Value(
            startLocation: gestureStart,
            location: local,
            translation: Size(
                width: local.x - gestureStart.x,
                height: local.y - gestureStart.y
            ),
            // The view's own rect, origin-relative — a fader turns a position
            // into a fraction with it.
            bounds: Rect(origin: .zero, size: gesture.frame.size)
        ))
    }

    /// A scroll wheel / trackpad delta at the last known pointer position.
    public func scroll(dx: Double, dy: Double) {
        guard let hit = rootNode?.hitTest(pointerLocation, matching: { $0.handlesScroll }) else {
            InputTrace.log("scroll (\(dx), \(dy)) at \(pointerLocation) — no target")
            return
        }
        InputTrace.log("scroll (\(dx), \(dy)) at \(pointerLocation)")
        hit.target.onScroll?(Point(x: dx, y: dy))
    }
}


/// Opt-in dump of the placed display list, on when
/// `NUCLEANT_SWIFTUI_TRACE_LAYOUT` is set. The fastest way to tell a layout bug
/// from a rendering one: these are the exact rects handed to the renderer.
enum LayoutTrace {
    nonisolated(unsafe) static let isEnabled = ProcessInfo.processInfo.environment["NUCLEANT_SWIFTUI_TRACE_LAYOUT"] != nil

    static func dump(_ list: DisplayList) {
        for (index, command) in list.commands.enumerated() {
            switch command {
            case .shape(let draw):
                fputs(String(
                    format: "[layout] %3d shape   x=%7.2f y=%7.2f w=%7.2f h=%7.2f\n",
                    index, draw.bounds.minX, draw.bounds.minY, draw.bounds.width, draw.bounds.height
                ), stderr)
            case .text(let draw):
                fputs(String(
                    format: "[layout] %3d text    x=%7.2f y=%7.2f w=%7.2f h=%7.2f  %@\n",
                    index, draw.frame.minX, draw.frame.minY, draw.frame.width, draw.frame.height,
                    draw.string
                ), stderr)
            }
        }
    }
}

/// Opt-in pointer tracing, on when `NUCLEANT_SWIFTUI_TRACE_INPUT` is set.
///
/// Writes to stderr because Swift's `print` is fully buffered off a terminal —
/// the reason a crashed or killed run appears to say nothing at all.
enum InputTrace {
    static let isEnabled = ProcessInfo.processInfo.environment["NUCLEANT_SWIFTUI_TRACE_INPUT"] != nil

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        fputs("[input] \(message())\n", stderr)
    }
}


/// Opt-in layout tracing, on when `NUCLEANT_SWIFTUI_TRACE_PERF` is set.
///
/// The counters are cache *misses*, not calls: `built` is how many nodes were
/// actually constructed, `measured` how many actually had to be sized, `text`
/// how many strings actually had to be measured. `reused` is the one gain
/// counter: subtrees grafted in from the previous pass. A rebuild whose miss
/// numbers climb with every pass means something is defeating a cache.
@MainActor
enum PerfTrace {
    static let isEnabled = ProcessInfo.processInfo.environment["NUCLEANT_SWIFTUI_TRACE_PERF"] != nil

    /// `NUCLEANT_SWIFTUI_TRACE_PERF=2` also names every view built or reused,
    /// with its path — the way to find out *why* a subtree is not being kept.
    static let isVerbose = ProcessInfo.processInfo.environment["NUCLEANT_SWIFTUI_TRACE_PERF"] == "2"

    static func trace(_ message: @autoclosure () -> String) {
        guard isVerbose else { return }
        fputs("[perf]   \(message())\n", stderr)
    }

    static var textMeasures = 0
    static var nodesBuilt = 0
    /// Subtrees kept from the previous pass — counted at their root, so one
    /// reused row is one, however many nodes it spared.
    static var nodesReused = 0
    static var sizeCalls = 0

    static func reset() {
        textMeasures = 0
        nodesBuilt = 0
        nodesReused = 0
        sizeCalls = 0
    }

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        fputs("[perf] \(message())\n", stderr)
    }
}
