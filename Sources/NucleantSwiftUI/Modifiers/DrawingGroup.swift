//
//  DrawingGroup.swift
//  NucleantSwiftUI
//
//  `.drawingGroup()` — a view with a render node of its own.
//

extension View {

    /// Rasterizes this view into an image of its own — a render node —
    /// composited into its frame, instead of drawing it into the enclosing
    /// canvas.
    ///
    /// The node is repainted only when what the view draws changes: a state
    /// change elsewhere on screen leaves its image alone, and a state change
    /// inside it leaves the rest of the screen alone. Moving it (a scroll)
    /// costs nothing; resizing it retargets the canvas at a new image. The
    /// view keeps its layout, its input and its state — only where its
    /// pixels go changes.
    ///
    /// What is worth grouping: a subtree that changes often while the rest
    /// does not (a meter, a list of faders), or one that is expensive to
    /// rasterize and rarely changes. Every group costs an image the size of
    /// its frame, and a canvas the first time one appears; a `Text` in a
    /// hot row is not worth one.
    ///
    /// As for `.shader(_:)`, the node composites as a rectangle: clip
    /// *inside* the group (`.cornerRadius(10).drawingGroup()`), and a
    /// rotation outside it is cut at the image's edge. Whatever the
    /// enclosing view paints *after* this one and over it — a later
    /// sibling in a `ZStack` — is put in an image ordered after the node.
    ///
    /// A view that reads state gets a node of its own without this (see
    /// `RenderBoundaryContent`); a group is for a subtree that should be
    /// one image regardless, and owns a ThorVG canvas for it.
    public func drawingGroup() -> some View {
        _ModifierView(content: self, key: ["drawingGroup"] as [AnyHashable]) { context in
            DrawingGroupContent(key: RenderNodeKey(path: context.path, identity: context.viewIdentity))
        }
    }
}

/// The node behind `.drawingGroup()`: lays its child out exactly as it would
/// be otherwise, but routes what the child draws into a display list of its
/// own — in the view's own coordinates — and hands that to its render node
/// instead of the enclosing canvas. The child's frames are still written, so
/// hit testing is untouched.
struct DrawingGroupContent: NodeContent {
    let key: RenderNodeKey

    /// The image is the frame; what the subtree draws outside it is cut.
    var clipsChildren: Bool { true }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        guard let child = node.singleChild else { return }
        guard !context.flattensRenderNodes, rect.width > 0, rect.height > 0,
              let host = ShaderHost.current
        else {
            child.place(in: rect, proposal: proposal, context: context, into: &list)
            return
        }
        // The node holds the whole view; what a container outside it clips
        // away is cut at the composite instead. The inherited opacity and
        // transform stay — they are part of how the view looks.
        var inner = context
        inner.clip = nil
        inner.clipCornerRadius = 0
        inner.nodeClip = context.compositeClip
        var content = DisplayList()
        child.place(in: rect, proposal: proposal, context: inner, into: &content)
        guard !content.isEmpty else { return }   // draws nothing: no node
        let clip = context.compositeClip
        // A view bigger than the window gets an image of what is on screen
        // — its frame cut to its container's clip and the window — with the
        // content shifted so that part's corner lands at the image's origin.
        // Unlike a node that fits, a scroll then changes what the image
        // holds and repaints it, as the window canvas would have.
        var visible = rect
        let windowSize = host.renderNodes.windowSize
        if rect.width > windowSize.width || rect.height > windowSize.height {
            let window = Rect(origin: .zero, size: windowSize)
            visible = rect.intersection(clip.map { $0.intersection(window) } ?? window)
            guard visible.width > 0, visible.height > 0 else { return }
        }
        guard let node = host.renderNodes.canvasNode(for: key, rect: visible) else { return }
        node.place(rect: visible, clip: clip, scale: host.renderNodes.scale)
        host.renderNodes.composite(node.container, at: host.renderNodes.nextPaintOrder())
        host.boundaries.noteNested(at: list.commands.count, rect: clip.map { visible.intersection($0) } ?? visible)
        // Local to the image, so a view that merely moved compares equal to
        // what its node already holds.
        node.render(content.translated(dx: -visible.minX, dy: -visible.minY), at: key.path)
    }
}
