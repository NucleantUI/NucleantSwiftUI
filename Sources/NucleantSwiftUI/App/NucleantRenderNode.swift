//
//  NucleantRenderNode.swift
//  NucleantSwiftUI
//
//  The engine slot type for this framework. `VulkanRenderEngine` is generic
//  over its container node so each host picks its own set of backends;
//  PyNucleantUI's carries five cases (thor / skia / pixel / py buffer / group)
//  because Python code can ask for any of them. A SwiftUI tree draws through
//  ThorVG only, so there is one case — and no dependency on PyNucleantUI (and
//  therefore none on Python) is needed to get it.
//

import CVulkan
import NucleantVulkan
import NucleantThorVG

public final class NucleantRenderNode: RenderContainerNode, @unchecked Sendable {

    public enum Context: RenderNodeContext {
        /// The window-filling 2D canvas every view draws into.
        case thor(ThorShaderNode<NucleantRenderNode>)
        /// One `Shader` view's own compute-written image, composited into the
        /// view's rect. A vector canvas can't run a fragment shader, so these
        /// get their own slot rather than sharing the canvas.
        case shader(OGLShaderNode<NucleantRenderNode>)
        /// One `VertexShader` view's image, drawn by a vertex + fragment
        /// pipeline and composited the same way.
        case vertexShader(VertFragShaderNode<NucleantRenderNode>)
    }

    public let id: Int
    public let context: Context

    /// Whether the canvas needs rasterizing again. Starts `true` so a fresh
    /// slot draws its first frame unprompted, and is cleared by `update` once
    /// it has — see the note there.
    public var needsRender: Bool = true

    /// Where this slot composites, in swapchain pixels. `nil` fills the
    /// window — the canvas slot. A `Shader` slot carries its view's placed
    /// frame, rewritten by `ShaderSlotRegistry` on every layout pass; the
    /// engine reads it fresh each frame, so moving a shader view costs
    /// nothing.
    public var compositeRect: SIMD4<Double>?

    /// The clip a `Shader` view inherited from its container — a `ScrollView`,
    /// a `.clipped()`. Canvas-drawn views get clipped inside the display list;
    /// a shader slot never goes through it, so its clip has to reach the
    /// engine as a scissor instead.
    public var compositeScissor: SIMD4<Double>?

    /// False for the canvas behind a `.shader(_:)` effect: the view's own
    /// content is drawn into it and the effect's compute node samples it, but
    /// it never reaches the swapchain itself — only the effect's output does.
    /// The engine skips a slot with no image view to composite, and leaves its
    /// size alone on a window resize.
    public var compositesToWindow: Bool = true

    public init(id: Int, context: Context) {
        self.id = id
        self.context = context
    }

    public func observeContext() {
        switch context {
        case .thor(let node):
            observe(node)
        case .shader(let node):
            observe(node)
        case .vertexShader(let node):
            observe(node)
        }
    }

    public func update(engine: Engine, cmd: VkCommandBuffer) {
        guard needsRender else { return }
        switch context {
        case .thor(let node):
            node.update(engine, slot: self, cmd: cmd)
        case .shader(let node):
            node.update(engine, slot: self, cmd: cmd)
        case .vertexShader(let node):
            node.update(engine, slot: self, cmd: cmd)
        }
        // Cleared here, so an idle frame costs nothing: `canvas.draw()` +
        // `sync()` re-rasterize the whole scene, and re-running them for an
        // unchanged tree is pure waste. The composite pass is unaffected — it
        // walks every slot and samples the image regardless of this flag, so
        // the last-drawn frame keeps being presented.
        //
        // Re-arming is `HostingWindow`'s job (`markNeedsRedraw`), not the
        // Observation chain's: that only fires on a *change* to `node.dirty`,
        // and a repaint while `dirty` is already `true` would post no
        // notification at all — the canvas would then never redraw again.
        needsRender = false
    }

    public func destroyResources(engine: Engine) {
        switch context {
        case .thor(let node):
            node.destroyResources(engine)
        case .shader(let node):
            node.destroyResources(engine)
        case .vertexShader(let node):
            node.destroyResources(engine)
        }
    }

    public func getImageView() -> VkImageView? {
        guard compositesToWindow else { return nil }
        switch context {
        case .thor(let node):
            return node.imageView
        case .shader(let node):
            return node.imageView
        case .vertexShader(let node):
            return node.imageView
        }
    }

    /// The canvas slot fills the window, so it has to follow the swapchain —
    /// nothing else tracks the size for it. A shader slot, and the canvas
    /// behind a `.shader` effect, are sized by their view's frame instead, and
    /// `ShaderSlotRegistry` rebuilds them on a change.
    public func resizeToFitWindow(width: Int, height: Int, engine: Engine) {
        switch context {
        case .thor(let node) where compositesToWindow && compositeRect == nil:
            engine.resizeThorNode(node, id: id, width: width, height: height)
        case .thor, .shader, .vertexShader:
            break
        }
    }
}

/// The engine this framework builds — named once so the window and host don't
/// repeat the generic parameter.
public typealias NucleantRenderEngine = VulkanRenderEngine<NucleantRenderNode>
