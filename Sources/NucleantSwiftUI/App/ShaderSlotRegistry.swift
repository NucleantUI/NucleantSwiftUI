//
//  ShaderSlotRegistry.swift
//  NucleantSwiftUI
//
//  A `Shader` view does not draw into the shared ThorVG canvas — it cannot,
//  the canvas is a 2D vector surface. It gets its own GPU node, composited
//  into its own rect of the swapchain, which is what `RenderContainerNode`'s
//  `compositeRect` is for.
//
//  That means slots have a *lifetime tied to the view tree*: created when a
//  Shader view first appears, moved and resized as it is laid out, destroyed
//  when it goes away. This registry is that bookkeeping, and the one place in
//  the framework where the view layer reaches the engine directly.
//
//  A `.shader(_:)` effect is the same slot with one more piece: a ThorVG
//  canvas of its own that the view is drawn into, bound to the compute
//  shader as a texture. Two engine nodes, then — the canvas, which is never
//  composited, and the effect's output, which is — updated in that order.
//
//  A `VertexShader` view is the same slot again with a graphics pipeline in
//  place of the compute one: its image is a colour attachment drawn by a
//  render pass, and composited exactly like the others.
//
//  The canvases themselves — a `.shader` layer's, and the per-view nodes of
//  `.drawingGroup()` / `ThorCanvas` — are `RenderNodeManager`'s, which this
//  registry owns and drives through the same pass lifecycle; one pool of
//  ThorVG canvases serves both. Slots and nodes are composited in the order
//  the tree placed them (`nextPaintOrder`), not the order they were built.
//

import CVulkan
import VulkanCore
import NucleantVulkan
import NucleantThorVG
import Dispatch

@MainActor
final class ShaderSlotRegistry {

    /// What a slot draws with: a compute dispatch or a vertex + fragment pass.
    @MainActor
    enum Backend {
        case compute(OGLShaderNode<NucleantRenderNode>, ShaderPipeline)
        case graphics(VertFragShaderNode<NucleantRenderNode>, VertexShaderPipeline)

        var argumentCapacity: Int {
            switch self {
            case .compute(_, let pipeline): return pipeline.argumentCapacity
            case .graphics(_, let pipeline): return pipeline.argumentCapacity
            }
        }

        func update(_ uniforms: ShaderUniforms) {
            switch self {
            case .compute(_, let pipeline): pipeline.update(uniforms)
            case .graphics(_, let pipeline): pipeline.update(uniforms)
            }
        }

        func updateArguments(_ packed: [Float]) {
            switch self {
            case .compute(_, let pipeline): pipeline.updateArguments(packed)
            case .graphics(_, let pipeline): pipeline.updateArguments(packed)
            }
        }
    }

    /// What a view asks its slot to be.
    enum Request {
        case compute(ShaderFunction, withLayer: Bool)
        case graphics(VertexShaderFunction, ShaderDraw, withLayer: Bool)

        /// Identity for the compiled pipeline; the kind is part of it, so a
        /// path that changes view type rebuilds.
        var source: String {
            switch self {
            case .compute(let function, _): return function.source
            case .graphics(let function, _, _): return "#graphics\n" + function.source
            }
        }

        var isAnimated: Bool {
            switch self {
            case .compute(let function, _): return function.isAnimated
            case .graphics(let function, _, _): return function.isAnimated
            }
        }

        var withLayer: Bool {
            switch self {
            case .compute(_, let withLayer), .graphics(_, _, let withLayer): return withLayer
            }
        }
    }

    /// One live shader view's GPU state.
    final class Slot {
        let backend: Backend
        let container: NucleantRenderNode
        /// For a `.shader(_:)` effect: the canvas the view is drawn into,
        /// which the shader samples. `nil` for a generative `Shader` view —
        /// and for a retired effect slot whose canvas has been handed on.
        var layer: Layer?
        /// Pixel size the node was built at — a resize rebuilds it.
        var width: Int
        var height: Int
        /// Source it was compiled from; a change recompiles.
        var source: String
        /// The argument names and kinds compiled in, and the values last
        /// uploaded — a change to the former rebuilds, to the latter
        /// re-uploads and re-dispatches.
        var argumentSignature: String
        var packedArguments: [Float] = []
        /// Whether the source reads the clock or the pointer. If not, one
        /// dispatch is all it needs until its input changes.
        let isAnimated: Bool
        /// Seen during the current layout pass. Anything not seen has left
        /// the tree and is torn down.
        var used = true
        /// Seconds since this shader appeared, fed to the `time` uniform.
        var elapsed: Double = 0
        /// Frames drawn since it appeared — ShaderToy's `iFrame`.
        var frame: Int = 0
        /// Where the view was last placed, in points — the pointer uniform
        /// is relative to it.
        var rect: Rect = .zero
        /// `rect`'s origin snapped to a whole pixel, in points: where the
        /// image is actually composited, and so where a layer's content is
        /// drawn from, so that texels land on pixels rather than between
        /// them (a fractional origin bilinearly blurs the whole layer).
        var pixelOrigin: Point = .zero

