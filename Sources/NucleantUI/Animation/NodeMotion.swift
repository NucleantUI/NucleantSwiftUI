//
//  NodeMotion.swift
//  NucleantUI
//
//  Animation at the level of placed nodes.
//
//  Geometry: every node remembers the rect layout last gave it. When an
//  animated commit pass gives it a different one, it starts a
//  *displacement* — how far the new rect is from where the node was
//  showing — and each pass shows it at the rect layout gives *now* plus
//  that displacement, shrinking to nothing. Additive, so it converges on
//  whatever layout says even if that moves again mid-way.
//
//  What moves on screen is the leaves — shapes, colors, text, images —
//  each from its own old rect to its own new one, all on one curve.
//  A container is laid out at the new layout at once, and only its
//  *frame* (what hit testing and a clip see) is shown in between: were its
//  children laid out inside an in-between box, they would be squeezed
//  into a layout that is neither the old one nor the new one — a row of
//  buttons wrapping their labels — and a child would ride along with its
//  parent's motion on top of its own.
//
//  A leaf that fills its box (a shape, a color) is drawn at the sizes in
//  between; text keeps its new size and only its center travels, since it
//  would otherwise reflow at every frame.
//
//  Transitions: a structural container (`if`, `switch`, `ForEach`) notes
//  which of its children are new and which it lost. A new one draws under
//  its insertion effect until it arrives; a lost one — a ghost — is kept
//  among the container's children, out of layout and out of hit testing,
//  and drawn where it last stood under its removal effect until it is gone.
//

/// A node's animation in flight, carried over when its view is rebuilt.
struct NodeMotion {
    struct Displacement {
        /// How far the center is from where layout puts it, and — for a
        /// node that animates its size — how much bigger it is.
        var dx: Double, dy: Double, dw: Double, dh: Double
        let run: AnimationRun

        /// What is left of it at `now`, and whether it has run out.
        @MainActor func remaining(at now: Double) -> (fraction: Double, isFinished: Bool) {
            let progress = run.progress(at: now)
            return (1 - progress.fraction, progress.isFinished)
        }
    }

    struct Insertion {
        let transition: AnyTransition
        let run: AnimationRun
    }

    var displacement: Displacement?
    var insertion: Insertion?
}

/// A removed node still drawing its exit.
struct NodeRemoval {
    let transition: AnyTransition
    let run: AnimationRun
    /// Where, how, and under what transform it last stood.
    let frame: Rect
    let proposal: ProposedSize
    let transform: Transform
    /// The container it was removed from, and the slot it held there.
    let container: [Int]
    let index: Int
    /// The frame it was last drawn in, so it is drawn once per pass.
    var drawnInFrame = 0
    var isFinished = false
}

extension ViewNode {

    /// Given the rect layout chose, the node's frame as shown now and the
    /// rect its content is placed in — the same for a leaf, the layout's
    /// own for a container (see the file comment) — with any insertion
    /// effect applied to both and to `context`.
    func animate(
        _ target: Rect,
        context: inout DrawContext,
        store: AnimationStore
    ) -> (frame: Rect, content: Rect) {
        defer { layoutRect = target }

        if store.isCommitPass, let animation = context.animation, let last = layoutRect, last != target {
            let shown = displaced(last, at: store.now)
            let resizes = content.animatesSize
            let displacement = NodeMotion.Displacement(
                dx: shown.midX - target.midX,
                dy: shown.midY - target.midY,
                dw: resizes ? shown.width - target.width : 0,
                dh: resizes ? shown.height - target.height : 0,
                run: AnimationRun(animation, start: store.now)
            )
            let isStill = abs(displacement.dx) < 0.01 && abs(displacement.dy) < 0.01
                && abs(displacement.dw) < 0.01 && abs(displacement.dh) < 0.01
            motion.displacement = isStill ? nil : displacement
            if !isStill { store.noteStarted(displacement.run) }
        }

        var frame = target
        if let displacement = motion.displacement {
            let remaining = displacement.remaining(at: store.now)
            if remaining.isFinished {
                motion.displacement = nil
            } else {
                frame = displaced(target, at: store.now)
                store.requestFrame()
            }
        }
        var content = children.isEmpty ? frame : target

        if let insertion = motion.insertion {
            let progress = insertion.run.progress(at: store.now)
            if progress.isFinished {
                motion.insertion = nil
            } else {
                let effect = TransitionEffect(
                    insertion.transition, isInsertion: true, amount: 1 - progress.fraction, size: target.size
                )
                effect.apply(to: &frame, context: &context)
                content = content.offsetBy(dx: effect.offset.x, dy: effect.offset.y)
                store.requestFrame()
            }
        }
        return (frame, content)
    }

