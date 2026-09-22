//
//  RenderNodeManager.swift
//  NucleantSwiftUI
//
//  The render nodes that belong to *views*, kept alive across the momentary
//  view structs. A view pulls its node out of here by the identity its state
//  is keyed by, every pass it is placed; a node not pulled by the end of a
//  pass belongs to a view that left the tree, and is retired.
//
//  Two kinds of node, both the engine's. A canvas node (`CanvasNode`) is a
//  ThorVG canvas the size of the view's frame — `.drawingGroup()`,
//  `ThorCanvas`, the `.shader` layer canvases, and the painter that fills
//  the image nodes. A fresh wg canvas costs ~60ms (its renderer compiles
//  pipelines on first target), a retargeted one under a millisecond, so a
//  retired canvas is pooled, never thrown away lightly. An image node
//  (`ImageEntry`) is the engine's copy-target image, for the automatic
//  per-view nodes: microseconds to make, pooled by size.
//
//  What a node holds is the view's business (it draws into the node it
//  pulled); where its runs split around nested nodes is `RenderBoundaries`';
//  how an image node gets its pixels is `NodePainter`'s. This keeps the
//  nodes, sizes their images, and puts the engine's list in the order the
//  tree paints in.
//

import NucleantVulkan
import NucleantThorVG
import Dispatch

/// What a per-view node is keyed by: where the view stands, which view it is
/// (type and stamped call site), and — when the author asked to start over —
/// their own id.
struct RenderNodeKey: Hashable {
    let path: [Int]
    let identity: ViewIdentity
    /// `ThorCanvas(id:)`'s value, hashed; 0 when there is none. A different
    /// value is a different node. For an automatic node, the run index: 0
    /// for the view's primary image, k for the run after its k-th nested
    /// node when that run needs an image of its own.
    let id: Int

    init(path: [Int], identity: ViewIdentity, id: Int = 0) {
        self.path = path
        self.identity = identity
        self.id = id
    }
}

@MainActor
final class RenderNodeManager {

    /// One ThorVG canvas the size of a view's frame, composited into it —
    /// or, for a `.shader` layer and the painter, sampled or copied by
    /// another node instead of composited.
    @MainActor
    final class CanvasNode {
        let node: ThorShaderNode<NucleantRenderNode>
        let container: NucleantRenderNode
        let renderer: ThorDisplayRenderer
        /// The canvas as a `ThorCanvas` view's closures see it.
        let thorContext: ThorContext
        /// Pixel size of the image — the frame rounded up to whole granules,
        /// so a frame that jitters by a few points keeps its image.
        var width: Int
        var height: Int
        /// What the canvas holds: node-local for a drawing group, absolute for
        /// a `.shader` layer — and for the latter, the origin it was drawn
        /// from. An identical list is not drawn again.
        var content: DisplayList?
        var origin: Point = .zero
        /// For a `ThorCanvas`: whether `onInit` has run on this canvas, which
        /// build's `renderer` last ran, and the frame it ran for.
        var initialized = false
        var generation = -1
        var renderedSize: Size = .zero
        /// State the `renderer` closure read, each slot listing the view's
        /// path (`readerPath`) among its readers — undone before it runs
        /// again and when the node retires.
        var reads: [any AnyStateStorage] = []
        var readerPath: [Int] = []
        /// Seen during the current layout pass. Anything not seen has left
        /// the tree and is retired.
        var used = true
        /// Where the view was last placed, in points, and that origin snapped
        /// to a whole pixel: where the image actually composites, so texels
        /// land on pixels (a fractional origin bilinearly blurs everything).
        var rect: Rect = .zero
        var pixelOrigin: Point = .zero

        init(
            node: ThorShaderNode<NucleantRenderNode>,
            container: NucleantRenderNode,
            renderer: ThorDisplayRenderer,
            width: Int,
            height: Int
        ) {
            self.node = node
            self.container = container
            self.renderer = renderer
            self.thorContext = ThorContext(base: node.canvas.base)
            self.width = width
            self.height = height
        }

