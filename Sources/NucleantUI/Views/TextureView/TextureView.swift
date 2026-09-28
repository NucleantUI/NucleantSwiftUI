//
//  TextureView.swift
//  NucleantUI
//
//  A view whose pixels come from a `TextureSource` — written into its own
//  GPU texture from outside the view tree, composited into its frame.
//

/// A view that shows what its `source` writes into it.
///
/// ```swift
/// TextureView(source: player)
///     .frame(width: 640, height: 360)
/// ```
///
/// The view gets a texture of its own, the size of its frame in pixels, and
/// tells `source` about it (`textureDidChange`) — again whenever the frame
/// or the display scale changes, and `textureDidDisappear` when the view
/// leaves the tree. The source writes frames into the texture whenever it has
/// them; nothing in the view tree has to rebuild for a new frame to show.
///
/// Pointer and key input over the view goes to the source as well
/// (`TextureSource.textureInput`), so a source that is interactive — a web
/// page — can be driven through it.
///
/// It takes whatever space it is offered, so give it a `.frame`. `id` is the
/// "start over" handle, as for `ThorCanvas`: a different value is a new
/// texture.
@View
public struct TextureView<Source: TextureSource> {
    let nodeID: Int
    let source: Source

    public init(source: Source, _viewID: ViewID = #viewID) {
        self.nodeID = _viewID.hash
        self.source = source
        self._viewID = _viewID
    }

    public init<ID: Hashable>(id: ID, source: Source, _viewID: ViewID = #viewID) {
        self.nodeID = id.hashValue
        self.source = source
        self._viewID = _viewID
    }

    public var body: Never { bodyUnavailable() }
}

extension TextureView: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        let source = self.source
        let send: @MainActor (TextureInputEvent) -> Void = { source.textureInput($0) }
        return ViewNode(content: TextureContent(
            key: RenderNodeKey(path: context.path, identity: context.viewIdentity, id: nodeID),
            sourceID: ObjectIdentifier(source),
            didChange: { source.textureDidChange($0) },
            didDisappear: { source.textureDidDisappear($0) },
            input: TextureInputTarget(path: context.path, send: send),
            focus: FocusTarget(
                path: context.path,
                isEnabled: context.environment.isEnabled,
                onFocusChange: { send(.focusChanged($0)) },
                onKeyDown: { send(.keyDown(keyCode: $0.keyCode, characters: $0.characters, modifiers: $0.modifiers)) },
                onKeyUp: { send(.keyUp(keyCode: $0.keyCode, characters: $0.characters, modifiers: $0.modifiers)) },
                editCommands: Set(EditCommand.allCases),
                onEditCommand: { send(.edit($0)) }
            ),
            hitTarget: HitTarget(
                isEnabled: context.environment.isEnabled,
                minimumDragDistance: 0,
                onPress: { send(.pointerDown($0)) },
                onRelease: { send(.pointerUp($0, inside: $1)) },
                onScroll: { send(.scroll(dx: $0.x, dy: $0.y)) },
                onDragChanged: { send(.pointerDragged($0.location)) }
            )
        ))
    }
}

/// Where the hover moves a `TextureView` takes are sent — found by the same
/// back-to-front walk as `hoverTarget`, and compared by path, since a
/// rebuild replaces the object. (Keys come through its `FocusTarget`.)
@MainActor
final class TextureInputTarget {
    let path: [Int]
    let send: @MainActor (TextureInputEvent) -> Void

    init(path: [Int], send: @escaping @MainActor (TextureInputEvent) -> Void) {
        self.path = path
        self.send = send
    }
}

/// Reserves the view's texture node at `place` and hands the source its
/// callbacks. Emits no draw commands of its own — its pixels arrive through
/// the engine, not the canvas.
struct TextureContent: NodeContent {
    let key: RenderNodeKey
    let sourceID: ObjectIdentifier
    let didChange: @MainActor (ViewTexture) -> Void
    let didDisappear: @MainActor (ViewTexture) -> Void
    let input: TextureInputTarget
    let focus: FocusTarget
    let hitTarget: HitTarget?

    var textureInput: TextureInputTarget? { input }
    var focusTarget: FocusTarget? { focus }

    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        proposal.replacingUnspecifiedDimensions()
    }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        guard rect.width > 0, rect.height > 0, let host = ShaderHost.current else { return }
        let clip = context.compositeClip
        host.textures.place(
            key: key,
            rect: rect,
            clip: clip,
            sourceID: sourceID,
            didChange: didChange,
            didDisappear: didDisappear
        )
        host.boundaries.noteNested(at: list.commands.count, rect: clip.map { rect.intersection($0) } ?? rect)
    }
}
