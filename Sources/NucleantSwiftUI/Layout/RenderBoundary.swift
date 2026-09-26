//
//  RenderBoundary.swift
//  NucleantSwiftUI
//
//  The automatic render node: a user view whose changes should repaint
//  itself and nothing else.
//
//  A view gets a node of its own once a change can *originate* at it —
//  once it has read `@State` (known when it is built) or been the origin of
//  a rebuild, which is how an `@Observable` reader announces itself: its
//  first change dirties its own path. Views that only pass values down
//  never become nodes; their drawing lands in the nearest node above, or
//  the window canvas. So a screen has as many nodes as it has things that
//  change, not as many as it has views — a node costs an image and a
//  composite per frame, and a hundred wrappers would be a hundred of each
//  for nothing.
//
//  Once a boundary, a view stays one for as long as it stands at its
//  position, whatever rebuilds it. The node is keyed as its `@State` is —
//  path and identity — so it survives every rebuild and goes away with the
//  view.
//

import Foundation

/// Wraps the node a boundary view's body produced. Layout passes straight
/// through — size, flexibility, hit testing all reach the body — and only
/// `place` differs: the body draws into a list of the boundary's own, which
/// `RenderBoundaries` turns into the view's image(s).
struct RenderBoundaryContent: NodeContent {
    let key: RenderNodeKey

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        guard let child = node.singleChild else { return }
        guard let host = ShaderHost.current else {
            child.place(in: rect, proposal: proposal, context: context, into: &list)
            return
        }
        host.boundaries.placeBoundary(key: key, rect: rect, context: context, into: &list) { inner, content in
            child.place(in: rect, proposal: proposal, context: inner, into: &content)
        }
    }
}

/// The boundaries of one layout pass — which are open, what nodes were
/// placed inside each — and how what a boundary drew becomes its images.
///
/// A view's node holds only what the view draws *itself* — what nested
/// nodes draw is theirs. Where the view draws something after a nested
/// node that lands over it (a `ZStack` overlay on a hot child), that run of
/// commands becomes a node of its own, composited after the child; a run
/// that overlaps nothing placed before it merges into the view's image.
/// The window canvas is the outermost such frame. Every node kind reports
/// where it was placed (`noteNested`): automatic, drawing group,
/// `ThorCanvas`, shader slot.
///
/// The images are pulled from the `RenderNodeManager` and filled through
/// the `NodePainter`.
@MainActor
final class RenderBoundaries {
    typealias ImageEntry = RenderNodeManager.ImageEntry

    /// One boundary being placed: the nodes placed directly inside it, in
    /// paint order, each with where in the boundary's own list it fell.
    struct Frame {
        /// Paint position taken for the primary image before anything
        /// inside was placed — so the image sits under every nested node.
        let primaryOrder: Int
        var markers: [Marker] = []
    }

    struct Marker {
        /// Commands the enclosing list held when the nested node was placed
        /// — where the enclosing content splits into runs.
        let index: Int
        /// Everything the nested node composites, in points.
        let rect: Rect
        /// Paint position reserved for the run after this node, should that
        /// run need an image of its own.
        let runOrder: Int
    }

    private let nodes: RenderNodeManager
    private let painter: NodePainter

    /// The boundaries open at this point of the pass, innermost last; the
    /// first is the window's own frame.
    private var frames: [Frame] = []

    init(nodes: RenderNodeManager, painter: NodePainter) {
        self.nodes = nodes
        self.painter = painter
    }

    func beginPass() {
        // The window canvas is the outermost frame; it composites first,
        // so its primary order is below every node's.
        frames = [Frame(primaryOrder: -1)]
    }

    func endPass() {
        frames.removeAll()
    }