        init(
            backend: Backend,
            container: NucleantRenderNode,
            layer: Layer?,
            width: Int,
            height: Int,
            request: Request,
            arguments: ShaderArguments
        ) {
            self.backend = backend
            self.container = container
            self.layer = layer
            self.width = width
            self.height = height
            self.source = request.source
            self.argumentSignature = arguments.signature
            self.isAnimated = request.isAnimated
        }
    }

    /// The view side of a `.shader(_:)` slot: a ThorVG canvas the size of the
    /// view, rasterized whenever the view draws something different, and
    /// sampled by the slot's compute shader as `uContent`. A per-view canvas
    /// node that is never composited — `content` and `origin` are what it
    /// holds and where the view was when it was drawn; an identical list at
    /// the same place is not drawn again.
    typealias Layer = RenderNodeManager.CanvasNode

    private unowned let engine: NucleantRenderEngine

    /// The per-view render nodes (and the canvas pool the layers share),
    /// the painter that fills the automatic image nodes, and the
    /// boundaries a pass's drawing splits at.
    let renderNodes: RenderNodeManager
    let painter: NodePainter
    let boundaries: RenderBoundaries

    /// Keyed by the view's structural path — the same identity `@State` uses,
    /// so a shader keeps its pipeline across rebuilds and loses it only when
    /// the view itself goes away.
    private var slots: [[Int]: Slot] = [:]

    /// Backing-store pixels per point.
    var scale: Double = 1 {
        didSet {
            renderNodes.scale = scale
            painter.scale = scale
        }
    }

    /// Slots detached from the engine but not yet freed — see `endPass`.
    private var pendingDestroy: [Slot] = []

    init(engine: NucleantRenderEngine) {
        self.engine = engine
        self.renderNodes = RenderNodeManager(engine: engine)
        self.painter = NodePainter(engine: engine, nodes: renderNodes)
        self.boundaries = RenderBoundaries(nodes: renderNodes, painter: painter)
    }

    // MARK: - Layout-pass lifecycle

    /// `windowSize` is the window's content size in points — what bounds a
    /// per-view node's image.
    func beginPass(windowSize: Size) {
        for slot in slots.values { slot.used = false }
        renderNodes.beginPass(windowSize: windowSize)
        boundaries.beginPass()
    }

    /// Called from `ShaderContent.place`: make sure a slot exists for this
    /// view, at this size, and put it at this rect.
    func use(path: [Int], function: ShaderFunction, arguments: ShaderArguments, rect: Rect, clip: Rect?) {
        _ = slot(at: path, request: .compute(function, withLayer: false), arguments: arguments, rect: rect, clip: clip)
    }

    /// Called from `VertexShaderContent.place`: the graphics slot for this
    /// view, drawing `draw` this frame.
    func useGraphics(
        path: [Int],
        function: VertexShaderFunction,
        draw: ShaderDraw,
        arguments: ShaderArguments,
        rect: Rect,
        clip: Rect?
    ) {
        guard let slot = slot(at: path, request: .graphics(function, draw, withLayer: false),
                              arguments: arguments, rect: rect, clip: clip)
        else { return }
        redraw(slot, covering: draw)
    }

    /// The per-frame half of a graphics slot: how much the next draw covers.
    /// No rebuild, just a redraw when it changes.
    private func redraw(_ slot: Slot, covering draw: ShaderDraw) {
        guard case .graphics(let node, _) = slot.backend else { return }
        let vertices = UInt32(draw.vertices), instances = UInt32(draw.instances)
        guard node.vertexCount != vertices || node.instanceCount != instances else { return }
        node.vertexCount = vertices
        node.instanceCount = instances
        slot.container.needsRender = true
    }

