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

    /// A press in flight, from its pointer going down to its release. Held
    /// rather than re-hit-tested on release, so dragging off a button reaches
    /// the button that was actually pressed — and so a drag keeps reporting
    /// to its own view after the pointer has left it.
    private struct PressedGesture {
        var hit: HitResult
        /// Where it began, in the gesture view's own space.
        var start: Point
        /// Whether the pointer has moved far enough for a drag to start reporting.
        var passedThreshold: Bool
    }

    /// The presses in flight, by pointer id — every finger on a touch host
    /// gets its own; a mouse is always pointer 0.
    private var gestures: [Int: PressedGesture] = [:]

    /// The pointer that scrolls, drags a `.draggable` or holds for a context
    /// menu: the first one down. Later fingers only press and drag-gesture.
    private var primaryPointer: Int?

    /// The last primary pointer position, in view coordinates — scroll events
    /// carry a delta but no location on macOS.
    private var pointerLocation: Point = .zero

    /// The drag in flight, once a press on a `.draggable` has moved far
    /// enough (or, with a finger that could scroll instead, been held).
    private var dragSession: DragSession?

    /// The innermost `.draggable` under the press in flight — found on the
    /// way down, separately from the pointer target, so a card is draggable
    /// by the button on it as well as by its margins.
    private var dragSourceHit: Hit<DragSource>?

    /// Bumped on every press and release, so a hold timer can tell whether
    /// the press it was started for is still the one in flight.
    private var pressSerial = 0

    /// How long a finger rests on a draggable inside a scroll view before
    /// it is dragging rather than about to scroll — UIKit's figure.
    private static let dragHoldDelay = 0.5

    /// The tree is unchanged but must be painted again — the drag preview
    /// moved. Placement only; nothing is rebuilt.
    private var needsRepaint = false

    /// The context menu on screen: where it was opened and what it holds.
    /// Built into the tree's overlay slot on the next rebuild.
    private var contextMenu: (anchor: Point, controller: ContextMenuController)?

    /// The innermost `.contextMenu` under the press in flight, for a touch
    /// host where a held press opens it.
    private var contextMenuHit: Hit<ContextMenuSource>?

    /// Whether a press held still opens the context menu under it — on for
    /// touch hosts, which have no right button.
    public var opensContextMenuOnLongPress = false

    /// The `.onHover` node the pointer is over, while no button is down.
    /// Compared by path, as a drop target is — the `true` it was told
    /// usually rebuilt it.
    private var hovered: Hit<HoverTarget>?

    /// The frame of the control most recently released — where a `Menu`
    /// pressed as a button opens its items.
    private var lastReleasedFrame: Rect?

    /// Whether a moving pointer scrolls the `ScrollView` under it. On for
    /// touch hosts, where a finger is the only way to scroll; off for a mouse,
    /// which scrolls with its wheel and drags only what asks for drags.
    public var scrollsOnDrag = false

    /// The innermost scrollable node under the touch that is in flight, and
    /// whether that touch has turned into a scroll.
    private var scrollTarget: HitResult?
    private var isScrolling = false
    private var touchStart: Point = .zero

    /// How far a finger travels before it is a scroll rather than a tap that
    /// wobbled. A drag-taking view (a fader) is never pre-empted by this; a
    /// press-only one (a button) is released without its tap once the finger
    /// is clearly scrolling, as UIKit does.
    private static let scrollSlop = 10.0

    public init<Root: View>(root: Root) {
        self.root = AnyView(root)
        environment.menuPresenter = MenuPresenter { [weak self] items in
            self?.presentMenu(items)
        }
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
        guard full || !work.paths.isEmpty || needsRepaint else { return false }
        guard size.width > 0, size.height > 0 else { return false }
        needsFullRebuild = false
        needsRepaint = false

        let started = PerfTrace.isEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        PerfTrace.reset()

        // What actually happened, not what was planned — a scoped attempt may
        // fall back, and a trace that reported the plan would hide exactly the
        // case worth seeing.
        let kind: String
        if full {
            rebuildAll(dirty: work.paths)
            kind = "full"
        } else if work.paths.isEmpty {
            kind = "repaint"
        } else if rebuildScoped(work.paths) {
            kind = "scoped(\(work.paths.count))"
        } else {
            // A dirty path with no record, or one whose node has since been
            // detached: the tree is not the shape the record described, so the
            // only safe answer is to build it again.
            rebuildAll(dirty: work.paths)
            kind = "fallback"
        }

        // A hovered node the rebuild removed (a menu that closed under the
        // pointer) is forgotten without being told: its view is gone.
        if let hovered, records.entry(for: hovered.value.path) == nil {
            self.hovered = nil
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
                + "measured=\(PerfTrace.sizeCalls) text=\(PerfTrace.textMeasures)"
                + (PerfTrace.layersDrawn > 0 ? " layers=\(PerfTrace.layersDrawn)" : ""))
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
        let overlay = contextMenu.map { menu in
            AnyView(ContextMenuOverlay(anchor: menu.anchor, controller: menu.controller))
        }
        rootNode = buildNode(_HostRoot(content: root, overlay: overlay), &context)
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
            context: DrawContext(colorScheme: environment.colorScheme),
            into: &list
        )
        // Over everything, and outside the tree: the preview is drawn, never
        // hit tested, so the destination under it is found through it.
        dragSession?.draw(into: &list, colorScheme: environment.colorScheme)
        if LayoutTrace.isEnabled {
            LayoutTrace.dump(list)
        }
        renderer?.render(list)
    }

    // MARK: - Input

    public func pointerDown(id: Int = 0, at point: Point) {
        if primaryPointer == nil {
            primaryPointer = id
            pointerLocation = point
            touchStart = point
            isScrolling = false
            pressSerial += 1
            scrollTarget = scrollsOnDrag
                ? rootNode?.hitTest(point, matching: { $0.handlesScroll })
                : nil
            dragSourceHit = rootNode?.hitTest(point) { $0.content.dragSource }
            contextMenuHit = opensContextMenuOnLongPress
                ? rootNode?.hitTest(point) { $0.content.contextMenuSource }
                : nil
            if contextMenuHit != nil || (dragSourceHit != nil && scrollTarget != nil) {
                // A finger resting on a view with a menu opens it; on a
                // draggable row of a list, moving scrolls and resting drags.
                // The timer is the rest.
                let serial = pressSerial
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.dragHoldDelay) { [weak self] in
                    MainActor.assumeIsolated { self?.holdElapsed(serial) }
                }
            }
        }
        guard let hit = rootNode?.hitTest(point, matching: { $0.handlesPointer }) else {
            InputTrace.log("down \(id) \(point) — no target")
            gestures[id] = nil
            return
        }
        InputTrace.log("down \(id) \(point) — hit \(hit.frame)")
        let gesture = PressedGesture(
            hit: hit,
            start: hit.localPoint,
            passedThreshold: hit.target.minimumDragDistance <= 0
        )
        gestures[id] = gesture
        hit.target.onPress?(hit.localPoint)
        // A zero-threshold drag reports on press as well, so tapping a fader
        // jumps it to where you touched instead of waiting for movement.
        if gesture.passedThreshold {
            reportDrag(id: id, gesture: gesture, at: hit.localPoint, ended: false)
        }
    }

    public func pointerUp(id: Int = 0, at point: Point) {
        if id == primaryPointer {
            releasePrimary(at: point)
            if let session = dragSession {
                dragSession = nil
                let taken = session.drop(at: point, in: rootNode)
                InputTrace.log("drop \(session.payload.itemName) at \(point) — \(taken ? "taken" : "not taken")")
                needsRepaint = true
                return
            }
        }
        guard let gesture = gestures.removeValue(forKey: id) else {
            InputTrace.log("up \(id) \(point) — no gesture in flight")
            return
        }
        let inside = gesture.hit.contains(point)
        InputTrace.log("up \(id) \(point) — inside \(inside)")
        let local = gesture.hit.localPoint(for: point) ?? gesture.hit.localPoint
        if gesture.passedThreshold {
            reportDrag(id: id, gesture: gesture, at: local, ended: true)
        }
        lastReleasedFrame = gesture.hit.frame
        gesture.hit.target.onRelease?(local, inside)
        if inside {
            gesture.hit.target.onTap?(local)
        }
    }

    /// The system took the pointer away (a system gesture, an incoming call):
    /// let its view go without a tap, and drop any drag preview on the floor.
    public func pointerCancelled(id: Int = 0, at point: Point) {
        if id == primaryPointer {
            releasePrimary(at: point)
            if let session = dragSession {
                dragSession = nil
                InputTrace.log("drag cancelled — \(session.payload.itemName)")
                needsRepaint = true
            }
        }
        guard let gesture = gestures.removeValue(forKey: id) else { return }
        InputTrace.log("cancel \(id) \(point)")
        let local = gesture.hit.localPoint(for: point) ?? gesture.hit.localPoint
        if gesture.passedThreshold {
            reportDrag(id: id, gesture: gesture, at: local, ended: true)
        }
        gesture.hit.target.onRelease?(local, false)
    }

    /// The primary pointer is gone: nothing scrolls, holds or drags until the
    /// next one goes down.
    private func releasePrimary(at point: Point) {
        primaryPointer = nil
        pointerLocation = point
        pressSerial += 1
        scrollTarget = nil
        isScrolling = false
        dragSourceHit = nil
        contextMenuHit = nil
    }

    public func pointerMoved(id: Int = 0, to point: Point) {
        // A hovering mouse has no press in flight but still moves the
        // location that a scroll wheel event lands on — and the node under
        // it. A finger never arrives here without a press, so never hovers.
        if primaryPointer == nil, gestures.isEmpty {
            pointerLocation = point
            updateHover(at: point)
            return
        }
        if primaryPointer == nil || primaryPointer == id {
            let previous = pointerLocation
            pointerLocation = point

            if let session = dragSession {
                session.move(to: point, in: rootNode)
                needsRepaint = true
                return
            }
            if isScrolling {
                scrollTarget?.target.onScroll?(Point(x: point.x - previous.x, y: point.y - previous.y))
                return
            }
            let takesDrags = gestures[id]?.hit.target.takesDrags ?? false
            if let scrollTarget, !takesDrags {
                let dx = point.x - touchStart.x
                let dy = point.y - touchStart.y
                if (dx * dx + dy * dy).squareRoot() >= Self.scrollSlop {
                    InputTrace.log("scroll begins at \(point)")
                    isScrolling = true
                    // The press was a scroll all along: let the view go
                    // without a tap.
                    releasePrimaryGesture()
                    scrollTarget.target.onScroll?(Point(x: dx, y: dy))
                    return
                }
            }

            // A press on a `.draggable` becomes a drag once it has travelled far
            // enough — unless the gesture in flight takes drags itself (a fader
            // on a draggable card keeps its own), or a finger could be scrolling
            // instead (then only a held press starts one — `holdElapsed`).
            if let source = dragSourceHit, scrollTarget == nil, !takesDrags {
                let dx = point.x - touchStart.x
                let dy = point.y - touchStart.y
                if (dx * dx + dy * dy).squareRoot() >= source.value.minimumDistance {
                    beginDrag(from: source)
                    return
                }
            }
        }

        // Movement only means something to the gesture that is already in
        // flight: a drag must keep reporting to the view it started on, even
        // once the pointer has left that view's bounds.
        guard var gesture = gestures[id],
              let local = gesture.hit.localPoint(for: point)
        else { return }

        if !gesture.passedThreshold {
            let dx = local.x - gesture.start.x
            let dy = local.y - gesture.start.y
            let threshold = gesture.hit.target.minimumDragDistance
            guard (dx * dx + dy * dy).squareRoot() >= threshold else { return }
            gesture.passedThreshold = true
            gestures[id] = gesture
        }
        reportDrag(id: id, gesture: gesture, at: local, ended: false)
    }

    /// The hold timer from `pointerDown` firing: still the same press, and
    /// it has neither scrolled nor let go, so it is a drag.
    private func holdElapsed(_ serial: Int) {
        guard serial == pressSerial, dragSession == nil, !isScrolling else { return }
        if let menu = contextMenuHit {
            releasePrimaryGesture()
            dragSourceHit = nil
            presentContextMenu(menu.value, at: touchStart)
        } else if let source = dragSourceHit {
            beginDrag(from: source)
        }
    }

    /// Let the view under the primary pointer go without a tap — the press
    /// turned out to be something else.
    private func releasePrimaryGesture() {
        guard let id = primaryPointer, let gesture = gestures.removeValue(forKey: id) else { return }
        gesture.hit.target.onRelease?(gesture.hit.localPoint(for: pointerLocation) ?? gesture.hit.localPoint, false)
    }

    private func beginDrag(from source: Hit<DragSource>) {
        // The press was a drag all along.
        releasePrimaryGesture()
        dragSourceHit = nil
        contextMenuHit = nil
        scrollTarget = nil
        // Anchored at the press, not at the point the threshold was crossed,
        // so the preview stays under the pointer where it was picked up.
        let session = DragSession(source: source, origin: touchStart)
        dragSession = session
        session.move(to: pointerLocation, in: rootNode)
        InputTrace.log("drag begins — \(session.payload.itemName) as \(session.payload.contentTypes)")
        needsRepaint = true
    }

    private func reportDrag(id: Int, gesture: PressedGesture, at local: Point, ended: Bool) {
        let target = gesture.hit.target
        let action = ended ? target.onDragEnded : target.onDragChanged
        guard let action else { return }
        action(DragGesture.Value(
            id: id,
            startLocation: gesture.start,
            location: local,
            translation: Size(
                width: local.x - gesture.start.x,
                height: local.y - gesture.start.y
            ),
            // The view's own rect, origin-relative — a fader turns a position
            // into a fraction with it.
            bounds: Rect(origin: .zero, size: gesture.hit.frame.size)
        ))
    }

    /// Tell the `.onHover` node under `point` it is hovered, and the one
    /// that was, that it no longer is. Same path, same node — the object
    /// is refreshed so the closure called is the current one.
    private func updateHover(at point: Point) {
        let found = rootNode?.hitTest(point) { $0.content.hoverTarget }
        guard found?.value.path != hovered?.value.path else {
            hovered = found
            return
        }
        hovered?.value.action(false)
        hovered = found
        found?.value.action(true)
    }

    // MARK: - Context menus

    /// A right click: open the menu of the innermost `.contextMenu` under
    /// `point`, closing any that is open.
    public func secondaryClick(at point: Point) {
        pointerLocation = point
        if contextMenu != nil {
            dismissContextMenu()
        }
        guard let hit = rootNode?.hitTest(point, select: { $0.content.contextMenuSource }) else {
            InputTrace.log("right click \(point) — no menu")
            return
        }
        presentContextMenu(hit.value, at: point)
    }

    private func presentContextMenu(_ source: ContextMenuSource, at anchor: Point) {
        presentMenu(source.items, at: anchor)
    }

    /// A `Menu` pressed as a button: its items open under the control that
    /// was just released, or at the pointer if no control was.
    private func presentMenu(_ items: AnyView) {
        let anchor = lastReleasedFrame.map { Point(x: $0.minX, y: $0.maxY + 2) } ?? pointerLocation
        if contextMenu != nil {
            dismissContextMenu()
        }
        presentMenu(items, at: anchor)
    }

    private func presentMenu(_ items: AnyView, at anchor: Point) {
        InputTrace.log("menu at \(anchor)")
        let controller = ContextMenuController(items: items) { [weak self] in
            self?.dismissContextMenu()
        }
        contextMenu = (anchor, controller)
        needsFullRebuild = true
    }

    private func dismissContextMenu() {
        guard contextMenu != nil else { return }
        InputTrace.log("context menu closed")
        contextMenu = nil
        needsFullRebuild = true
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
            case .image(let draw):
                fputs(String(
                    format: "[layout] %3d image   x=%7.2f y=%7.2f w=%7.2f h=%7.2f  %dx%d\n",
                    index, draw.frame.minX, draw.frame.minY, draw.frame.width, draw.frame.height,
                    draw.image.width, draw.image.height
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
/// how many strings actually had to be measured, `layers` how many `.shader`
/// canvases had to be redrawn. `reused` is the one gain counter: subtrees
/// grafted in from the previous pass. A rebuild whose miss numbers climb with
/// every pass means something is defeating a cache.
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
    /// `.shader` layers whose canvas was drawn again this pass — because the
    /// view under them drew something different, or moved.
    static var layersDrawn = 0

    static func reset() {
        textMeasures = 0
        nodesBuilt = 0
        nodesReused = 0
        sizeCalls = 0
        layersDrawn = 0
    }

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        fputs("[perf] \(message())\n", stderr)
    }

    static func millis(since start: UInt64) -> String {
        millis(from: start, to: DispatchTime.now().uptimeNanoseconds)
    }

    static func millis(from start: UInt64, to end: UInt64) -> String {
        String(format: "%.1fms", Double(end - start) / 1_000_000)
    }
}
