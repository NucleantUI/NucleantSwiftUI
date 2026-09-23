//
//  VertexShaderView.swift
//  NucleantSwiftUI
//

/// The older spelling of a vertex + fragment `ShaderFunction`.
///
/// There is one function type: `ShaderFunction(varyings:vertex:fragment:)`,
/// or a PyShader module defining both stages, is a pair, and `isGraphics`
/// says so — which is what lets `.shader(_:)` take either kind.
public typealias VertexShaderFunction = ShaderFunction

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
    public init(
        _ function: VertexShaderFunction,
        vertices: Int = 6,
        instances: Int = 1,
        arguments: [ShaderArgument] = [],
        _viewID: ViewID = #viewID
    ) {
        self.function = function
        self.vertices = vertices
        self.instances = instances
        self.arguments = arguments
        self._viewID = _viewID
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
struct ShaderDraw: Hashable {
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