        /// Point the node at its frame, and at whatever its container lets
        /// it show. `scale` is pixels per point.
        func place(rect: Rect, clip: Rect?, scale: Double) {
            self.rect = rect
            // Whole pixels, at the image's own size, so texels map 1:1. The
            // image is bigger than the frame (the granule); the scissor below
            // cuts the slack.
            let x = (rect.minX * scale).rounded(.down)
            let y = (rect.minY * scale).rounded(.down)
            pixelOrigin = Point(x: x / scale, y: y / scale)
            container.compositeRect = SIMD4(x, y, Double(width), Double(height))
            // The frame — from the snapped origin to the last pixel it touches —
            // intersected with the container's clip, as a shader slot's is.
            let visible = clip.map { rect.intersection($0) } ?? rect
            let minX = (visible.minX * scale).rounded(.down)
            let minY = (visible.minY * scale).rounded(.down)
            let maxX = (visible.maxX * scale).rounded(.up)
            let maxY = (visible.maxY * scale).rounded(.up)
            container.compositeScissor = SIMD4(minX, minY, max(0, maxX - minX), max(0, maxY - minY))
            if LayoutTrace.isEnabled {
                fputs(String(
                    format: "[layout] node    rect x=%7.2f y=%7.2f w=%7.2f h=%7.2f  image %dx%d\n",
                    rect.minX, rect.minY, rect.width, rect.height, width, height
                ), stderr)
            }
        }

        /// Draw `list` into the canvas — unless it is what the canvas already
        /// holds — for the engine to rasterize at the frame.
        func render(_ list: DisplayList, at path: [Int]) {
            guard content != list else { return }
            PerfTrace.nodesDrawn += 1
            PerfTrace.trace("node \(width)x\(height) at \(path): \(list.commands.count) commands drawn")
            renderer.render(list)
            content = list
            node.dirty = true
            container.needsRender = true
        }

        /// Have the engine rasterize the canvas at the frame after its
        /// paints were changed in place: ThorVG re-prepares only what it is
        /// told changed, and `draw` alone is not guaranteed to ask.
        func rasterize() {
            _ = thorContext.update()
            PerfTrace.nodesDrawn += 1
            node.dirty = true
            container.needsRender = true
        }
    }

    /// A standing automatic node: the engine's copy-target image, and what
    /// `NodePainter` knows it holds.
    @MainActor
    final class ImageEntry {
        let node: ImageNode<NucleantRenderNode>
        let container: NucleantRenderNode
        /// What the image holds, in the image's own coordinates; `nil` for a
        /// fresh or pooled image holding nothing of use.
        var content: DisplayList?
        /// What it should hold after this pass — set when the list differs
        /// from `content`, painted at the end of the pass.
        var pending: DisplayList?
        /// The part of the image `pending` changes, in the image's own
        /// coordinates (points), when the rest can be kept. `nil` paints
        /// the whole image.
        var damage: Rect?
        /// The window pixel the image's origin sits at — the content is
        /// relative to it, so a change of origin is a change of content.
        var pixelOrigin = SIMD2<Double>(0, 0)
        var used = true

        /// Pixel size of the image — a multiple of the granule.
        var width: Int { Int(node.width) }
        var height: Int { Int(node.height) }

        init(node: ImageNode<NucleantRenderNode>, container: NucleantRenderNode) {
            self.node = node
            self.container = container
        }
    }

    private unowned let engine: NucleantRenderEngine

    /// The canvas nodes standing, by the identity of the view that owns
    /// each; and the image nodes, by the view (and run) each holds.
    private var nodes: [RenderNodeKey: CanvasNode] = [:]
    private var images: [RenderNodeKey: ImageEntry] = [:]

    /// Backing-store pixels per point.
    var scale: Double = 1 {
        didSet {
            for node in nodes.values { node.renderer.scale = scale }
        }
    }

    /// The window's content size in points, per pass. An image is never
    /// bigger than the swapchain: the composite drops a viewport whose
    /// dimensions exceed it (found the hard way with a 912×624 overlay over
    /// a 900×620 window — a smaller viewport hanging past an edge is fine).
    /// A node larger than the window is composited through a window-sized
    /// image holding its visible part instead.
    private(set) var windowSize: Size = .zero

    /// Images are allocated in multiples of this many pixels per side: a
    /// 128×130 frame gets a 128×144 image, and growing to 128×140 reallocates
    /// nothing. `compositeRect` keeps the exact frame.
    static let granule = 16

