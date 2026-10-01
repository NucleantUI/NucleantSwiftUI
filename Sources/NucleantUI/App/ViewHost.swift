//
//  ViewHost.swift
//  NucleantUI
//
//  Owns one view tree: builds it, lays it out, hands the display list to the
//  renderer, and routes input into it. Everything here is platform-free — the
//  window feeds it sizes and events and asks it whether anything changed.
//

import Foundation
import Dispatch
import NucleantWindow

@MainActor
public final class ViewHost {

    private let root: AnyView

    private let store = StateStore()
    private let effects = EffectQueue()
    private let animations = AnimationStore()

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
    public var renderer: ThorDisplayRenderer? {
        didSet { needsWindowRedraw = true }
    }

    /// GPU slots for `Shader` views — and the per-view render nodes — if the
    /// window has an engine yet.
    var shaderSlots: ShaderSlotRegistry?

    /// What the window canvas holds. A pass whose list comes out identical
    /// — a change that landed entirely inside a per-view node — leaves the
    /// canvas alone: no ThorVG scene rebuilt, nothing rasterized.
    private var windowContent: DisplayList?

    /// The canvas must be painted whatever the list says: it is new, or a
    /// new target after a resize, or the host was told to start over.
    private var needsWindowRedraw = true

    /// What the overlay slot (popovers, the context menu) drew this pass,
    /// composited as the topmost render node along with the drag preview.
    private let overlay = OverlayCapture()

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

    /// The popovers on screen (`.popover(isPresented:content:)`): the
    /// modifiers keep the list in step with their bindings, the overlay
    /// slot draws from it.
    private let popoverPresenter = PopoverPresenter()

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

    /// The `TextureView` the pointer is over, while no button is down — told
    /// every move, and told when the pointer leaves it.
    private var textureHovered: Hit<TextureInputTarget>?

    /// The view keys go to — a `TextField`, a `TextureView` — known by its
    /// path: the last one pressed. A press anywhere else takes the keys away.
    private var focusedPath: [Int]?

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

    /// The gestures attached with `.gesture` and its kin, and how they
    /// compete with each other and with the presses above.
    private let arena = GestureArena()

    /// Keys down now, by key code — a key down for one already here is a
    /// repeat.
    private var heldKeys: Set<UInt16> = []

    /// The write count of each focus state as the host last left it, so a
    /// write from a view (`focused = .email`) can be told from the host's.
    private var focusVersions: [ObjectIdentifier: UInt32] = [:]

