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

import CVulkan
import VulkanCore
import NucleantVulkan

@MainActor
final class ShaderSlotRegistry {

    /// One live shader view's GPU state.
    final class Slot {
        let node: OGLShaderNode<NucleantRenderNode>
        let container: NucleantRenderNode
        let pipeline: ShaderPipeline
        /// Pixel size the node was built at — a resize rebuilds it.
        var width: Int
        var height: Int
        /// Source it was compiled from; a change recompiles.
        var source: String
        /// Seen during the current layout pass. Anything not seen has left
        /// the tree and is torn down.
        var used = true
        /// Seconds since this shader appeared, fed to the `time` uniform.
        var elapsed: Double = 0
        /// Frames drawn since it appeared — ShaderToy's `iFrame`.
        var frame: Int = 0

        init(
            node: OGLShaderNode<NucleantRenderNode>,
            container: NucleantRenderNode,
            pipeline: ShaderPipeline,
            width: Int,
            height: Int,
            source: String
        ) {
            self.node = node
            self.container = container
            self.pipeline = pipeline
            self.width = width
            self.height = height
            self.source = source
        }
    }

    private unowned let engine: NucleantRenderEngine

    /// Keyed by the view's structural path — the same identity `@State` uses,
    /// so a shader keeps its pipeline across rebuilds and loses it only when
    /// the view itself goes away.
    private var slots: [[Int]: Slot] = [:]

    /// Backing-store pixels per point.
    var scale: Double = 1

    /// Slots detached from the engine but not yet freed — see `endPass`.
    private var pendingDestroy: [Slot] = []

    init(engine: NucleantRenderEngine) {
        self.engine = engine
    }

    // MARK: - Layout-pass lifecycle

    func beginPass() {
        for slot in slots.values { slot.used = false }
    }

    /// Called from `ShaderContent.place`: make sure a slot exists for this
    /// view, at this size, and put it at this rect.
    func use(path: [Int], function: ShaderFunction, rect: Rect, clip: Rect?) {
        let source = function.source
        let pixelWidth = max(1, Int((rect.width * scale).rounded()))
        let pixelHeight = max(1, Int((rect.height * scale).rounded()))

        var previous: Slot?
        if let existing = slots[path] {
            existing.used = true
            // Both rects are read fresh by the engine every frame, so moving or
            // re-clipping a shader view is free; only a *resize* or a source
            // change needs the GPU objects rebuilt.
            place(existing, rect: rect, clip: clip)
            if existing.width == pixelWidth,
               existing.height == pixelHeight,
               existing.source == source {
                return
            }
            // Retire it the way `endPass` does — detach now, free at the top
            // of the next frame. Freeing here, mid-frame, is the same
            // use-after-free §8 fixed for teardown: command buffers still in
            // flight reference the image, and the old container would stay
            // in `engine.nodes` for the composite pass to draw from freed
            // memory. Seen as a segfault inside MoltenVK on maximizing a
            // window with a shader on screen.
            retire(existing)
            slots[path] = nil
            previous = existing
        }

        guard let slot = makeSlot(
            function: function,
            width: pixelWidth,
            height: pixelHeight
        ) else {
            return
        }
        // Same view, new image: the animation continues rather than restarts.
        if let previous {
            slot.elapsed = previous.elapsed
            slot.frame = previous.frame
        }
        place(slot, rect: rect, clip: clip)
        slots[path] = slot
    }