    /// Canvases no longer in use, kept for the next node to appear — see the
    /// file comment for why a canvas is never thrown away lightly.
    private var spare: [CanvasNode] = []
    private let spareLimit = 12

    /// Images no longer in use, kept for the next node of the same size.
    private var spareImages: [ImageEntry] = []
    private let spareImageLimit = 32

    /// Retired this pass — detached from the engine, GPU objects still
    /// allocated until `releasePending` runs outside any recording.
    private var pendingDestroy: [CanvasNode] = []
    private var pendingDestroyImages: [ImageEntry] = []

    /// This pass's composite order, by container id — every node and shader
    /// slot placed this pass, numbered as it was placed. `endPass` sorts the
    /// engine's list by it.
    private var paintOrders: [Int: Int] = [:]
    private var paintCounter = 0

    init(engine: NucleantRenderEngine) {
        self.engine = engine
    }

    // MARK: - Layout-pass lifecycle

    func beginPass(windowSize: Size) {
        self.windowSize = windowSize
        for node in nodes.values { node.used = false }
        for entry in images.values { entry.used = false }
        paintOrders.removeAll(keepingCapacity: true)
        paintCounter = 0
    }

    /// The next position in this pass's paint order. Taken by everything
    /// that composites — per-view nodes, shader slots — at the moment it is
    /// placed, which is tree paint order.
    func nextPaintOrder() -> Int {
        defer { paintCounter += 1 }
        return paintCounter
    }

    /// File `container` at `order` for this pass. `layer` puts a slot's
    /// canvas just before the compute node that samples it: the engine
    /// updates nodes in list order, so the canvas must be drawn first.
    func composite(_ container: NucleantRenderNode, at order: Int, layer: Bool = false) {
        paintOrders[container.id] = order * 2 + (layer ? 0 : 1)
    }

    /// Retire the nodes no view pulled this pass: their views left the tree.
    func retireUnused() {
        for (key, node) in nodes where !node.used {
            retire(node)
            nodes[key] = nil
        }
        for (key, entry) in images where !entry.used {
            retire(entry)
            images[key] = nil
        }
    }

    /// Put the engine's list in this pass's paint order: the window canvas
    /// (and anything else not placed by a view) first, then every node and
    /// slot as it was placed. The engine composites in list order, later on
    /// top — so without this a node created later would sit over one that
    /// the tree draws after it.
    func endPass() {
        guard !paintOrders.isEmpty else { return }
        // Ranked once each, and by the current position second, so the
        // sort is stable whatever the standard library's happens to be.
        var ranked: [Ranked] = []
        ranked.reserveCapacity(engine.nodes.count)
        for (offset, node) in engine.nodes.enumerated() {
            ranked.append(Ranked(order: paintOrders[node.id] ?? -1, offset: offset, node: node))
        }
        ranked.sort()
        var changed = false
        for (offset, entry) in ranked.enumerated() where entry.offset != offset {
            changed = true
            break
        }
        if changed {
            engine.nodes = ranked.map(\.node)
        }
    }

    private struct Ranked: Comparable {
        let order: Int
        let offset: Int
        let node: NucleantRenderNode

        static func < (a: Ranked, b: Ranked) -> Bool {
            a.order != b.order ? a.order < b.order : a.offset < b.offset
        }

        static func == (a: Ranked, b: Ranked) -> Bool {
            a.order == b.order && a.offset == b.offset
        }
    }

    // MARK: - Image sizes

    /// Pixel size the image for `rect` is allocated at: rounded up to the
    /// granule, and never past the window (see `windowSize`).
    func imageSize(for rect: Rect) -> (width: Int, height: Int) {
        imageSize(pixelWidth: (rect.width * scale).rounded(.up), pixelHeight: (rect.height * scale).rounded(.up))
    }

    func imageSize(pixelWidth: Double, pixelHeight: Double) -> (width: Int, height: Int) {
        func round(_ pixels: Double, limit: Double) -> Int {
            let pixels = max(1, Int(pixels))
            let granule = Self.granule
            let rounded = (pixels + granule - 1) / granule * granule
            let cap = Int((limit * scale).rounded(.up))
            return cap > 0 ? max(1, min(rounded, max(cap, pixels))) : rounded
        }
        return (round(pixelWidth, limit: windowSize.width), round(pixelHeight, limit: windowSize.height))
    }