    public init<Root: View>(root: Root) {
        self.root = AnyView(root)
        environment.menuPresenter = MenuPresenter { [weak self] items in
            self?.presentMenu(items)
        }
        environment.popoverPresenter = popoverPresenter
        arena.cancelPress = { [weak self] pointer, point in
            self?.cancelPress(pointer, at: point)
        }
        arena.didClaim = { [weak self] pointers in
            self?.gestureClaimed(pointers)
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
        needsWindowRedraw = true
    }

    // MARK: - The frame tick

    /// Rebuild and repaint if anything asked for it. Returns true when the
    /// window canvas was redrawn, so the window knows to mark its render
    /// node dirty — false when nothing changed, and also when what changed
    /// landed entirely in per-view render nodes, which mark themselves.
    @discardableResult
    public func update() -> Bool {
        // One instant for the whole frame: everything placed in it is
        // sampled at the same time.
        AnimationStore.current = animations
        defer { AnimationStore.current = nil }
        animations.beginFrame()
        animations.invalidateScheduledRebuilds()

        // `withAnimation` completions whose animations are over — run last,
        // however this frame goes, so one that writes state marks the next.
        let completions = animations.takeDueCompletions()
        defer {
            for completion in completions { completion.run() }
        }

        let work = Invalidator.shared.consume()
        let full = needsFullRebuild || work.full
        // Something still moving is laid out again even with nothing dirty.
        guard full || !work.paths.isEmpty || needsRepaint || animations.wantsFrame else { return false }
        guard size.width > 0, size.height > 0 else { return false }
        needsFullRebuild = false
        needsRepaint = false

        let builds = full || !work.paths.isEmpty
        animations.beginPass(transaction: builds ? work.transaction : nil, isCommit: builds)
        let transaction = work.transaction ?? Transaction()

        let started = PerfTrace.isEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        PerfTrace.reset()

        // What actually happened, not what was planned — a scoped attempt may
        // fall back, and a trace that reported the plan would hide exactly the
        // case worth seeing.
        let kind: String
        if full {
            rebuildAll(dirty: work.paths, transaction: transaction)
            kind = "full"
        } else if work.paths.isEmpty {
            kind = "repaint"
        } else if rebuildScoped(work.paths, transaction: transaction) {
            kind = "scoped(\(work.paths.count))"
        } else {
            // A dirty path with no record, or one whose node has since been
            // detached: the tree is not the shape the record described, so the
            // only safe answer is to build it again.
            rebuildAll(dirty: work.paths, transaction: transaction)
            kind = "fallback"
        }

        // A hovered node the rebuild removed (a menu that closed under the
        // pointer) is forgotten without being told: its view is gone.
        if let hovered, records.entry(for: hovered.value.path) == nil {
            self.hovered = nil
        }

        let built = PerfTrace.isEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        let windowRedrawn = layoutAndRender()
        animations.endPass()

        if PerfTrace.isEnabled {
            let now = DispatchTime.now().uptimeNanoseconds
            let elapsed = Double(now - started) / 1_000_000
            let building = Double(built - started) / 1_000_000
            PerfTrace.log("\(kind) \(String(format: "%.1f", elapsed))ms "
                + "(build \(String(format: "%.1f", building))ms) "
                + "built=\(PerfTrace.nodesBuilt) reused=\(PerfTrace.nodesReused) "
                + "measured=\(PerfTrace.sizeCalls) text=\(PerfTrace.textMeasures)"
                + (PerfTrace.layersDrawn > 0 ? " layers=\(PerfTrace.layersDrawn)" : "")
                + (PerfTrace.nodesDrawn > 0 ? " nodes=\(PerfTrace.nodesDrawn)" : "")
                + (windowRedrawn ? " window" : ""))
        }

        // Deferred to here so an `onAppear` body can read the state it was
        // built alongside. One that writes state just marks the next frame
        // dirty — it does not re-enter this pass.
        for action in effects.endPass() {
            action()
        }
        if builds, let rootNode {
            if !arena.isIdle {
                arena.refreshAttachments(from: rootNode)
            }
            applyFocusRequests()
        }
        // Only a pass that built can have changed a preference: every value
        // is set by a view, not by layout.
        if builds {
            for action in effects.preferenceObservers.changes() {
                action()
            }
        }
        return windowRedrawn
    }

    /// Force a full rebuild on the next `update()`, and a repaint of the
    /// window canvas with it.
    public func invalidate() {
        needsFullRebuild = true
        needsWindowRedraw = true
        Invalidator.shared.invalidate()
    }

    // MARK: - Building

    /// Rebuild from the root. "Full" describes where the rebuild *starts*,
    /// not how much gets built: every child the root produces is still
    /// compared against what stood there, and kept if equivalent — which is
    /// why a resize, whose views are all unchanged, mostly reuses.
    private func rebuildAll(dirty: Set<[Int]>, transaction: Transaction) {
        records.beginRebuild(under: [])
        var context = BuildContext(
            environment: environment,
            store: store,
            effects: effects,
            animations: animations,
            records: records,
            dirtyPaths: dirty
        )
        context.transaction = transaction
        let overlay = _HostOverlay(
            popovers: popoverPresenter,
            contextMenu: contextMenu.map { menu in
                ContextMenuOverlay(anchor: menu.anchor, controller: menu.controller)
            }
        )
        rootNode = buildNode(
            _HostRoot(content: root, overlay: AnyView(overlay), capture: self.overlay),
            &context
        )
        releaseDeparted()
    }

    /// Rebuild just the subtrees whose state actually changed.
    ///
    /// Returns false when any dirty path can't be served this way, leaving the
    /// tree untouched so the caller can fall back to a full rebuild.
    private func rebuildScoped(_ paths: Set<[Int]>, transaction: Transaction) -> Bool {
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
                animations: animations,
                records: records,
                dirtyPaths: paths
            )
            context.transaction = transaction
            context.path = path
            context.stackAxis = record.stackAxis
            // A view inside a lazy container rebuilds under the window it
            // was built under, not eagerly.
            context.lazyCursor = record.lazyKey.map {
                LazyBuildCursor(owner: $0.owner, window: $0.window, position: $0.start)
            }
            let replacement = record.rebuild(&context)
            releaseDeparted()

            parent.replaceChild(at: old.indexInParent, with: replacement)
            records.replaceNode(old, with: replacement, above: path)
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
        let paths = Set(departed.map { $0.0 })
        effects.forget(paths: paths)
        animations.forget(paths: paths)
    }

