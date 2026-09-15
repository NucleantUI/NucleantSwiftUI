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

/// A value handed to a shader from Swift — SwiftUI's `Shader.Argument`.
///
/// Each one is named, and the name is what the GLSL body sees:
///
/// ```swift
/// Shader(envelope, arguments: [
///     .float("gain", 1.5),               // float gain;
///     .float2("size", w, h),             // vec2  size;
///     .color("tint", .orange),           // vec4  tint;
///     .floatArray("mins", negatives),    // float mins(int i); int minsCount;
/// ])
/// ```
///
/// Scalars and vectors are plain variables; an array is read through a
/// function of its index, with its length beside it, because a storage
/// buffer's contents cannot be aliased as a GLSL array variable. Reads
/// outside the array are clamped to its ends, and an empty array reads
/// as zero.
///
/// Arguments live in a storage buffer the shader reads (binding 3), so an
/// array can be as long as it likes — a waveform's ten thousand points are
/// fine. Changing a value re-dispatches the shader, whether or not it is
/// animated; the set of names and kinds is part of the compiled pipeline's
/// identity, so keep those stable across rebuilds and vary only the values.
public enum ShaderArgument: Hashable, Sendable {
    case float(String, Double)
    case float2(String, Double, Double)
    case float3(String, Double, Double, Double)
    case float4(String, Double, Double, Double, Double)
    case color(String, Color)
    case floatArray(String, [Float])

    public var name: String {
        switch self {
        case .float(let name, _), .float2(let name, _, _), .float3(let name, _, _, _),
             .float4(let name, _, _, _, _), .color(let name, _), .floatArray(let name, _):
            return name
        }
    }

    /// The GLSL declaration this argument becomes.
    var glslType: String {
        switch self {
        case .float:      return "float"
        case .float2:     return "vec2"
        case .float3:     return "vec3"
        case .float4:     return "vec4"
        case .color:      return "vec4"
        case .floatArray: return "array"
        }
    }

    /// The numbers, as they are packed into the buffer. A color is resolved
    /// for `scheme` first, so a dynamic one reaches the shader in the
    /// appearance the view is drawn under.
    func values(for scheme: ColorScheme) -> [Float] {
        switch self {
        case .float(_, let x):              return [Float(x)]
        case .float2(_, let x, let y):      return [Float(x), Float(y)]
        case .float3(_, let x, let y, let z): return [Float(x), Float(y), Float(z)]
        case .float4(_, let x, let y, let z, let w): return [Float(x), Float(y), Float(z), Float(w)]
        case .color(_, let color):
            let resolved = color.resolved(for: scheme)
            return [Float(resolved.red), Float(resolved.green), Float(resolved.blue), Float(resolved.alpha)]
        case .floatArray(_, let array):     return array
        }
    }
}

/// A list of arguments, as the pipeline consumes it: the part that shapes
/// the compiled shader (names and kinds) apart from the part that only fills
/// a buffer (the numbers).
struct ShaderArguments: Equatable {
    /// `name:type` per argument — the GLSL declarations depend on nothing else.
    let signature: String
    let declarations: [(name: String, type: String)]
    /// Two floats per argument (offset into `packed`, element count), then
    /// every argument's values in order. `std430` gives a `float[]` a 4-byte
    /// stride, so this is the buffer byte for byte.
    let packed: [Float]

    init(_ arguments: [ShaderArgument], colorScheme: ColorScheme = .light) {
        declarations = arguments.map { ($0.name, $0.glslType) }
        signature = declarations.map { "\($0.name):\($0.type)" }.joined(separator: ",")
        var header: [Float] = []
        var data: [Float] = []
        var offset = arguments.count * 2
        for argument in arguments {
            let values = argument.values(for: colorScheme)
            header.append(Float(offset))
            header.append(Float(values.count))
            data.append(contentsOf: values)
            offset += values.count
        }
        packed = header + data
    }

    static let none = ShaderArguments([])

    var isEmpty: Bool { declarations.isEmpty }

    static func == (lhs: ShaderArguments, rhs: ShaderArguments) -> Bool {
        lhs.signature == rhs.signature && lhs.packed == rhs.packed
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
    let arguments: [ShaderArgument]

    public init(_ function: ShaderFunction, arguments: [ShaderArgument] = []) {
        self.function = function
        self.arguments = arguments
    }

    public init(source: String, arguments: [ShaderArgument] = []) {
        self.function = ShaderFunction(source)
        self.arguments = arguments
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
            function: function,
            arguments: ShaderArguments(arguments, colorScheme: context.environment.colorScheme)
        ))
    }
}

/// Reserves a GPU slot and reports where it should composite. Emits no draw
/// commands of its own — its pixels arrive through the engine, not the canvas.
struct ShaderContent: NodeContent {
    let path: [Int]
    let function: ShaderFunction
    let arguments: ShaderArguments

    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        proposal.replacingUnspecifiedDimensions()
    }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        guard rect.width > 0, rect.height > 0 else { return }
        ShaderHost.current?.use(
            path: path,
            function: function,
            arguments: arguments,
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