    /// Called from `ShaderEffectContent.place`: the slot for this view with
    /// `content` — what the view drew this pass — in its canvas. `function`
    /// says which pipeline reads it: a compute dispatch over every pixel, or
    /// a vertex + fragment pair drawing `draw` over it.
    func useLayer(
        path: [Int],
        function: ShaderFunction,
        draw: ShaderDraw,
        arguments: ShaderArguments,
        rect: Rect,
        clip: Rect?,
        content: DisplayList
    ) {
        let request: Request = function.isGraphics
            ? .graphics(function, draw, withLayer: true)
            : .compute(function, withLayer: true)
        guard let slot = slot(at: path, request: request, arguments: arguments, rect: rect, clip: clip),
              let layer = slot.layer
        else { return }
        if function.isGraphics {
            redraw(slot, covering: draw)
        }
        // Absolute coordinates, so a view that merely moved reads as changed
        // and is drawn again at its new place; the canvas transform absorbs
        // the origin, but the comparison does not.
        guard layer.content != content || layer.origin != slot.pixelOrigin else { return }
        PerfTrace.layersDrawn += 1
        layer.renderer.render(content, origin: slot.pixelOrigin, flipHeight: slot.height)
        layer.content = content
        layer.origin = slot.pixelOrigin
        // Rasterize the canvas, then resample it — whether or not the shader
        // itself is animated.
        layer.container.needsRender = true
        slot.container.needsRender = true
    }

    /// The slot standing at `path`, rebuilt if its size or source changed,
    /// created if there is none; placed at `rect` either way.
    private func slot(
        at path: [Int],
        request: Request,
        arguments: ShaderArguments,
        rect: Rect,
        clip: Rect?
    ) -> Slot? {
        let source = request.source
        let withLayer = request.withLayer
        let pixelWidth = max(1, Int((rect.width * scale).rounded()))
        let pixelHeight = max(1, Int((rect.height * scale).rounded()))

        // This slot's place in the composite order is where the tree placed
        // it, whether the GPU objects are kept or rebuilt below.
        let order = renderNodes.nextPaintOrder()
        var previous: Slot?
        var canvas: Layer?
        if let existing = slots[path] {
            existing.used = true
            // Both rects are read fresh by the engine every frame, so moving or
            // re-clipping a shader view is free; only a *resize*, a source
            // change, or an argument list the buffer can't hold needs the GPU
            // objects rebuilt.
            place(existing, rect: rect, clip: clip)
            if existing.width == pixelWidth,
               existing.height == pixelHeight,
               existing.source == source,
               existing.argumentSignature == arguments.signature,
               existing.backend.argumentCapacity >= arguments.packed.count,
               (existing.layer != nil) == withLayer {
                upload(arguments, to: existing)
                composite(existing, at: order)
                return existing
            }
            // Retire it the way `endPass` does — detach now, free at the top
            // of the next frame. Freeing here, mid-frame, is the same
            // use-after-free §8 fixed for teardown: command buffers still in
            // flight reference the image, and the old container would stay
            // in `engine.nodes` for the composite pass to draw from freed
            // memory. Seen as a segfault inside MoltenVK on maximizing a
            // window with a shader on screen.
            //
            // Its canvas, though, is handed straight to the replacement: the
            // retargeting is in place, and the spare pool is only refilled
            // once the old GPU objects are freed, a frame from now.
            retire(existing)
            if withLayer {
                canvas = existing.layer
                existing.layer = nil
            }
            slots[path] = nil
            previous = existing
        }

        guard let slot = makeSlot(
            request: request,
            arguments: arguments,
            width: pixelWidth,
            height: pixelHeight,
            layer: withLayer ? .reuse(canvas) : .none
        ) else {
            return nil
        }
        // Same view, new image: the animation continues rather than restarts.
        if let previous {
            slot.elapsed = previous.elapsed
            slot.frame = previous.frame
        }
        place(slot, rect: rect, clip: clip)
        upload(arguments, to: slot)
        composite(slot, at: order)
        slots[path] = slot
        return slot
    }

    /// File the slot — and its layer canvas just before it, so the engine
    /// draws the canvas before the shader samples it — at `order`.
    private func composite(_ slot: Slot, at order: Int) {
        if let layer = slot.layer {
            renderNodes.composite(layer.container, at: order, layer: true)
        }
        renderNodes.composite(slot.container, at: order)
    }