    // MARK: - Canvas nodes: by view, pool, build, retire, free

    /// The canvas node standing for `key`, resized if its frame outgrew the
    /// image (or shrank a granule), taken from the pool or built if there
    /// is none. Composited into its frame.
    func canvasNode(for key: RenderNodeKey, rect: Rect) -> CanvasNode? {
        let size = imageSize(for: rect)
        if let existing = nodes[key] {
            existing.used = true
            guard existing.width != size.width || existing.height != size.height else {
                return existing
            }
            // Same node, new image — the canvas keeps its paints, so an
            // author's shapes survive; the display list is drawn again
            // because its frames changed with the size anyway.
            if resize(existing, width: size.width, height: size.height) {
                existing.content = nil
                existing.container.needsRender = true
                return existing
            }
            // Left at the old size, which is no use — replace it.
            retire(existing)
            nodes[key] = nil
        }
        guard let node = acquire(width: size.width, height: size.height) else { return nil }
        node.container.compositesToWindow = true
        nodes[key] = node
        return node
    }

    /// A canvas node at `width × height`, composited nowhere yet: a spare
    /// retargeted in place if there is one, else a fresh one. In the engine's
    /// list on return, holding no paints.
    func acquire(width: Int, height: Int) -> CanvasNode? {
        acquire(width: width, height: height, reusing: nil)
    }

    /// As `acquire(width:height:)`, starting from `handed` — a canvas its
    /// previous owner is passing straight on — before the pool.
    func acquire(width: Int, height: Int, reusing handed: CanvasNode?) -> CanvasNode? {
        if let node = handed ?? spare.popLast() {
            if resize(node, width: width, height: height) {
                node.renderer.scale = scale
                node.thorContext.scale = scale
                node.content = nil
                node.initialized = false
                node.generation = -1
                node.renderedSize = .zero
                node.used = true
                node.container.needsRender = true
                engine.append(node.container)
                return node
            }
            // Left at its old size, which is no use here — replace it.
            destroy(node)
        }
        let started = PerfTrace.isVerbose ? DispatchTime.now().uptimeNanoseconds : 0
        guard let thor = engine.makeThorWidgetNode(width: width, height: height) else {
            fflush(stdout)
            fputs("NucleantSwiftUI: canvas node build (\(width)x\(height)) failed\n", stderr)
            return nil
        }
        let container = NucleantRenderNode(
            id: Int.random(in: Int.min...Int.max),
            context: .thor(thor)
        )
        container.observeContext()
        engine.append(container)

        let renderer = ThorDisplayRenderer(canvas: thor.canvas.base)
        renderer.scale = scale
        let node = CanvasNode(node: thor, container: container, renderer: renderer, width: width, height: height)
        node.thorContext.scale = scale
        PerfTrace.trace("canvas node \(width)x\(height): \(PerfTrace.millis(since: started))")
        return node
    }

    /// Retarget the node's canvas at an image of `width × height` — the
    /// same `Tvg_Canvas`, so its paints survive. False leaves it as it was.
    func resize(_ node: CanvasNode, width: Int, height: Int) -> Bool {
        guard engine.resizeThorNode(node.node, id: node.container.id, width: width, height: height) else {
            return false
        }
        node.width = width
        node.height = height
        return true
    }

    /// Take a node out of the engine now and queue its GPU objects for
    /// `releasePending`. Freeing here, mid-pass, is the use-after-free the
    /// shader registry hit: command buffers in flight still reference the
    /// image. Taking it out of `engine.nodes` stops it compositing at once,
    /// which is all that has to happen now.
    func retire(_ node: CanvasNode) {
        engine.nodes.removeAll { $0.id == node.container.id }
        engine.invalidateComposite(id: node.container.id)
        pendingDestroy.append(node)
    }

    /// Free (or pool) everything retired since the last call. Called at the
    /// top of a frame, before anything is recorded; a node that is freed
    /// drains the device itself, one that is pooled needs no drain.
    func releasePending() {
        guard !pendingDestroy.isEmpty || !pendingDestroyImages.isEmpty else { return }
        let retired = pendingDestroy
        let retiredImages = pendingDestroyImages
        pendingDestroy.removeAll(keepingCapacity: true)
        pendingDestroyImages.removeAll(keepingCapacity: true)
        for node in retired { recycle(node) }
        for entry in retiredImages { recycle(entry) }
    }

