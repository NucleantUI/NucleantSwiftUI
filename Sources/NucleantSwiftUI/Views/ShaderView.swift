//
//  ShaderView.swift
//  NucleantSwiftUI
//

/// A GLSL fragment-style shader, compiled once and reused.
///
/// The body is written in the terms TouchBay's shader library uses — `uv`,
/// `fragCoord`, `time`, `resolution` and `mouse` are in scope, and it assigns
/// `fragColor`:
///
/// ```swift
/// let plasma = ShaderFunction("""
///     float v = sin(uv.x * 10.0 + time)
///             + sin((uv.y * 10.0 + time) * 0.5);
///     fragColor = vec4(vec3(0.5 + 0.5 * sin(3.14159 * v)), 1.0);
/// """)
/// ```
///
/// Source beginning with `#version` is taken as a complete GLSL 450 compute
/// shader instead, and must declare `local_size_x = 8, local_size_y = 8` plus
/// the bindings the wrapper would have (0: `writeonly image2D`, 1: the
/// `Uniforms` block).
public struct ShaderFunction: Hashable, Sendable {

    /// Declarations emitted at file scope, before `main` — helper functions,
    /// constants, structs. GLSL has no nested function definitions, so
    /// anything a body *calls* has to live here rather than in the body.
    /// TouchBay's shader library splits its sources the same way
    /// (`FragShaderFunction(functions:main:)`).
    public let functions: String

    /// The per-pixel body, inlined into `main`.
    public let body: String

    public init(functions: String = "", _ body: String) {
        self.functions = functions
        self.body = body
    }

    /// Wraps an unmodified ShaderToy shader.
    ///
    /// Paste the whole thing — helper functions and its
    /// `void mainImage(out vec4 fragColor, in vec2 fragCoord)` — and it is
    /// emitted at file scope and called once per pixel. `iTime`, `iTimeDelta`,
    /// `iFrame`, `iResolution` and `iMouse` are already declared with
    /// ShaderToy's own types, so most shaders compile untouched:
    ///
    /// ```swift
    /// ShaderFunction(shaderToy: """
    ///     void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    ///         vec2 uv = fragCoord / iResolution.xy;
    ///         fragColor = vec4(uv, 0.5 + 0.5 * sin(iTime), 1.0);
    ///     }
    /// """)
    /// ```
    ///
    /// What will *not* compile, because the target is a compute shader rather
    /// than a fragment one: `iChannel0`…`iChannel3` and any `texture()` call
    /// against them, and the screen-space derivatives (`fwidth`, `dFdx`,
    /// `dFdy`). A shader using those needs reworking, not just wrapping.
    /// `gl_FragCoord` is likewise absent — `mainImage`'s own `fragCoord`
    /// parameter carries the same value.
    public init(shaderToy source: String) {
        self.functions = source
        self.body = "mainImage(fragColor, fragCoord);"
    }

    /// Identity for the compiled-pipeline cache: both halves, since either
    /// changing means a recompile.
    var source: String { functions.isEmpty ? body : functions + "\n" + body }

    /// Whether the shader reads anything that changes between frames.
    ///
    /// A source that never mentions the clock or the pointer produces the
    /// same pixels every dispatch, so it is dispatched once — and, under
    /// `.shader(_:)`, again only when the view beneath it is repainted. A
    /// textual test, so a helper that takes `time` as a parameter counts too;
    /// erring towards "animated" only costs dispatches.
    var isAnimated: Bool {
        let clocks: Set<Substring> = ["time", "iTime", "iTimeDelta", "iFrame", "mouse", "iMouse"]
        var identifier = Substring()
        for character in source {
            if character.isLetter || character.isNumber || character == "_" {
                identifier.append(character)
            } else {
                if clocks.contains(identifier) { return true }
                identifier = Substring()
            }
        }
        return clocks.contains(identifier)
    }
}

/// A view whose pixels are produced by a compute shader on the GPU.
///
/// It takes whatever space it is offered, so give it a `.frame`. Unlike every
/// other view here it does not draw into the shared ThorVG canvas — it gets its
/// own image, composited into its rect. That means a shader view is never free:
/// it dispatches every frame, which is the point of it.
@View
public struct Shader: View {
    let function: ShaderFunction

    public init(_ function: ShaderFunction) {
        self.function = function
    }

    public init(source: String) {
        self.function = ShaderFunction(source)
    }

    public var body: Never { bodyUnavailable() }
}

extension Shader: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        ViewNode(content: ShaderContent(
            // The structural path is the slot's identity, so the compiled
            // pipeline survives rebuilds and is torn down only when this view
            // actually leaves the tree.
            path: context.path,
            function: function
        ))
    }
}

/// Reserves a GPU slot and reports where it should composite. Emits no draw
/// commands of its own — its pixels arrive through the engine, not the canvas.
struct ShaderContent: NodeContent {
    let path: [Int]
    let function: ShaderFunction

    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        proposal.replacingUnspecifiedDimensions()
    }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        guard rect.width > 0, rect.height > 0 else { return }
        ShaderHost.current?.use(
            path: path,
            function: function,
            rect: rect,
            clip: context.clip
        )
    }
}

/// The registry the current layout pass should talk to.
///
/// `place` is deep inside the layout walk and has no route to the window, and
/// threading a registry through `DrawContext` would put a GPU concern into the
/// one type every leaf copies. A single current-host reference, set around the
/// pass by `ViewHost`, keeps it out of the layout types entirely.
@MainActor
enum ShaderHost {
    static var current: ShaderSlotRegistry?
}