    /// Hand the slot its argument values if they changed, and make it draw
    /// again — a static shader's one dispatch was of the old values.
    private func upload(_ arguments: ShaderArguments, to slot: Slot) {
        guard !arguments.isEmpty, arguments.packed != slot.packedArguments else { return }
        slot.backend.updateArguments(arguments.packed)
        slot.packedArguments = arguments.packed
        slot.container.needsRender = true
    }

    /// Point a slot at its frame, and at whatever its container allows it to
    /// draw within.
    private func place(_ slot: Slot, rect: Rect, clip: Rect?) {
        slot.rect = rect
        // Whole pixels, at the image's own size: a viewport that starts or
        // ends between pixels resamples the image, and a 1:1 mapping is what
        // keeps a layer's text as sharp as it was in the canvas.
        let x = (rect.minX * scale).rounded(.down)
        let y = (rect.minY * scale).rounded(.down)
        slot.pixelOrigin = Point(x: x / scale, y: y / scale)
        slot.container.compositeRect = SIMD4(
            x, y,
            Double(slot.width), Double(slot.height)
        )
        // Intersected here rather than in the engine: `clip` is the container's
        // rect, and what the slot may draw is the part of *its own* frame that
        // falls inside it.
        slot.container.compositeScissor = clip.map { clip in
            let visible = rect.intersection(clip)
            return SIMD4(
                visible.minX * scale, visible.minY * scale,
                visible.width * scale, visible.height * scale
            )
        }
        if LayoutTrace.isEnabled {
            let s = slot.container.compositeScissor
            nucleantLogError(String(
                format: "[layout] shader  rect x=%7.2f y=%7.2f w=%7.2f h=%7.2f  scissor %@\n",
                rect.minX, rect.minY, rect.width, rect.height,
                s.map { String(format: "x=%.2f y=%.2f w=%.2f h=%.2f", $0.x, $0.y, $0.z, $0.w) }
                    ?? "none"
            ))
        }
    }

    /// Retire slots whose views have left the tree.
    ///
    /// Detach now, free later. This runs inside the layout pass, from
    /// `ViewHost.layoutAndRender` — the middle of a frame, with command buffers
    /// for frames still in flight holding references to the image. Freeing here
    /// segfaulted inside MoltenVK even behind a `vkDeviceWaitIdle`. Taking the
    /// slot out of `engine.nodes` stops it compositing immediately (which is
    /// all that has to happen *now*), and the GPU objects are released at the
    /// top of the next frame, outside any recording.
    func endPass() {
        let started = PerfTrace.isVerbose ? DispatchTime.now().uptimeNanoseconds : 0
        var retired = 0
        for (path, slot) in slots where !slot.used {
            retire(slot)
            slots[path] = nil
            retired += 1
        }
        if retired > 0 {
            PerfTrace.trace("shader slots: retired \(retired) in \(PerfTrace.millis(since: started))")
        }
        // Retire the per-view nodes no view pulled, paint the images with
        // new content, then put the engine's list in this pass's paint
        // order — slots included.
        renderNodes.retireUnused()
        boundaries.endPass()
        painter.paintPending()
        renderNodes.endPass()
    }

    /// Take a slot out of the engine now and queue its GPU objects for
    /// `releasePending`. Drops the engine's per-slot descriptor set, pool
    /// and readable marker — `remove(id:)` would do this too, but it also
    /// frees the node, which is exactly what is being deferred.
    private func retire(_ slot: Slot) {
        let ids = [slot.container.id, slot.layer?.container.id].compactMap { $0 }
        engine.nodes.removeAll { ids.contains($0.id) }
        for id in ids { engine.invalidateComposite(id: id) }
        pendingDestroy.append(slot)
    }

    // MARK: - Per frame

