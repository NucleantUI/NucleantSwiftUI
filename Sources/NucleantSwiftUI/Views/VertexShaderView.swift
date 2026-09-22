//
//  VertexShaderView.swift
//  NucleantSwiftUI
//

/// A vertex + fragment shader pair, compiled once and reused.
///
/// Where `ShaderFunction` runs a body once per pixel, this runs `vertex` once
/// per vertex of every instance the view is asked to draw, and `fragment`
/// once per pixel each triangle covers. There are no vertex buffers: the
/// vertex stage places its geometry from `gl_VertexIndex`, `gl_InstanceIndex`
/// and whatever `ShaderArgument`s the view was given, which is what makes
/// "one quad per touch, from an array of touches" a single draw call.
///
/// The GLSL form takes the two bodies and the varyings that connect them —
/// declared once, as `type name;` pairs, and usable as plain variables in both
/// stages (`flat` for integer types):
///
/// ```swift
/// let glow = VertexShaderFunction(
///     varyings: "vec2 local; float seed;",
///     vertex: """
///         int t = gl_InstanceIndex * 3;
///         vec2 corner = QUAD[gl_VertexIndex];
///         vec2 centre = vec2(touches(t), touches(t + 1));
///         gl_Position = vec4((centre + corner * 0.25) * 2.0 - 1.0, 0.0, 1.0);
///         local = corner * 0.5 + 0.5;
///         seed = touches(t + 2);
///     """,
///     fragment: """
///         float d = distance(local, vec2(0.5));
///         fragColor = vec4(vec3(fract(seed + time)), smoothstep(0.5, 0.0, d));
///     """)
/// ```
///
/// `time`, `resolution` and `mouse` are in scope in both stages, as are the
/// arguments; `uv` and `fragCoord` in the fragment stage. Shader space is
/// y-up as everywhere else: `gl_Position` is written as in OpenGL and flipped
/// into Vulkan's clip space by the wrapper.
///
/// The PyShader form is one module with `vertex` returning a `class` whose
/// first field is the `float4` position and whose other fields are the
/// varyings, taken by `fragment` by name:
///
/// ```swift
/// let glow = VertexShaderFunction(pyshader: """
///     class V:
///         position: float4
///         local: float2
///         seed: float
///
///     def vertex(vertex_index: int, instance_index: int, touches: FloatArray) -> V:
///         ...
///
///     def fragment(local: float2, seed: float, time: float) -> float4:
///         ...
/// """)
/// ```
public struct VertexShaderFunction: Hashable, Sendable {

    public let language: ShaderFunction.Language

    /// File-scope declarations shared by both stages — helpers, constants.
    /// Empty for PyShader, whose source is one module.
    public let functions: String
    /// `type name;` pairs the vertex stage writes and the fragment stage reads.
    public let varyings: String
    /// The vertex body — or, for PyShader, the whole module.
    public let vertex: String
    /// The fragment body; empty for PyShader.
    public let fragment: String

    public init(functions: String = "", varyings: String = "", vertex: String, fragment: String) {
        self.language = .glsl
        self.functions = functions
        self.varyings = varyings
        self.vertex = vertex
        self.fragment = fragment
    }

    public init(pyshader source: String) {
        self.language = .pyshader
        self.functions = ""
        self.varyings = ""
        self.vertex = source
        self.fragment = ""
    }

    /// Identity for the compiled-pipeline cache.
    var source: String {
        switch language {
        case .glsl:
            return [functions, varyings, vertex, fragment].joined(separator: "\n")
        case .pyshader:
            return "#pyshader\n" + vertex
        }
    }

    /// Whether either stage reads anything that changes between frames —
    /// same textual test as `ShaderFunction.isAnimated`.
    var isAnimated: Bool {
        ShaderFunction.mentionsClock(source)
    }
}

/// A view whose pixels are produced by a vertex + fragment pipeline on the GPU.
///
/// Draws `vertices` vertices `instances` times into its own image, which is
/// composited into its rect — the same slot a `Shader` view gets, with a
/// render pass in place of the compute dispatch. It takes whatever space it is
/// offered, so give it a `.frame`.
///
/// `vertices` and `instances` are per-frame values: changing them redraws
/// without a rebuild, so a particle system varies `instances` freely.
@View
public struct VertexShader: View {
    let function: VertexShaderFunction
    let vertices: Int
    let instances: Int
    let arguments: [ShaderArgument]

    /// - Parameters:
    ///   - vertices: vertices per instance; 6 is a quad as two triangles.
    ///   - instances: how many times the vertex stage runs over them.
    public init(_ function: VertexShaderFunction, vertices: Int = 6, instances: Int = 1, arguments: [ShaderArgument] = []) {
        self.function = function
        self.vertices = vertices
        self.instances = instances
        self.arguments = arguments
    }

    public var body: Never { bodyUnavailable() }
}

extension VertexShader: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        ViewNode(content: VertexShaderContent(
            path: context.path,
            function: function,
            draw: ShaderDraw(vertices: max(0, vertices), instances: max(0, instances)),
            arguments: ShaderArguments(arguments, colorScheme: context.environment.colorScheme)
        ))
    }
}

/// What one `VertexShader` draw covers.
struct ShaderDraw: Equatable {
    let vertices: Int
    let instances: Int
}

/// Reserves a GPU slot and reports where it should composite — the graphics
/// twin of `ShaderContent`.
struct VertexShaderContent: NodeContent {
    let path: [Int]
    let function: VertexShaderFunction
    let draw: ShaderDraw
    let arguments: ShaderArguments

    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        proposal.replacingUnspecifiedDimensions()
    }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        guard rect.width > 0, rect.height > 0, let host = ShaderHost.current else { return }
        host.useGraphics(
            path: path,
            function: function,
            draw: draw,
            arguments: arguments,
            rect: rect,
            clip: context.compositeClip
        )
        host.boundaries.noteNested(at: list.commands.count, rect: context.compositeClip.map { rect.intersection($0) } ?? rect)
    }
}
