//
//  DragSession.swift
//  NucleantSwiftUI
//
//  One drag, from the moment the pointer has moved far enough on a
//  `.draggable` to the release. Owned by `ViewHost`, which feeds it pointer
//  positions and asks it to paint the preview after each layout pass.
//

/// A drag in flight: what it carries, what it looks like, where it is, and
/// which destination it is over.
@MainActor
final class DragSession {

    let payload: TransferPayload
    private let preview: Preview

    /// Where the pointer was when the drag began, in window coordinates —
    /// the snapshot preview is drawn where the view was, moved by however
    /// far the pointer has come since.
    let origin: Point
    var location: Point

    /// The destination the pointer is over, if it could take the payload.
    /// Held by path as well as object: a rebuild replaces the object (see
    /// `DropTarget.path`).
    private(set) var target: Hit<DropTarget>?

    /// How the preview is painted — never fully opaque, so what it is over
    /// still shows through.
    private static let previewOpacity = 0.8

    private enum Preview {
        /// The dragged view exactly as it was last drawn, clip removed.
        case snapshot([DrawCommand])
        /// A view of the caller's, built for the drag, centred on the pointer.
        case view(ViewNode, size: Size, environment: EnvironmentValues)
    }

    init(source: Hit<DragSource>, origin: Point) {
        payload = source.value.makePayload()
        self.origin = origin
        location = origin

        if let makePreview = source.value.makePreview {
            // A tree of its own, with its own state and rebuild records —
            // the preview is not part of the host's tree and must not file
            // anything under the host's paths. The path prefix keeps any
            // shader slot it claims apart from the tree's.
            var context = BuildContext(
                environment: source.value.environment,
                store: StateStore(),
                effects: EffectQueue(),
                records: RebuildRecords()
            )
            context.path = [-1]
            let node = buildNode(makePreview(), &context)
            let size = node.sizeThatFits(.unspecified)
            preview = .view(node, size: size, environment: source.value.environment)
        } else {
            // Place the node again, into a list nobody renders, under the
            // context it was last placed with — same rect, same transform,
            // same opacity — but unclipped, so a card half under the edge of
            // its scroll view is dragged whole.
            var context = source.value.context
            context.clip = nil
            context.clipCornerRadius = 0
            var list = DisplayList()
            source.node.place(in: source.frame, proposal: source.value.proposal, context: context, into: &list)
            preview = .snapshot(list.commands)
        }
    }

    // MARK: - The destination under the pointer

    /// Move to `point` and find the destination there. Tells a destination
    /// being left and one being entered, and answers whether that changed.
    @discardableResult
    func move(to point: Point, in root: ViewNode?) -> Bool {
        location = point
        let found = root?.hitTest(point) { node -> DropTarget? in
            guard let target = node.content.dropTarget, target.accepts(payload) else { return nil }
            return target
        }
        guard found?.value.path != target?.value.path else {
            target = found
            return false
        }
        target?.value.setTargeted(false)
        target = found
        found?.value.setTargeted(true)
        return true
    }

    /// Release at `point`: hand the payload to the destination there, if
    /// any. Whether it was taken.
    func drop(at point: Point, in root: ViewNode?) -> Bool {
        move(to: point, in: root)
        guard let target else { return false }
        let local = target.localPoint(for: point) ?? target.localPoint
        // Told "no longer over" before the drop lands, as SwiftUI does — so a
        // highlight is cleared before the action's own state change.
        target.value.setTargeted(false)
        let accepted = target.value.perform(payload, local)
        self.target = nil
        return accepted
    }

    // MARK: - The preview

    /// Paint the preview at the current location, over everything.
    func draw(into list: inout DisplayList, colorScheme: ColorScheme) {
        var faded = DrawContext(colorScheme: colorScheme)
        faded.opacity = Self.previewOpacity
        switch preview {
        case .snapshot(let commands):
            let dx = location.x - origin.x
            let dy = location.y - origin.y
            for command in commands {
                list.append(command.translated(dx: dx, dy: dy).faded(under: faded))
            }
        case .view(let node, let size, _):
            let rect = Rect(
                x: location.x - size.width / 2,
                y: location.y - size.height / 2,
                width: size.width,
                height: size.height
            )
            node.place(in: rect, proposal: ProposedSize(size), context: faded, into: &list)
        }
    }
}

extension DrawCommand {

    /// The same command drawn `(dx, dy)` further along. A command with a
    /// transform is moved *after* it — a rotated card must not be re-rotated
    /// about the old anchor — which is the conjugated transform.
    func translated(dx: Double, dy: Double) -> DrawCommand {
        guard dx != 0 || dy != 0 else { return self }
        func moved(_ transform: Transform) -> Transform {
            guard !transform.isIdentity else { return transform }
            return Transform.translation(x: dx, y: dy)
                .concatenating(transform)
                .concatenating(Transform.translation(x: -dx, y: -dy))
        }
        switch self {
        case .shape(var draw):
            draw.path = draw.path.offsetBy(dx: dx, dy: dy)
            draw.bounds = draw.bounds.offsetBy(dx: dx, dy: dy)
            draw.clip = draw.clip?.offsetBy(dx: dx, dy: dy)
            draw.transform = moved(draw.transform)
            return .shape(draw)
        case .text(var draw):
            draw.frame = draw.frame.offsetBy(dx: dx, dy: dy)
            draw.clip = draw.clip?.offsetBy(dx: dx, dy: dy)
            draw.transform = moved(draw.transform)
            return .text(draw)
        case .image(var draw):
            draw.frame = draw.frame.offsetBy(dx: dx, dy: dy)
            draw.clip = draw.clip?.offsetBy(dx: dx, dy: dy)
            draw.transform = moved(draw.transform)
            return .image(draw)
        }
    }

    /// The same command under `context`'s opacity. Its colors were resolved
    /// when it was first drawn, so the scheme in `context` changes nothing.
    func faded(under context: DrawContext) -> DrawCommand {
        guard context.opacity < 1 else { return self }
        switch self {
        case .shape(var draw):
            draw.fill = draw.fill.map(context.resolve)
            draw.stroke = draw.stroke.map(context.resolve)
            return .shape(draw)
        case .text(var draw):
            draw.color = context.resolve(draw.color)
            return .text(draw)
        case .image(var draw):
            draw.opacity *= context.opacity
            return .image(draw)
        }
    }
}