    /// Place the view at `key` as a node boundary: `body` places its subtree
    /// with a context and list of this frame's own, and what it drew goes
    /// into images keyed by `key` rather than into `list` — split around
    /// the nodes placed inside it, see the file comment. `rect` is the
    /// view's frame, `context` what it was placed under.
    ///
    /// A capture (`flattensRenderNodes`) wants every pixel in its own list,
    /// and a view covering the whole window *is* the window canvas: both
    /// draw straight through.
    func placeBoundary(
        key: RenderNodeKey,
        rect: Rect,
        context: DrawContext,
        into list: inout DisplayList,
        body: (DrawContext, inout DisplayList) -> Void
    ) {
        let coversWindow = rect.minX <= 0 && rect.minY <= 0
            && rect.maxX >= nodes.windowSize.width && rect.maxY >= nodes.windowSize.height
        guard !context.flattensRenderNodes, rect.width > 0, rect.height > 0, !coversWindow else {
            body(context, &list)
            return
        }
        frames.append(Frame(primaryOrder: nodes.nextPaintOrder()))
        // The image holds what the view draws wherever it draws it; what a
        // container outside clips away is cut at the composite instead, so
        // the content compares equal as the view scrolls under the clip —
        // and travels on as `nodeClip`, for the nodes inside. A rounded
        // clip has no scissor equivalent and stays in the commands.
        let clip = context.compositeClip
        var inner = context
        if context.clipCornerRadius == 0 {
            inner.clip = nil
            inner.nodeClip = clip
        }
        var content = DisplayList()
        body(inner, &content)
        let frame = frames.removeLast()
        if let extent = commit(key: key, clip: clip, frame: frame, content: content) {
            noteNested(at: list.commands.count, rect: extent)
        }
    }

    /// Open a frame for content that the caller collects in a list of its
    /// own (the host's overlay slot); `endFrame` hands it back for
    /// `useBoundary`.
    func beginFrame(primaryOrder: Int) {
        frames.append(Frame(primaryOrder: primaryOrder))
    }

    func endFrame() -> Frame? {
        frames.popLast()
    }

    /// The images for a frame collected outside `placeBoundary`.
    func useBoundary(key: RenderNodeKey, clip: Rect?, frame: Frame, content: DisplayList) {
        _ = commit(key: key, clip: clip, frame: frame, content: content)
    }

    /// Record a node placed directly inside the innermost open frame: the
    /// enclosing content is split here, and `rect` is what the node covers
    /// — a later run of the enclosing content over it must composite after
    /// it, not under. Every node kind reports itself: automatic, drawing
    /// group, `ThorCanvas`, shader slot.
    func noteNested(at index: Int, rect: Rect) {
        guard !frames.isEmpty else { return }
        frames[frames.count - 1].markers.append(
            Marker(index: index, rect: rect, runOrder: nodes.nextPaintOrder())
        )
    }

    /// The window's own list at the end of the pass, with any run of it
    /// that lands over a node placed before it moved into a node of its
    /// own — the window canvas composites under everything.
    func endRootFrame(_ list: inout DisplayList) {
        guard let frame = frames.popLast(), !frame.markers.isEmpty else { return }
        let split = splitRuns(list.commands, at: frame.markers)
        guard !split.detached.isEmpty else { return }
        for run in split.detached {
            _ = useImage(
                key: RenderNodeKey(path: [], identity: Self.rootIdentity, id: run.index),
                clip: nil,
                commands: run.commands,
                order: frame.markers[run.index - 1].runOrder
            )
        }
        list = DisplayList(commands: split.primary)
    }

    private static let rootIdentity = ViewIdentity(type: ObjectIdentifier(RenderBoundaries.self), viewID: .unknown)

    /// Cut `commands` into runs at the markers, and sort what comes after
    /// the first marker into the primary image — which composites under
    /// every nested node — and images of their own, per run, for what must
    /// not: a command that lands over a node placed before it, and then
    /// any command that lands over one of those, since it was drawn after
    /// it and has to stay on top of it.
    private func splitRuns(
        _ commands: [DrawCommand],
        at markers: [Marker]
    ) -> (primary: [DrawCommand], detached: [(index: Int, commands: [DrawCommand])]) {
        var primary: [DrawCommand] = []
        var detached: [(index: Int, commands: [DrawCommand])] = []
        // The nodes placed before the run being cut.
        var covered: [Rect] = []
        // Everything moved out of the primary so far, whichever run: a
        // later command over any of it was drawn after it.
        var movedBounds: [Rect] = []
        var start = 0
        for run in 0...markers.count {
            let end = run < markers.count ? min(max(markers[run].index, start), commands.count) : commands.count
            defer { start = end }
            if run > 0 { covered.append(markers[run - 1].rect) }
            guard end > start else { continue }
            let slice = commands[start..<end]
            if run == 0 {
                primary.append(contentsOf: slice)
                continue
            }
            var moved: [DrawCommand] = []
            for command in slice {
                guard let bounds = command.paintBounds else { continue }
                if Self.overlaps(bounds, any: covered) || Self.overlaps(bounds, any: movedBounds) {
                    moved.append(command)
                    movedBounds.append(bounds)
                } else {
                    primary.append(command)
                }
            }
            if !moved.isEmpty {
                detached.append((run, moved))
            }
        }
        return (primary, detached)
    }