    /// Advance every live shader's clock and hand it to the GPU, then flag the
    /// animated slots for redraw.
    ///
    /// A shader that reads the clock or the pointer wants a dispatch every
    /// frame — unlike the ThorVG canvas, that is the one thing on screen which
    /// is never idle. One that reads neither is left alone: its first dispatch
    /// (the slot starts `needsRender`) produced everything it will ever
    /// produce, until a `.shader` layer's content changes and `useLayer`
    /// re-arms it. Returns true when at least one slot is live, so the window
    /// knows the frame was not free.
    @discardableResult
    func tick(_ delta: Double, pointer: Point) -> Bool {
        releasePending()
        renderNodes.releasePending()
        painter.frameWillDraw()
        guard !slots.isEmpty else { return false }
        for slot in slots.values {
            slot.elapsed += delta
            slot.frame += 1
            // One pointer for every shader, in window pixels: two shaders
            // side by side read the same value and stay in step with each
            // other, which per-view coordinates never did.
            let local = Point(
                x: pointer.x * scale,
                y: pointer.y * scale
            )
            slot.backend.update(ShaderUniforms(
                time: Float(slot.elapsed),
                timeDelta: Float(delta),
                frame: Float(slot.frame),
                resolutionX: Float(slot.width),
                resolutionY: Float(slot.height),
                mouseX: Float(local.x),
                mouseY: Float(local.y),
                // zw is ShaderToy's "position while pressed"; there is no
                // press tracking on this path yet, so it mirrors xy.
                mouseClickX: Float(local.x),
                mouseClickY: Float(local.y)
            ))
            if slot.isAnimated {
                slot.container.needsRender = true
            }
        }
        return true
    }

    func destroyAll() {
        for slot in slots.values {
            retire(slot)
        }
        slots.removeAll()
        releasePending()
        painter.destroy()
        renderNodes.destroyAll()
    }

    /// Free everything retired by a previous pass. Called at the top of a
    /// frame, before anything is recorded.
    private func releasePending() {
        guard !pendingDestroy.isEmpty else { return }
        let retired = pendingDestroy
        pendingDestroy.removeAll(keepingCapacity: true)
        // One drain for the whole batch: nothing in flight may still reference
        // any of these images.
        vkDeviceWaitIdle(engine.device)
        for slot in retired { destroy(slot) }
    }

    // MARK: - Building

    /// Whether a slot gets a canvas, and if so which one to start from.
    private enum LayerRequest {
        case none
        /// A canvas to retarget if given, a spare or a fresh one otherwise.
        case reuse(Layer?)
    }

