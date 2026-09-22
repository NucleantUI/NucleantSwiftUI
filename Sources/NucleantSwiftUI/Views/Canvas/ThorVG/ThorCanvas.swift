//
//  ThorCanvas.swift
//  NucleantSwiftUI
//
//  Views that draw straight into a ThorVG canvas of their own: a render node
//  per view, filled by the author's paints rather than by a display list.
//
import NucleantThorVG

/// A view drawn by two closures against its own ThorVG canvas.
///
/// ```swift
/// ThorCanvas(
///     onInit: { context, size in          // once per node: add the paints
///         let rect = TCShape()
///         rect.append_rect(pos: .zero, size: size)
///         rect.set_fill_color(r: 255, g: 255, b: 255)
///         context.add(shape: rect)
///         shapes.rect = rect
///     },
///     renderer: { context, size in        // whenever what it read changed,
///         shapes.rect.append_rect(…)      // or the size did
///     }
/// )
/// ```
///
/// The node is the view's for as long as the view stands: `onInit` runs when
/// the node is created, on a canvas holding nothing, and `renderer` after it
/// — then again on every rebuild of this view and on every resize (the
/// canvas is retargeted, the paints survive), after which the node is
/// rasterized. A `@State` read through a captured binding, or an
/// `@Observable` property read, inside `renderer` makes this view depend on
/// it: a change rebuilds this view alone and runs `renderer` again. Nothing
/// read changes ⇒ nothing runs ⇒ the node keeps its image.
///
/// `id` is the "start over" handle: a different value is a new node — a
/// fresh canvas, `onInit` again. Sizes are canvas pixels; the view takes
/// whatever space it is offered, so give it a `.frame` — one no bigger than
/// the window, which is as large as a node's image can be composited.
@View
public struct ThorCanvas {
    let nodeID: Int
    let onInit: (borrowing ThorContext, SIMD2<Float>) -> Void
    let renderer: (borrowing ThorContext, SIMD2<Float>) -> Void

    public init(
        onInit: @escaping (borrowing ThorContext, SIMD2<Float>) -> Void,
        renderer: @escaping (borrowing ThorContext, SIMD2<Float>) -> Void,
        _viewID: ViewID = #viewID
    ) {
        self.nodeID = 0
        self.onInit = onInit
        self.renderer = renderer
        self._viewID = _viewID
    }

    public init<ID: Hashable>(
        id: ID,
        onInit: @escaping (borrowing ThorContext, SIMD2<Float>) -> Void,
        renderer: @escaping (borrowing ThorContext, SIMD2<Float>) -> Void,
        _viewID: ViewID = #viewID
    ) {
        self.nodeID = id.hashValue
        self.onInit = onInit
        self.renderer = renderer
        self._viewID = _viewID
    }

    public var body: Never { bodyUnavailable() }
}

extension ThorCanvas: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        ViewNode(content: ThorCanvasContent(
            key: RenderNodeKey(path: context.path, identity: context.viewIdentity, id: nodeID),
            path: context.path,
            onInit: onInit,
            render: renderer
        ))
    }
}

/// Reserves a render node and hands the author's closures to it at `place`.
/// Emits no draw commands of its own — its pixels arrive through the engine,
/// not the enclosing canvas.
struct ThorCanvasContent: NodeContent {
    let key: RenderNodeKey
    let path: [Int]
    let onInit: (borrowing ThorContext, SIMD2<Float>) -> Void
    let render: (borrowing ThorContext, SIMD2<Float>) -> Void
    /// Which build this content came from. A rebuilt view gets a new
    /// content and so a new generation; the node runs `render` again when
    /// it sees one it has not run for.
    let generation: Int = ThorCanvasContent.nextGeneration()

    private static var generations = 0

    private static func nextGeneration() -> Int {
        generations += 1
        return generations
    }

    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        proposal.replacingUnspecifiedDimensions()
    }

    /// The node for `key`: the author fills its canvas.
    ///
    /// `onInit` runs once per node, on a canvas holding nothing; `render`
    /// runs after it, and again whenever `generation` — bumped each time the
    /// view is rebuilt — or the frame size differs from the last run, and
    /// the node is rasterized. `render` runs with its reads attributed to
    /// `path`, the view's own, so a `@State` or `@Observable` read inside
    /// it dirties that view alone — the next frame rebuilds just it, and the
    /// closure runs again with the new values.
    func place(node viewNode: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        guard rect.width > 0, rect.height > 0, let host = ShaderHost.current else { return }
        // Inside a capture there is nothing to flatten into — the author's
        // paints live on the node — so the node is used regardless; it is
        // composited over the capture, as a `Shader` view inside one is.
        let clip = context.compositeClip
        guard let node = host.renderNodes.canvasNode(for: key, rect: rect) else { return }
        let scale = host.renderNodes.scale
        node.place(rect: rect, clip: clip, scale: scale)
        host.renderNodes.composite(node.container, at: host.renderNodes.nextPaintOrder())
        host.boundaries.noteNested(at: list.commands.count, rect: clip.map { rect.intersection($0) } ?? rect)

        // Canvas pixels: the frame's size, not the image's — the slack past
        // the frame is cut by the scissor and is nobody's to draw in.
        let size = SIMD2<Float>(Float(rect.width * scale), Float(rect.height * scale))
        var rasterize = false
        if !node.initialized {
            node.initialized = true
            onInit(node.thorContext, size)
            rasterize = true
        }
        if node.generation != generation || node.renderedSize != rect.size {
            // The reads about to happen replace the last run's.
            for storage in node.reads {
                storage.readers.removeValue(forKey: node.readerPath)
            }
            node.readerPath = path
            DependencyTracker.shared.push(path)
            trackingObservation(at: path) {
                render(node.thorContext, size)
            }
            DependencyTracker.shared.pop()
            node.reads = DependencyTracker.shared.takeReads(for: path)
            node.generation = generation
            node.renderedSize = rect.size
            rasterize = true
        }
        if rasterize { node.rasterize() }
    }
}



//@MainActor


func getThorCanvas(id: Int) -> OpaquePointer {
    fatalError("just for testing")
}