    /// Lay the tree out and paint it. Returns whether the window canvas was
    /// redrawn.
    private func layoutAndRender() -> Bool {
        guard let node = rootNode else { return false }

        // Shader views and drawing groups claim their slots and nodes during
        // `place`; anything not claimed by the end of the pass has left the
        // tree.
        shaderSlots?.beginPass(windowSize: size)
        ShaderHost.current = shaderSlots
        defer {
            ShaderHost.current = nil
            shaderSlots?.endPass()
        }

        let window = Rect(origin: .zero, size: size)
        var list = DisplayList()
        overlay.list = DisplayList()
        overlay.order = nil
        var context = DrawContext(colorScheme: environment.colorScheme)
        // What moved in the frame that built it moves the way the change
        // said; in the frames after, it only follows.
        if animations.isCommitPass {
            context.animation = animations.transaction.animation
        }
        node.place(
            in: window,
            proposal: ProposedSize(size),
            context: context,
            into: &list
        )
        // Over everything, and outside the tree: the preview is drawn, never
        // hit tested, so the destination under it is found through it.
        dragSession?.draw(into: &overlay.list, colorScheme: environment.colorScheme)
        if let shaderSlots {
            // The overlay slot and the preview are the last thing painted,
            // so they are a node of their own, over every other node; an
            // empty list keeps no node at all.
            shaderSlots.boundaries.useBoundary(
                key: Self.overlayKey,
                clip: nil,
                frame: overlay.frame ?? RenderBoundaries.Frame(primaryOrder: overlay.order ?? shaderSlots.renderNodes.nextPaintOrder()),
                content: overlay.list
            )
            // Whatever the window paints over a node placed before it
            // leaves the window canvas for a node of its own.
            shaderSlots.boundaries.endRootFrame(&list)
        } else {
            list.append(contentsOf: overlay.list)
        }
        if LayoutTrace.isEnabled {
            LayoutTrace.dump(list)
            if !overlay.list.isEmpty {
                nucleantLogError("[layout] overlay:\n")
                LayoutTrace.dump(overlay.list)
            }
        }
        guard needsWindowRedraw || windowContent != list else { return false }
        needsWindowRedraw = false
        windowContent = list
        renderer?.render(list)
        return true
    }

    /// The overlay node's identity: slot `[1]` of the root, whatever it holds.
    private static let overlayKey = RenderNodeKey(
        path: [1],
        identity: ViewIdentity(type: ObjectIdentifier(_HostOverlay.self), viewID: .unknown)
    )

    // MARK: - Input

