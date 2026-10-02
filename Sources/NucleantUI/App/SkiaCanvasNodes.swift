//
//  SkiaCanvasNodes.swift
//  NucleantUI
//
//  The Skia canvas nodes: Skia's counterpart of `CanvasNode`, each with a
//  `SkiaDisplayRenderer`. With `SKIA_MODE` they are what `.drawingGroup()`,
//  the `.shader` layers and the painter draw into; `ThorCanvas` keeps its
//  ThorVG canvas nodes either way.
//
//  Kept by `RenderNodeManager` alongside its own: pulled by key each pass,
//  retired when no view pulled them, pooled on release. Every node shares
//  one Ganesh context, made with the first node, so Skia's caches (glyphs,
//  pipelines) are built once for the window rather than once per node.
//

import NucleantVulkan
import NucleantSkia
import Dispatch

extension RenderNodeManager {

    /// One Skia canvas the size of a view's frame, composited into it — or,
    /// for a `.shader` layer and the painter, sampled or copied by another
    /// node instead.
    @MainActor
    final class SkiaCanvasNode {
        let node: SkiaShaderNode<NucleantRenderNode>
        let container: NucleantRenderNode
        let renderer: SkiaDisplayRenderer
        /// Pixel size of the image — the frame rounded up to whole granules.
        var width: Int
        var height: Int
        /// What the canvas holds, and for a `.shader` layer the origin it
        /// was drawn from. An identical list is not drawn again.
        var content: DisplayList?
        var origin: Point = .zero
        /// Seen during the current layout pass.
        var used = true
        /// Where the view was last placed, and that origin snapped to a
        /// whole pixel.
        var rect: Rect = .zero
        var pixelOrigin: Point = .zero

        init(node: SkiaShaderNode<NucleantRenderNode>, container: NucleantRenderNode, width: Int, height: Int) {
            self.node = node
            self.container = container
            self.renderer = SkiaDisplayRenderer(node: node)
            self.width = width
            self.height = height
        }

        /// Point the node at its frame, and at whatever its container lets
        /// it show. `scale` is pixels per point.
        func place(rect: Rect, clip: Rect?, scale: Double) {
            self.rect = rect
            let x = (rect.minX * scale).rounded(.down)
            let y = (rect.minY * scale).rounded(.down)
            pixelOrigin = Point(x: x / scale, y: y / scale)
            container.compositeRect = SIMD4(x, y, Double(width), Double(height))
            let visible = clip.map { rect.intersection($0) } ?? rect
            let minX = (visible.minX * scale).rounded(.down)
            let minY = (visible.minY * scale).rounded(.down)
            let maxX = (visible.maxX * scale).rounded(.up)
            let maxY = (visible.maxY * scale).rounded(.up)
            container.compositeScissor = SIMD4(minX, minY, max(0, maxX - minX), max(0, maxY - minY))
        }

        /// Draw `list` into the canvas — unless it is what the canvas already
        /// holds — for the engine to flush at the frame.
        func render(_ list: DisplayList, at path: [Int]) {
            guard content != list else { return }
            if PerfTrace.isEnabled { PerfTrace.nodesDrawn += 1 }
            PerfTrace.trace("skia node \(width)x\(height) at \(path): \(list.commands.count) commands drawn")
            renderer.render(list)
            content = list
            node.dirty = true
            container.needsRender = true
        }
    }

    /// The Skia canvas nodes standing, by view; the spare pool; and what
    /// waits to be freed.
    @MainActor
    final class SkiaCanvasNodes {
        private unowned let engine: NucleantRenderEngine
        private unowned let manager: RenderNodeManager

        /// The Ganesh context every node draws through, made with the first.
        private(set) var context: SkiaVulkanContext?

        private var nodes: [RenderNodeKey: SkiaCanvasNode] = [:]
        private var spare: [SkiaCanvasNode] = []
        private let spareLimit = 12
        private var pendingDestroy: [SkiaCanvasNode] = []

        /// Backing-store pixels per point.
        var scale: Double = 1 {
            didSet {
                for node in nodes.values { node.renderer.scale = scale }
                for node in spare { node.renderer.scale = scale }
            }
        }

        init(engine: NucleantRenderEngine, manager: RenderNodeManager) {
            self.engine = engine
            self.manager = manager
        }