    /// Keep a canvas for the next node to appear, emptied of its paints and
    /// of the reader registrations its `renderer` made; past the limit it
    /// is freed.
    func recycle(_ node: CanvasNode) {
        for storage in node.reads {
            storage.readers.removeValue(forKey: node.readerPath)
        }
        node.reads.removeAll()
        node.generation = -1
        node.renderedSize = .zero
        guard spare.count < spareLimit else {
            destroy(node)
            return
        }
        _ = tvg_canvas_remove(node.node.canvas.base, nil)
        node.content = nil
        node.initialized = false
        spare.append(node)
    }

    /// The canvas first: ThorVG holds its own reference to the wgpu texture
    /// behind the node's image for as long as it is the canvas's target, and
    /// the node's teardown releases that texture last.
    func destroy(_ node: CanvasNode) {
        _ = tvg_canvas_destroy(node.node.canvas.base)
        node.node.destroyResources(engine)
    }

    func destroyAll() {
        for node in nodes.values { retire(node) }
        nodes.removeAll()
        for entry in images.values { retire(entry) }
        images.removeAll()
        releasePending()
        for node in spare { destroy(node) }
        spare.removeAll()
        for entry in spareImages { entry.node.destroyResources(engine) }
        spareImages.removeAll()
    }

    // MARK: - Image nodes: by view, pool, build, retire, free

    /// The standing image for `key` at `width × height`, or a new one when
    /// there is none or the content outgrew it. An image that is a granule
    /// bigger than needed is kept: content whose bounds hover around a
    /// granule edge would otherwise reallocate every other pass.
    func imageNode(for key: RenderNodeKey, width: Int, height: Int) -> ImageEntry? {
        if let existing = images[key] {
            existing.used = true
            let slack = 2 * Self.granule
            // Never past the window: the composite drops a viewport wider
            // than the swapchain, so an image the window has shrunk under
            // is replaced however little it exceeds it.
            let cap = imageSize(for: Rect(origin: .zero, size: windowSize))
            if width <= existing.width, height <= existing.height,
               existing.width - width < slack, existing.height - height < slack,
               existing.width <= cap.width, existing.height <= cap.height {
                return existing
            }
            retire(existing)
            images[key] = nil
        }
        guard let entry = acquireImage(width: width, height: height) else { return nil }
        images[key] = entry
        return entry
    }

    private func acquireImage(width: Int, height: Int) -> ImageEntry? {
        if let index = spareImages.firstIndex(where: { $0.width == width && $0.height == height }) {
            let entry = spareImages.remove(at: index)
            entry.used = true
            engine.append(entry.container)
            return entry
        }
        let node: ImageNode<NucleantRenderNode>
        do {
            node = try engine.makeImageNode(width: width, height: height)
        } catch {
            fflush(stdout)
            fputs("NucleantSwiftUI: image node (\(width)x\(height)) failed: \(error)\n", stderr)
            return nil
        }
        let container = NucleantRenderNode(id: Int.random(in: Int.min...Int.max), context: .image(node))
        container.observeContext()
        // Nothing to draw at frame time; the composite samples it once
        // `readable` says the first copy landed.
        container.needsRender = false
        engine.append(container)
        return ImageEntry(node: node, container: container)
    }

    /// As `retire(_:)` for canvas nodes: out of the engine now, freed or
    /// pooled at `releasePending`.
    private func retire(_ entry: ImageEntry) {
        engine.nodes.removeAll { $0.id == entry.container.id }
        engine.invalidateComposite(id: entry.container.id)
        entry.pending = nil
        entry.damage = nil
        // A copy not yet recorded would land in an image about to be freed.
        entry.node.pendingCopy = nil
        pendingDestroyImages.append(entry)
    }

    private func recycle(_ entry: ImageEntry) {
        entry.content = nil
        entry.pending = nil
        entry.damage = nil
        guard spareImages.count < spareImageLimit else {
            entry.node.destroyResources(engine)
            return
        }
        spareImages.append(entry)
    }
}