    public func pointerDown(id: Int = 0, at point: Point, modifiers: EventModifiers = []) {
        if primaryPointer == nil {
            primaryPointer = id
            pointerLocation = point
            PointerPress.modifiers = modifiers
            updateFocus(at: point)
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
        // The frontmost pointer target, as always — and the gestures
        // attached around it, which compete for the press in the arena.
        let chain = rootNode?.pressChain(at: point) ?? PressChain()
        if !chain.gestures.isEmpty, id == primaryPointer, arena.timesHoldAhead(of: chain) {
            // A long press gesture is what a held press means here.
            contextMenuHit = nil
        }
        guard let hit = chain.press else {
            InputTrace.log("down \(id) \(point) — no target")
            gestures[id] = nil
            arena.pointerDown(id, at: point, chain: chain, pressReports: false)
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
        arena.pointerDown(
            id,
            at: point,
            chain: chain,
            pressReports: gesture.passedThreshold && hit.target.takesDrags
        )
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
        // A gesture this release completes goes before the press — a tap
        // gesture that wins lets the press go without its tap.
        arena.pointerUp(id, at: point)
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
        // At once — or, behind a tap gesture still counting, once that is
        // decided.
        // A target with nothing to do on release — a drag that never moved,
        // a press-only row — is no tap, and leaves the release to the
        // gestures around it.
        let target = gesture.hit.target
        let takesRelease = target.onRelease != nil || target.onTap != nil
        arena.pressReleased(id, inside: inside && takesRelease) { tapped in
            target.onRelease?(local, tapped)
            if tapped {
                target.onTap?(local)
            }
        }
    }

    /// The system took the pointer away (a system gesture, an incoming call):
    /// let its view go without a tap, and drop any drag preview on the floor.
    public func pointerCancelled(id: Int = 0, at point: Point) {
        arena.cancelPointer(id)
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
        if primaryPointer == nil, gestures.isEmpty, !arena.follows(pointer: id) {
            pointerLocation = point
            updateHover(at: point)
            updateTextureHover(at: point)
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
            let takesDrags = (gestures[id]?.hit.target.takesDrags ?? false) || arena.followsDrags(of: id)
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

        arena.pointerMoved(id, to: point)

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
            if gesture.hit.target.takesDrags {
                arena.pressReports(id)
                // The arena may have handed the press to a gesture before it.
                guard gestures[id] != nil else { return }
            }
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
        if let id = primaryPointer {
            arena.pressDropped(id)
            arena.cancelPointer(id)
        }
        guard let id = primaryPointer, let gesture = gestures.removeValue(forKey: id) else { return }
        gesture.hit.target.onRelease?(gesture.hit.localPoint(for: pointerLocation) ?? gesture.hit.localPoint, false)
    }

    /// A gesture won the press on `pointer`: its view lets go without a
    /// tap, as when the system takes a pointer away.
    private func cancelPress(_ pointer: Int, at point: Point) {
        guard let gesture = gestures.removeValue(forKey: pointer) else { return }
        InputTrace.log("press \(pointer) taken by a gesture")
        let local = gesture.hit.localPoint(for: point) ?? gesture.hit.localPoint
        if gesture.passedThreshold {
            reportDrag(id: pointer, gesture: gesture, at: local, ended: true)
        }
        gesture.hit.target.onRelease?(local, false)
    }

    /// A gesture that excludes others recognized on `pointers`: when one is
    /// the primary pointer, the press is no longer a scroll, a drag of a
    /// `.draggable` or a held context menu.
    private func gestureClaimed(_ pointers: Set<Int>) {
        guard let id = primaryPointer, pointers.contains(id) else { return }
        scrollTarget = nil
        dragSourceHit = nil
        contextMenuHit = nil
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

    /// Tell the `TextureView` under `point` where the pointer is, and the
    /// one it was over, if another, that it left.
    private func updateTextureHover(at point: Point) {
        let found = rootNode?.hitTest(point) { $0.content.textureInput }
        if let previous = textureHovered, previous.value.path != found?.value.path {
            previous.value.send(.pointerExited)
        }
        textureHovered = found
        if let found {
            found.value.send(.pointerMoved(found.localPoint))
        }
    }

    /// A press at `point`: the view under it that takes keys, if any, gets
    /// them; the one that had them is told it lost them.
    private func updateFocus(at point: Point) {
        let found = rootNode?.hitTest(point) { node in
            node.content.focusTarget.flatMap { $0.isEnabled ? $0 : nil }
        }?.value
        guard found?.path != focusedPath else { return }
        if let path = focusedPath {
            rootNode?.focusTarget(at: path)?.onFocusChange(false)
        }
        focusedPath = found?.path
        found?.onFocusChange(true)
        syncFocusBindings()
    }

    /// The focused view's current target — `nil`, and the focus dropped,
    /// once that view has left the tree.
    private func focusedTarget() -> FocusTarget? {
        guard let path = focusedPath else { return nil }
        guard let target = rootNode?.focusTarget(at: path) else {
            focusedPath = nil
            return nil
        }
        return target
    }

    // MARK: - Keys

    /// A key pressed, for the view that has the keys — or, for Tab, a move
    /// to the next tab stop when the focused view doesn't keep Tab itself.
    public func keyDown(keyCode: UInt16, characters: String?, modifiers: EventModifiers = []) {
        let isRepeat = heldKeys.contains(keyCode)
        // A key pressed with ⌘ never reports its release on macOS, so it is
        // not counted as held — its next press is a press, not a repeat.
        if modifiers.contains(.command) {
            heldKeys.remove(keyCode)
        } else {
            heldKeys.insert(keyCode)
        }
        let press = KeyPress(phase: isRepeat ? .repeat : .down, keyCode: keyCode, characters: characters, modifiers: modifiers)
        if offerKeyPress(press) { return }
        let focused = focusedTarget()
        if keyCode == 0x30, !modifiers.contains(.command), !modifiers.contains(.option) {
            // Nothing focused, a tab stop that passes Tab on, or ⌃Tab out of
            // one that keeps it. A view that is no tab stop (a `TextureView`)
            // gets its Tab.
            let moves = focused.map { $0.isTabStop && (!$0.insertsTab || modifiers.contains(.control)) } ?? true
            if moves, moveFocus(backward: modifiers.contains(.shift)) { return }
        }
        focused?.onKeyDown(KeyEvent(keyCode: keyCode, characters: characters, modifiers: modifiers))
    }

    /// Give the keys to the tab stop after the focused one (before it, going
    /// backward), wrapping around; whether there was one to go to.
    private func moveFocus(backward: Bool) -> Bool {
        var stops: [FocusTarget] = []
        rootNode?.tabStops(into: &stops)
        guard !stops.isEmpty else { return false }
        let current = focusedPath.flatMap { path in stops.firstIndex { $0.path == path } }
        let next: Int
        if let current {
            next = (current + (backward ? stops.count - 1 : 1)) % stops.count
        } else {
            next = backward ? stops.count - 1 : 0
        }
        let target = stops[next]
        guard target.path != focusedPath else { return true }
        if let path = focusedPath {
            rootNode?.focusTarget(at: path)?.onFocusChange(false)
        }
        focusedPath = target.path
        target.onFocusChange(true)
        syncFocusBindings()
        return true
    }

    public func keyUp(keyCode: UInt16, characters: String?, modifiers: EventModifiers = []) {
        heldKeys.remove(keyCode)
        if offerKeyPress(KeyPress(phase: .up, keyCode: keyCode, characters: characters, modifiers: modifiers)) { return }
        focusedTarget()?.onKeyUp(KeyEvent(keyCode: keyCode, characters: characters, modifiers: modifiers))
    }

    /// Offer `press` to the `.onKeyPress` actions around the view that has
    /// the keys, innermost first; whether one used it.
    private func offerKeyPress(_ press: KeyPress) -> Bool {
        guard focusedTarget() != nil, let path = focusedPath, let node = rootNode?.focusNode(at: path) else {
            return false
        }
        for scope in node.focusScope {
            if let handler = scope.content.keyPressHandler, handler.handle(press) { return true }
        }
        return false
    }

    // MARK: - Focus state

    /// Give the keys to `target` — or take them away, for `nil` — and
    /// bring the focus states up to date.
    private func setFocus(_ target: FocusTarget?) {
        guard target?.path != focusedPath else { return }
        if let path = focusedPath {
            rootNode?.focusTarget(at: path)?.onFocusChange(false)
        }
        focusedPath = target?.path
        target?.onFocusChange(true)
        syncFocusBindings()
    }

    /// Write every `@FocusState` marked in the tree to match where the keys
    /// are: the mark around the focused view, for its state; empty, for a
    /// state none of whose marks has them.
    private func syncFocusBindings() {
        guard let root = rootNode else { return }
        var marks: [(record: FocusBindingRecord, node: ViewNode)] = []
        root.focusBindings(into: &marks)
        guard !marks.isEmpty else { return }

        var holding: [ObjectIdentifier: FocusBindingRecord] = [:]
        if let path = focusedPath, let node = root.focusNode(at: path) {
            for scope in node.focusScope {
                if let record = scope.content.focusBinding, holding[record.group] == nil {
                    holding[record.group] = record
                }
            }
        }
        var done: Set<ObjectIdentifier> = []
        for mark in marks where done.insert(mark.record.group).inserted {
            let group = mark.record.group
            if let record = holding[group] {
                if !record.matches() { record.take() }
            } else if marks.contains(where: { $0.record.group == group && $0.record.matches() }) {
                mark.record.clear()
            }
            focusVersions[group] = mark.record.version()
        }
    }

    /// After a build: a focus state a view set since the host last looked
    /// moves the keys to the view it names — or, set empty, takes them from
    /// the view that had them. A focused view that has left the tree gives
    /// the keys up.
    private func applyFocusRequests() {
        guard let root = rootNode else { return }
        if let path = focusedPath, root.focusTarget(at: path) == nil {
            focusedPath = nil
            syncFocusBindings()
        }
        var marks: [(record: FocusBindingRecord, node: ViewNode)] = []
        root.focusBindings(into: &marks)
        guard !marks.isEmpty else {
            focusVersions.removeAll()
            return
        }

        let focusedNode = focusedPath.flatMap { root.focusNode(at: $0) }
        let focusedScope = focusedNode?.focusScope ?? []
        var done: Set<ObjectIdentifier> = []
        for mark in marks where done.insert(mark.record.group).inserted {
            let group = mark.record.group
            let version = mark.record.version()
            let seen = focusVersions[group]
            guard seen != version else { continue }
            focusVersions[group] = version
            let ofGroup = marks.filter { $0.record.group == group }
            if let named = ofGroup.first(where: { $0.record.matches() }) {
                // Already there — the keys are inside the named view.
                guard !focusedScope.contains(where: { $0 === named.node }) else { continue }
                if let target = named.node.firstFocusTarget() {
                    setFocus(target)
                }
            } else if seen != nil, ofGroup.contains(where: { mark in focusedScope.contains { $0 === mark.node } }) {
                setFocus(nil)
            }
        }
        let standing = Set(marks.map(\.record.group))
        focusVersions = focusVersions.filter { standing.contains($0.key) }
    }

    // MARK: - Editing commands

    /// Whether the view that has the keys takes `command` — what decides if
    /// the Edit menu's item for it is enabled.
    func canPerform(_ command: EditCommand) -> Bool {
        focusedTarget()?.editCommands.contains(command) ?? false
    }

    /// `command` from the Edit menu, for the view that has the keys.
    func perform(_ command: EditCommand) {
        guard let target = focusedTarget(), target.editCommands.contains(command) else { return }
        target.onEditCommand(command)
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

    // MARK: - Trackpad gestures

    /// A trackpad pinch at `point`: `delta` is the change in scale since
    /// the last event, as AppKit reports it. Drives `MagnifyGesture`.
    public func magnify(phase: TrackpadGesturePhase, delta: Double, at point: Point) {
        pointerLocation = point
        arena.trackpad(.magnify, phase: phase, delta: delta, at: point) {
            rootNode?.pressChain(at: point) ?? PressChain()
        }
    }

    /// A trackpad rotation at `point`: `delta` is degrees counterclockwise
    /// since the last event, as AppKit reports it. Drives `RotateGesture`.
    public func rotate(phase: TrackpadGesturePhase, delta: Double, at point: Point) {
        pointerLocation = point
        arena.trackpad(.rotate, phase: phase, delta: delta, at: point) {
            rootNode?.pressChain(at: point) ?? PressChain()
        }
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
                nucleantLogError(String(
                    format: "[layout] %3d shape   x=%7.2f y=%7.2f w=%7.2f h=%7.2f\n",
                    index, draw.bounds.minX, draw.bounds.minY, draw.bounds.width, draw.bounds.height
                ))
            case .text(let draw):
                nucleantLogError(String(
                    format: "[layout] %3d text    x=%7.2f y=%7.2f w=%7.2f h=%7.2f  %@\n",
                    index, draw.frame.minX, draw.frame.minY, draw.frame.width, draw.frame.height,
                    draw.string
                ))
            case .image(let draw):
                nucleantLogError(String(
                    format: "[layout] %3d image   x=%7.2f y=%7.2f w=%7.2f h=%7.2f  %dx%d\n",
                    index, draw.frame.minX, draw.frame.minY, draw.frame.width, draw.frame.height,
                    draw.image.width, draw.image.height
                ))
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
        nucleantLogError("[input] \(message())\n")
    }
}


/// Opt-in layout tracing, on when `NUCLEANT_SWIFTUI_TRACE_PERF` is set.
///
/// The counters are cache *misses*, not calls: `built` is how many nodes were
/// actually constructed, `measured` how many actually had to be sized, `text`
/// how many strings actually had to be measured, `layers` how many `.shader`
/// canvases had to be redrawn, `nodes` how many per-view render nodes, and
/// `window` whether the window canvas itself was. `reused` is the one gain
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
        nucleantLogError("[perf]   \(message())\n")
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
    /// Per-view render nodes — automatic ones, `.drawingGroup()`,
    /// `ThorCanvas`, the overlay — painted again this pass, because what
    /// they hold changed.
    static var nodesDrawn = 0

    static func reset() {
        textMeasures = 0
        nodesBuilt = 0
        nodesReused = 0
        sizeCalls = 0
        layersDrawn = 0
        nodesDrawn = 0
    }

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        nucleantLogError("[perf] \(message())\n")
    }

    static func millis(since start: UInt64) -> String {
        millis(from: start, to: DispatchTime.now().uptimeNanoseconds)
    }

    static func millis(from start: UInt64, to end: UInt64) -> String {
        String(format: "%.1fms", Double(end - start) / 1_000_000)
    }
}