        /// The shared context, made on first use.
        func sharedContext() -> SkiaVulkanContext? {
            if let context { return context }
            do {
                let made = try engine.makeSkiaContext()
                context = made
                return made
            } catch {
                nucleantFlushStandardOutput()
                nucleantLogError("NucleantUI: Skia context failed: \(error)\n")
                return nil
            }
        }

        // MARK: Pass lifecycle

        func beginPass() {
            for node in nodes.values { node.used = false }
        }

        func retireUnused() {
            for (key, node) in nodes where !node.used {
                retire(node)
                nodes[key] = nil
            }
        }

        // MARK: By view

        /// The node standing for `key`, resized if its frame outgrew the
        /// image (or shrank a granule), taken from the pool or built if there
        /// is none. Composited into its frame.
        func canvasNode(for key: RenderNodeKey, rect: Rect) -> SkiaCanvasNode? {
            let size = manager.imageSize(for: rect)
            if let existing = nodes[key] {
                existing.used = true
                guard existing.width != size.width || existing.height != size.height else {
                    return existing
                }
                // A new surface holds nothing — the list is drawn again.
                if resize(existing, width: size.width, height: size.height) {
                    existing.content = nil
                    existing.container.needsRender = true
                    return existing
                }
                retire(existing)
                nodes[key] = nil
            }
            guard let node = acquire(width: size.width, height: size.height) else { return nil }
            node.container.compositesToWindow = true
            nodes[key] = node
            return node
        }

        // MARK: Pool, build, retire, free

        /// A node at `width × height`, composited nowhere yet: `handed` or a
        /// spare resized in place if there is one, else a fresh one. In the
        /// engine's list on return, holding nothing.
        func acquire(width: Int, height: Int, reusing handed: SkiaCanvasNode? = nil) -> SkiaCanvasNode? {
            if let node = handed ?? spare.popLast() {
                if resize(node, width: width, height: height) {
                    node.renderer.scale = scale
                    node.content = nil
                    node.used = true
                    node.container.needsRender = true
                    engine.append(node.container)
                    return node
                }
                destroy(node)
            }
            let started = PerfTrace.isVerbose ? DispatchTime.now().uptimeNanoseconds : 0
            guard let context = sharedContext(),
                  let skia = engine.makeSkiaWidgetNode(context: context, width: width, height: height) else {
                nucleantFlushStandardOutput()
                nucleantLogError("NucleantUI: skia canvas node build (\(width)x\(height)) failed\n")
                return nil
            }
            let container = NucleantRenderNode(id: Int.random(in: Int.min...Int.max), context: .skia(skia))
            container.observeContext()
            engine.append(container)
            let node = SkiaCanvasNode(node: skia, container: container, width: width, height: height)
            node.renderer.scale = scale
            PerfTrace.trace("skia canvas node \(width)x\(height): \(PerfTrace.millis(since: started))")
            return node
        }

        /// A new surface at `width × height` for the same node. False leaves
        /// it as it was.
        func resize(_ node: SkiaCanvasNode, width: Int, height: Int) -> Bool {
            guard engine.resizeSkiaNode(node.node, id: node.container.id, width: width, height: height) else {
                return false
            }
            node.width = width
            node.height = height
            return true
        }

        /// Out of the engine now; freed or pooled at `releasePending`, outside
        /// any recording.
        func retire(_ node: SkiaCanvasNode) {
            engine.nodes.removeAll { $0.id == node.container.id }
            engine.invalidateComposite(id: node.container.id)
            pendingDestroy.append(node)
        }

        func releasePending() {
            guard !pendingDestroy.isEmpty else { return }
            let retired = pendingDestroy
            pendingDestroy.removeAll(keepingCapacity: true)
            for node in retired { recycle(node) }
        }

        /// Keep a node for the next one to appear; past the limit it is freed.
        func recycle(_ node: SkiaCanvasNode) {
            node.content = nil
            guard spare.count < spareLimit else {
                destroy(node)
                return
            }
            spare.append(node)
        }

        func destroy(_ node: SkiaCanvasNode) {
            node.node.destroyResources(engine)
        }

        func destroyAll() {
            for node in nodes.values { retire(node) }
            nodes.removeAll()
            releasePending()
            for node in spare { destroy(node) }
            spare.removeAll()
        }
    }
}
