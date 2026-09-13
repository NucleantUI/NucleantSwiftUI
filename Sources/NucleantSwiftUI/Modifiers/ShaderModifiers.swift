//
//  ShaderModifiers.swift
//  NucleantSwiftUI
//
//  `.shader(_:)` — a view as a shader's texture input.
//
//  A `Shader` view *generates* pixels. This is the other direction: the view
//  it is applied to is drawn into a canvas of its own, and the shader reads
//  that canvas as a texture and writes the pixels that actually reach the
//  window — SwiftUI's `layerEffect`, on the engine's own terms. Every
//  CanvasBase in PyNucleantUI rendered into its own VkImage for exactly this,
//  and `OGLShaderNode` was given texture inputs for it; this is the view
//  layer reaching both.
//

extension View {

    /// Runs `function` over this view's rendered pixels.
    ///
    /// Inside the body the view is `uContent`, a `sampler2D` stored y-up like
    /// the rest of shader space, and `layer(uv)` reads the view's pixel under
    /// the current one — so `fragColor = layer(uv);` is the identity, and a
    /// distortion is `layer(uv + offset)`. ShaderToy's `iChannel0` is the
    /// same texture, so a post-processing shader written against it drops in
    /// through `ShaderFunction(shaderToy:)` unchanged.
    ///
    /// The view keeps its layout and its input: a fader under a ripple is
    /// still a fader. What the effect changes is only what is drawn, and it
    /// composites as a rectangle over the canvas — so clip *inside* the
    /// effect (`.cornerRadius(10).shader(fx)`), where the rounding lands in
    /// the texture, rather than outside it.
    ///
    /// `isEnabled: false` draws the view as usual, keeping its identity and
    /// state so an effect can be toggled without rebuilding what is under it.
    public func shader(_ function: ShaderFunction, isEnabled: Bool = true) -> some View {
        _ModifierView(content: self, key: ["shader", function, isEnabled] as [AnyHashable]) { context in
            ShaderEffectContent(
                path: context.path,
                function: isEnabled ? function : nil
            )
        }
    }

    /// `shader(_:)` with the GLSL body inline.
    public func shader(source: String, isEnabled: Bool = true) -> some View {
        shader(ShaderFunction(source), isEnabled: isEnabled)
    }
}

/// The node behind `.shader(_:)`: lays its child out exactly as it would be
/// otherwise, but routes what the child draws into a display list of its own
/// and hands that to the layer's canvas instead of the window's. The child's
/// frames are still written, so hit testing is untouched.
struct ShaderEffectContent: NodeContent {
    let path: [Int]
    /// `nil` when disabled — the child then draws straight into the window.
    let function: ShaderFunction?

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        guard let child = node.singleChild else { return }
        guard let function, rect.width > 0, rect.height > 0, let host = ShaderHost.current else {
            child.place(in: rect, proposal: proposal, context: context, into: &list)
            return
        }
        // The layer holds the whole view; what a container outside it clips
        // away is cut at the composite instead, as for a `Shader` view. The
        // inherited opacity and transform stay — they are part of how the
        // view looks, and the texture is the view.
        var inner = context
        inner.clip = nil
        inner.clipCornerRadius = 0
        var content = DisplayList()
        child.place(in: rect, proposal: proposal, context: inner, into: &content)
        host.useLayer(
            path: path,
            function: function,
            rect: rect,
            clip: context.clip,
            content: content
        )
    }
}
