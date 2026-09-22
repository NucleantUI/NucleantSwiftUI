//
//  ThorCanvasRender.swift
//  NucleantSwiftUI
//
import NucleantThorVG

/// `ThorCanvas` with the paints and the two callbacks on an object.
///
/// ```swift
/// ThorCanvasRender(context: instructions)   // a ThorRenderContext
/// ```
///
/// The object is compared by identity, so the parent rebuilding with the
/// same object changes nothing here; `update` runs when what it read
/// changed (make the object `@Observable`) or the size did. `id` starts
/// over with a new node, as for `ThorCanvas`.
@View
public struct ThorCanvasRender<Context: ThorRenderContext> {
    let nodeID: Int
    let context: Context

    public init(context: Context, _viewID: ViewID = #viewID) {
        self.nodeID = 0
        self.context = context
        self._viewID = _viewID
    }

    public init<ID: Hashable>(id: ID, context: Context, _viewID: ViewID = #viewID) {
        self.nodeID = id.hashValue
        self.context = context
        self._viewID = _viewID
    }

    public var body: Never { bodyUnavailable() }
}

extension ThorCanvasRender: BuiltinView {
    func makeNode(_ build: inout BuildContext) -> ViewNode {
        let context = self.context
        return ViewNode(content: ThorCanvasContent(
            key: RenderNodeKey(path: build.path, identity: build.viewIdentity, id: nodeID),
            path: build.path,
            onInit: { canvas, size in context.onAppear(context: canvas, size: size) },
            render: { canvas, size in context.update(context: canvas, size: size) }
        ))
    }
}