    /// Point a slot at its frame, and at whatever its container allows it to
    /// draw within.
    private func place(_ slot: Slot, rect: Rect, clip: Rect?) {
        slot.container.compositeRect = SIMD4(
            rect.minX * scale, rect.minY * scale,
            rect.width * scale, rect.height * scale
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
            fputs(String(
                format: "[layout] shader  rect x=%7.2f y=%7.2f w=%7.2f h=%7.2f  scissor %@\n",
                rect.minX, rect.minY, rect.width, rect.height,
                s.map { String(format: "x=%.2f y=%.2f w=%.2f h=%.2f", $0.x, $0.y, $0.z, $0.w) }
                    ?? "none"
            ), stderr)
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
        for (path, slot) in slots where !slot.used {
            retire(slot)
            slots[path] = nil
        }
    }

    /// Take a slot out of the engine now and queue its GPU objects for
    /// `releasePending`. Drops the engine's per-slot descriptor set, pool
    /// and readable marker — `remove(id:)` would do this too, but it also
    /// frees the node, which is exactly what is being deferred.
    private func retire(_ slot: Slot) {
        engine.nodes.removeAll { $0.id == slot.container.id }
        engine.invalidateComposite(id: slot.container.id)
        pendingDestroy.append(slot)
    }

    // MARK: - Per frame

    /// Advance every live shader's clock and hand it to the GPU, then flag the
    /// slots for redraw.
    ///
    /// Shaders are animated by definition, so unlike the ThorVG canvas these
    /// slots *do* want a dispatch every frame — that is the one thing on screen
    /// which is never idle. Returns true when there is at least one, so the
    /// window knows the frame was not free.
    @discardableResult
    func tick(_ delta: Double, pointer: Point) -> Bool {
        releasePending()
        guard !slots.isEmpty else { return false }
        for slot in slots.values {
            slot.elapsed += delta
            slot.frame += 1
            slot.pipeline.update(ShaderUniforms(
                time: Float(slot.elapsed),
                timeDelta: Float(delta),
                frame: Float(slot.frame),
                resolutionX: Float(slot.width),
                resolutionY: Float(slot.height),
                mouseX: Float(pointer.x * scale),
                mouseY: Float(pointer.y * scale),
                // zw is ShaderToy's "position while pressed"; there is no
                // press tracking on this path yet, so it mirrors xy.
                mouseClickX: Float(pointer.x * scale),
                mouseClickY: Float(pointer.y * scale)
            ))
            slot.container.needsRender = true
        }
        return true
    }

    func destroyAll() {
        for slot in slots.values {
            retire(slot)
        }
        slots.removeAll()
        releasePending()
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

    private func makeSlot(function: ShaderFunction, width: Int, height: Int) -> Slot? {
        do {
            let image = try makeStorageImage(width: width, height: height)
            let node = OGLShaderNode<NucleantRenderNode>(
                width: UInt32(width),
                height: UInt32(height),
                image: image.image,
                imageView: image.view,
                memory: image.memory,
                storageCapable: true
            )
            let pipeline = try ShaderPipeline(
                engine: engine,
                imageView: image.view,
                source: ShaderSource.compute(
                    functions: function.functions,
                    body: function.body
                )
            )
            node.computePipeline = pipeline.pipeline
            node.computeLayout = pipeline.pipelineLayout
            node.computeDescriptorSet = pipeline.descriptorSet
            node.dirty = true

            let container = NucleantRenderNode(
                id: Int.random(in: Int.min...Int.max),
                context: .shader(node)
            )
            container.observeContext()
            engine.append(container)

            return Slot(
                node: node,
                container: container,
                pipeline: pipeline,
                width: width,
                height: height,
                source: function.source
            )
        } catch {
            fputs("NucleantSwiftUI: shader node build (\(width)x\(height)) failed: \(error)\n", stderr)
            return nil
        }
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
        slot.node.computePipeline = nil
        slot.node.computeLayout = nil
        slot.node.computeDescriptorSet = nil
        slot.pipeline.destroy()
        slot.node.destroyResources(engine)
    }

    /// The image the compute shader writes and the composite samples.
    ///
    /// `VulkanCore.createStorageImage` does exactly this, but it is a method on
    /// the `VulkanCore` bootstrap class rather than on `VulkanContext`, so it
    /// isn't reachable from the render engine. RGBA8 rather than BGRA8: storage
    /// support for it is universal, and the composite samples through a view so
    /// the channel order never has to match the swapchain's.
    private func makeStorageImage(
        width: Int,
        height: Int
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
        info.usage = VkImageUsageFlags(
            VK_IMAGE_USAGE_STORAGE_BIT.rawValue | VK_IMAGE_USAGE_SAMPLED_BIT.rawValue
        )
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
        // `currentLayout`, which the node initialises to GENERAL.
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