    private func makeSlot(
        request: Request,
        arguments: ShaderArguments,
        width: Int,
        height: Int,
        layer layerRequest: LayerRequest
    ) -> Slot? {
        let started = PerfTrace.isVerbose ? DispatchTime.now().uptimeNanoseconds : 0
        let layer: Layer?
        let withLayer: Bool
        switch layerRequest {
        case .none:
            layer = nil
            withLayer = false
        case .reuse(let handed):
            guard let made = makeLayer(width: width, height: height, reusing: handed) else { return nil }
            layer = made
            withLayer = true
        }
        let canvasReady = PerfTrace.isVerbose ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            PerfTrace.trace("shader slot \(width)x\(height)\(withLayer ? " +layer" : ""): "
                + "\(PerfTrace.millis(since: started))"
                + (withLayer ? " (canvas \(PerfTrace.millis(from: started, to: canvasReady)))" : ""))
        }
        do {
            // Room for half again as many floats as there are now, so an
            // array that grows a little does not rebuild the slot each time.
            let capacity = arguments.isEmpty ? 0 : max(256, arguments.packed.count * 3 / 2)
            let backend: Backend
            let context: NucleantRenderNode.Context
            switch request {
            case .compute(let function, _):
                let image = try makeImage(width: width, height: height, usage: .storage)
                let node = OGLShaderNode<NucleantRenderNode>(
                    width: UInt32(width),
                    height: UInt32(height),
                    image: image.image,
                    imageView: image.view,
                    memory: image.memory,
                    storageCapable: true
                )
                if let layer {
                    // Borrowed, as the node's contract says: the layer's node
                    // owns the image and frees it.
                    node.register(image: layer.node.image, imageView: layer.node.imageView)
                }
                let pipeline = try ShaderPipeline(
                    engine: engine,
                    imageView: image.view,
                    input: layer?.node.imageView,
                    source: try ShaderCode.compute(
                        function,
                        samplesContent: layer != nil,
                        arguments: arguments
                    ),
                    argumentCapacity: capacity
                )
                node.computePipeline = pipeline.pipeline
                node.computeLayout = pipeline.pipelineLayout
                node.computeDescriptorSet = pipeline.descriptorSet
                node.dirty = true
                backend = .compute(node, pipeline)
                context = .shader(node)
            case .graphics(let function, let draw, _):
                let pass = try colorPass()
                let image = try makeImage(width: width, height: height, usage: .colorAttachment)
                let node = try VertFragShaderNode<NucleantRenderNode>(
                    width: UInt32(width),
                    height: UInt32(height),
                    image: image.image,
                    imageView: image.view,
                    memory: image.memory,
                    pass: pass,
                    vertexCount: UInt32(draw.vertices),
                    instanceCount: UInt32(draw.instances)
                )
                let pipeline: VertexShaderPipeline
                do {
                    pipeline = try VertexShaderPipeline(
                        engine: engine,
                        renderPass: pass.renderPass!,
                        input: layer?.node.imageView,
                        source: try GraphicsShaderCode.graphics(
                            function,
                            samplesContent: layer != nil,
                            arguments: arguments
                        ),
                        argumentCapacity: capacity
                    )
                } catch {
                    node.destroyResources(engine)
                    throw error
                }
                node.pipeline = pipeline.pipeline
                node.pipelineLayout = pipeline.pipelineLayout
                node.descriptorSet = pipeline.descriptorSet
                node.dirty = true
                backend = .graphics(node, pipeline)
                context = .vertexShader(node)
            }

            let container = NucleantRenderNode(
                id: Int.random(in: Int.min...Int.max),
                context: context
            )
            container.observeContext()
            // After the layer's canvas node, so the engine draws the canvas
            // before the shader samples it.
            engine.append(container)

            return Slot(
                backend: backend,
                container: container,
                layer: layer,
                width: width,
                height: height,
                request: request,
                arguments: arguments
            )
        } catch {
            nucleantLogError("NucleantSwiftUI: shader node build (\(width)x\(height)) failed: \(error)\n")
            if let layer {
                engine.nodes.removeAll { $0.id == layer.container.id }
                recycle(layer)
            }
            return nil
        }
    }

    /// The canvas half of a `.shader` slot: a ThorVG node the size of the
    /// view, in the engine's list so it is drawn each frame its content
    /// changed, but never composited — `compositesToWindow` is what keeps its
    /// image off the swapchain and its size off the window's.
    ///
    /// `reusing` (or a spare from the shared pool) is retargeted in place
    /// rather than rebuilt: the canvas keeps its renderer, gets a new image
    /// at the new size, and its slot keeps its identity in the engine.
    private func makeLayer(width: Int, height: Int, reusing handed: Layer?) -> Layer? {
        guard let layer = renderNodes.acquire(width: width, height: height, reusing: handed) else {
            return nil
        }
        layer.container.compositesToWindow = false
        return layer
    }

    /// Free one retired slot. The caller has already detached it from the
    /// engine and drained the device.
    ///
    /// The pipeline goes first: its descriptor set points at the node's image
    /// view, so nothing references the image by the time it is freed.
    /// `engine.remove(id:)` is deliberately *not* used — it frees the node's
    /// resources itself, and the slot is no longer in `engine.nodes` for it to
    /// find anyway.
    private func destroy(_ slot: Slot) {
        switch slot.backend {
        case .compute(let node, let pipeline):
            node.computePipeline = nil
            node.computeLayout = nil
            node.computeDescriptorSet = nil
            pipeline.destroy()
            node.destroyResources(engine)
        case .graphics(let node, let pipeline):
            node.pipeline = nil
            node.pipelineLayout = nil
            node.descriptorSet = nil
            pipeline.destroy()
            node.destroyResources(engine)
        }
        if let layer = slot.layer {
            recycle(layer)
        }
    }

    /// The render pass every `VertexShader` slot draws with — one per
    /// registry, made on first use; the format never varies.
    private var sharedColorPass: ColorAttachmentPass?

    private func colorPass() throws -> ColorAttachmentPass {
        if let sharedColorPass { return sharedColorPass }
        let pass = try ColorAttachmentPass(device: engine.device)
        sharedColorPass = pass
        return pass
    }

    /// How a slot's image is written.
    private enum ImageUsage {
        /// By a compute dispatch: `STORAGE`, left in GENERAL.
        case storage
        /// By a render pass: `COLOR_ATTACHMENT`, left in UNDEFINED for the
        /// pass to take from.
        case colorAttachment
    }

    /// Hand a canvas that is no longer in use back to the shared pool,
    /// emptied of its paints; past the pool's limit it is freed.
    private func recycle(_ layer: Layer) {
        renderNodes.recycle(layer)
    }

    /// The image a slot's shader writes and the composite samples.
    ///
    /// `VulkanCore.createStorageImage` does much of this, but it is a method on
    /// the `VulkanCore` bootstrap class rather than on `VulkanContext`, so it
    /// isn't reachable from the render engine. RGBA8 rather than BGRA8: storage
    /// support for it is universal, and the composite samples through a view so
    /// the channel order never has to match the swapchain's.
    private func makeImage(
        width: Int,
        height: Int,
        usage: ImageUsage
    ) throws -> (image: VkImage, view: VkImageView, memory: VkDeviceMemory) {
        var info = VkImageCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
        info.imageType = VK_IMAGE_TYPE_2D
        info.format = VK_FORMAT_R8G8B8A8_UNORM
        info.extent = VkExtent3D(width: UInt32(width), height: UInt32(height), depth: 1)
        info.mipLevels = 1
        info.arrayLayers = 1
        info.samples = VK_SAMPLE_COUNT_1_BIT
        info.tiling = VK_IMAGE_TILING_OPTIMAL
        switch usage {
        case .storage:
            info.usage = VkImageUsageFlags(
                VK_IMAGE_USAGE_STORAGE_BIT.rawValue | VK_IMAGE_USAGE_SAMPLED_BIT.rawValue
            )
        case .colorAttachment:
            info.usage = VkImageUsageFlags(
                VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue | VK_IMAGE_USAGE_SAMPLED_BIT.rawValue
            )
        }
        info.sharingMode = VK_SHARING_MODE_EXCLUSIVE
        info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED

        var image: VkImage?
        guard vkCreateImage(engine.device, &info, nil, &image) == VK_SUCCESS, let image else {
            throw ShaderError.vulkan("vkCreateImage")
        }

        var requirements = VkMemoryRequirements()
        vkGetImageMemoryRequirements(engine.device, image, &requirements)

        var allocation = VkMemoryAllocateInfo()
        allocation.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
        allocation.allocationSize = requirements.size
        allocation.memoryTypeIndex = engine.findMemoryType(
            typeFilter: requirements.memoryTypeBits,
            properties: VkMemoryPropertyFlags(VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.rawValue)
        )

        var memory: VkDeviceMemory?
        guard vkAllocateMemory(engine.device, &allocation, nil, &memory) == VK_SUCCESS,
              let memory
        else {
            vkDestroyImage(engine.device, image, nil)
            throw ShaderError.vulkan("vkAllocateMemory")
        }
        vkBindImageMemory(engine.device, image, memory, 0)

        var viewInfo = VkImageViewCreateInfo()
        viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
        viewInfo.image = image
        viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D
        viewInfo.format = VK_FORMAT_R8G8B8A8_UNORM
        viewInfo.subresourceRange = VkImageSubresourceRange(
            aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue),
            baseMipLevel: 0, levelCount: 1, baseArrayLayer: 0, layerCount: 1
        )

        var view: VkImageView?
        guard vkCreateImageView(engine.device, &viewInfo, nil, &view) == VK_SUCCESS,
              let view
        else {
            vkFreeMemory(engine.device, memory, nil)
            vkDestroyImage(engine.device, image, nil)
            throw ShaderError.vulkan("vkCreateImageView")
        }

        // UNDEFINED → GENERAL once, so the very first dispatch has somewhere
        // valid to write. `OGLShaderNode.update` starts its barrier from
        // `currentLayout`, which the node initialises to GENERAL. A colour
        // attachment needs no transition: its render pass starts from
        // UNDEFINED and clears.
        guard usage == .storage else { return (image, view, memory) }
        engine.oneTimeSubmit { cmd in
            engineImageBarrier(
                cmd,
                image: image,
                srcLayout: VK_IMAGE_LAYOUT_UNDEFINED,
                srcAccess: 0,
                srcStage: VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                dstLayout: VK_IMAGE_LAYOUT_GENERAL,
                dstAccess: VkAccessFlags(VK_ACCESS_SHADER_WRITE_BIT.rawValue),
                dstStage: VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT
            )
        }

        return (image, view, memory)
    }
}
