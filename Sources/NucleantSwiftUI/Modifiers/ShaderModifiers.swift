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
//  One modifier, whichever kind of function it is handed. A function with a
//  vertex stage gets the same texture at the same binding under the same name
//  (`uContent`, read with `layer(uv)`); its fragment stage runs over the
//  geometry the vertex stage places instead of over every pixel. The only
//  extra it takes is what a graphics draw cannot infer — how many vertices
//  and instances.
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
    /// A `function` with a vertex stage — `isGraphics` — is drawn instead of
    /// dispatched, and everything above still holds: same texture, same name,
    /// same `layer(uv)`, same `ShaderArgument`s. What changes is which pixels
    /// the fragment body runs over. A per-pixel function covers the rect, so
    /// leaving `fragColor` alone leaves the view on screen; a vertex stage
    /// shades only what its triangles cover, and the rest of the rect is
    /// cleared. So a glow drawn over a view is one more instance, not one
    /// fewer:
    ///
    /// ```swift
    /// view.shader(glow, arguments: [.float4Array("touches", touches)],
    ///             vertices: 6, instances: touches.count + 1)
    /// ```
    ///
    /// with instance 0 the full-view quad returning `layer(uv)` — the
    /// identity — and the rest the glows. `vertices` and `instances` are
    /// ignored by a per-pixel function, and are per-frame values otherwise:
    /// changing them redraws without a rebuild.
    ///
    /// `isEnabled: false` draws the view as usual, keeping its identity and
    /// state so an effect can be toggled without rebuilding what is under it.
    ///
    /// `backdrop: true` draws what was already painted under this view's
    /// rect — everything earlier in paint order, in the same window or
    /// layer — into the texture before the view itself, so `layer(uv)`
    /// reads the view *and its background*: a glass or blur over whatever is
    /// beneath. The window's clear colour and other shader nodes are not
    /// paint, so they are not in it.
    ///
    /// `arguments` are the shader's named inputs — see `ShaderArgument`.
    ///
    /// - Parameters:
    ///   - vertices: with a vertex stage, vertices per instance; 6 is a quad
    ///     as two triangles.
    ///   - instances: how many times the vertex stage runs over them.
    public func shader(
        _ function: ShaderFunction,
        arguments: [ShaderArgument] = [],
        vertices: Int = 6,
        instances: Int = 1,
        backdrop: Bool = false,
        isEnabled: Bool = true
    ) -> some View {
        let draw = ShaderDraw(vertices: max(0, vertices), instances: max(0, instances))
        return _ModifierView(
            content: self,
            key: ["shader", function, draw, arguments, backdrop, isEnabled] as [AnyHashable]
        ) { context in
            ShaderEffectContent(
                path: context.path,
                function: isEnabled ? function : nil,
                draw: draw,
                arguments: ShaderArguments(arguments, colorScheme: context.environment.colorScheme),
                backdrop: backdrop
            )
        }
    }

    /// `shader(_:)` with the GLSL body inline.
    public func shader(
        source: String,
        arguments: [ShaderArgument] = [],
        backdrop: Bool = false,
        isEnabled: Bool = true
    ) -> some View {
        shader(ShaderFunction(source), arguments: arguments, backdrop: backdrop, isEnabled: isEnabled)
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
    /// What one draw covers, when `function` has a vertex stage.
    let draw: ShaderDraw
    let arguments: ShaderArguments
    /// Seed the layer with what is already painted under the view.
    let backdrop: Bool

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
        // The texture is the view: a drawing group inside draws into it.
        inner.flattensRenderNodes = true
        // The list so far is everything painted beneath this view; the
        // layer's canvas is only the view's rect, so the rest is clipped
        // away by ThorVG.
        var content = backdrop ? list : DisplayList()
        child.place(in: rect, proposal: proposal, context: inner, into: &content)
        host.useLayer(
            path: path,
            function: function,
            draw: draw,
            arguments: arguments,
            rect: rect,
            clip: context.compositeClip,
            content: content
        )
        host.boundaries.noteNested(at: list.commands.count, rect: context.compositeClip.map { rect.intersection($0) } ?? rect)
    }
}