    /// `rect` moved by whatever is left of the displacement at `now`.
    private func displaced(_ rect: Rect, at now: Double) -> Rect {
        guard let displacement = motion.displacement else { return rect }
        let remaining = displacement.remaining(at: now)
        guard !remaining.isFinished else { return rect }
        let k = remaining.fraction
        let width = max(0, rect.width + displacement.dw * k)
        let height = max(0, rect.height + displacement.dh * k)
        return Rect(
            x: rect.midX + displacement.dx * k - width / 2,
            y: rect.midY + displacement.dy * k - height / 2,
            width: width,
            height: height
        )
    }


    /// Take over a rebuilt predecessor's motion: where it last stood and
    /// what it was in the middle of.
    ///
    /// Not into a group: a group is never a box of its own, and one that
    /// replaces a view (an `if` whose other branch is still exiting) would
    /// otherwise slide its new contents over from where the old stood.
    func inheritMotion(from old: ViewNode) {
        guard layoutRect == nil, !content.isTransparent else { return }
        layoutRect = old.layoutRect
        motion = old.motion
    }

    // MARK: - Ghosts

    /// Draw the removed children still exiting — directly held, or held by
    /// a group dissolved into this node's layout.
    func placeGhosts(context: DrawContext, store: AnimationStore, into list: inout DisplayList) {
        for child in children {
            if child.removal != nil {
                child.placeRemoved(context: context, store: store, into: &list)
            } else if child.content.isTransparent {
                child.placeGhosts(context: context, store: store, into: &list)
            }
        }
    }

    private func placeRemoved(context: DrawContext, store: AnimationStore, into list: inout DisplayList) {
        guard var removal, !removal.isFinished, removal.drawnInFrame != store.frame else { return }
        removal.drawnInFrame = store.frame
        let progress = removal.run.progress(at: store.now)
        if progress.isFinished {
            removal.isFinished = true
            self.removal = removal
            store.removeGhost(container: removal.container, index: removal.index)
            return
        }
        self.removal = removal
        store.requestFrame()

        var rect = removal.frame
        var inner = context
        inner.transform = removal.transform
        // Frozen where it stood: nothing inside starts or follows motion.
        inner.freezesMotion = true
        TransitionEffect(removal.transition, isInsertion: false, amount: progress.fraction, size: rect.size)
            .apply(to: &rect, context: &inner)
        place(in: rect, proposal: removal.proposal, context: inner, into: &list)
    }
}

// MARK: - Structural containers

extension BuildContext {

    /// Whether the child about to be built in slot `index` is new here.
    func isNewChild(at index: Int) -> Bool {
        records.candidate(at: path + [index]) == nil
    }

    /// The children of an `if`, a `switch` or a `ForEach`, with this
    /// pass's arrivals and departures animated: `built` is every child
    /// just built, by slot, with whether it was new. Returns the node's
    /// children — `built`, then any removed ones still exiting.
    ///
    /// Only a container that stood here before transitions anything: one
    /// built from scratch has nothing arriving *into* it.
    func structuralChildren(_ built: [(index: Int, node: ViewNode, isNew: Bool)]) -> [ViewNode] {
        var children = built.map(\.node)
        guard isReplacingStandingView else { return children }

        let animation = transaction.animation
        if let animation {
            for child in built where child.isNew {
                let transition = child.node.transitionTrait ?? .opacity
                guard !transition.isIdentity else { continue }
                let run = AnimationRun(transition.animation ?? animation, start: animations.now)
                child.node.motion.insertion = NodeMotion.Insertion(transition: transition, run: run)
                animations.noteStarted(run)
            }

            let builtSlots = Set(built.map(\.index))
            for (index, node) in records.leftoverChildren(under: path) where !builtSlots.contains(index) {
                // Never placed (a dissolved group), or already on its way out.
                guard node.removal == nil, node.frame.width > 0 || node.frame.height > 0 else { continue }
                let transition = node.transitionTrait ?? .opacity
                guard !transition.isIdentity else { continue }
                let run = AnimationRun(transition.animation ?? animation, start: animations.now)
                node.removal = NodeRemoval(
                    transition: transition,
                    run: run,
                    frame: node.frame,
                    proposal: node.proposal,
                    transform: node.transform,
                    container: path,
                    index: index
                )
                animations.noteStarted(run)
                animations.addGhost(node, container: path, index: index)
            }
        }
        children += animations.ghosts(in: path, excluding: Set(built.map(\.index)))
        return children
    }
}