    /// A plain loop rather than `contains(where:)`: this runs per command
    /// per rect of every pass, and a closure here pays an actor-isolation
    /// check on each call.
    private static func overlaps(_ bounds: Rect, any rects: [Rect]) -> Bool {
        for rect in rects where rect.intersects(bounds) { return true }
        return false
    }

    /// File the images for one boundary and return everything the boundary
    /// composites — its own images and its nested nodes' — for the frame
    /// above it, or `nil` when it composites nothing.
    private func commit(key: RenderNodeKey, clip: Rect?, frame: Frame, content: DisplayList) -> Rect? {
        var extent: Rect?
        func cover(_ rect: Rect?) {
            guard let rect else { return }
            extent = extent.map { $0.union(rect) } ?? rect
        }
        for marker in frame.markers { cover(marker.rect) }
        guard !content.isEmpty else { return extent }
        let split = splitRuns(content.commands, at: frame.markers)
        cover(useImage(key: key, clip: clip, commands: split.primary, order: frame.primaryOrder))
        for run in split.detached {
            cover(useImage(
                key: RenderNodeKey(path: key.path, identity: key.identity, id: run.index),
                clip: clip,
                commands: run.commands,
                order: frame.markers[run.index - 1].runOrder
            ))
        }
        return extent
    }

    /// The image node for `key` holding `commands` (absolute coordinates),
    /// composited where they paint and cut to `clip`. The image is the
    /// commands' paint bounds inside the window, rounded to the granule;
    /// the content is kept in the image's own coordinates, so a view that
    /// only moved by whole pixels compares equal and is not painted again.
    /// Returns the visible rect, in points, or `nil` when nothing is shown.
    private func useImage(key: RenderNodeKey, clip: Rect?, commands: [DrawCommand], order: Int) -> Rect? {
        guard !commands.isEmpty else { return nil }
        let scale = nodes.scale
        var bounds: Rect?
        for command in commands {
            guard let b = command.paintBounds else { continue }
            bounds = bounds.map { $0.union(b) } ?? b
        }
        let window = Rect(origin: .zero, size: nodes.windowSize)
        guard let visibleBounds = bounds?.intersection(window), visibleBounds.width > 0, visibleBounds.height > 0 else {
            return nil
        }
        // Scrolled out of its container: nothing to show, so nothing to
        // paint — and no image to hold until it comes back.
        if let clip {
            let shown = visibleBounds.intersection(clip)
            guard shown.width > 0, shown.height > 0 else { return nil }
        }
        let px = (visibleBounds.minX * scale).rounded(.down)
        let py = (visibleBounds.minY * scale).rounded(.down)
        let pixels = Rect(
            x: px, y: py,
            width: (visibleBounds.maxX * scale).rounded(.up) - px,
            height: (visibleBounds.maxY * scale).rounded(.up) - py
        )
        let size = nodes.imageSize(pixelWidth: pixels.width, pixelHeight: pixels.height)
        guard let entry = nodes.imageNode(for: key, width: size.width, height: size.height) else { return nil }

        let imageRect = Rect(
            x: px / scale, y: py / scale,
            width: Double(entry.width) / scale, height: Double(entry.height) / scale
        )
        entry.container.compositeRect = SIMD4(px, py, Double(entry.width), Double(entry.height))
        // Only the part inside the container's clip and the window shows;
        // the granule slack past the content is transparent anyway.
        let visible = imageRect.intersection(clip.map { $0.intersection(window) } ?? window)
        let minX = (visible.minX * scale).rounded(.down)
        let minY = (visible.minY * scale).rounded(.down)
        let maxX = (visible.maxX * scale).rounded(.up)
        let maxY = (visible.maxY * scale).rounded(.up)
        entry.container.compositeScissor = SIMD4(minX, minY, max(0, maxX - minX), max(0, maxY - minY))
        nodes.composite(entry.container, at: order)

        // Local to the image, so a view that only moved by whole pixels
        // compares equal to what its image holds.
        painter.schedule(
            entry,
            content: DisplayList(commands: commands).translated(dx: -px / scale, dy: -py / scale),
            origin: SIMD2(px, py)
        )
        if LayoutTrace.isEnabled {
            nucleantLogError(String(
                format: "[layout] image   rect x=%7.2f y=%7.2f w=%7.2f h=%7.2f  image %dx%d  ",
                imageRect.minX, imageRect.minY, imageRect.width, imageRect.height,
                entry.width, entry.height
            ) + "\(key.path)/\(key.id)\n")
        }
        return visible.width > 0 && visible.height > 0 ? visible : nil
    }
}
