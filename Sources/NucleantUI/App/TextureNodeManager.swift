//
//  TextureNodeManager.swift
//  NucleantUI
//
//  The render nodes that belong to `TextureView`s, kept alive across the
//  momentary view structs — keyed, placed and retired the way
//  `RenderNodeManager` keeps its canvas nodes, but holding the engine's
//  `ExternalTextureNode`s, whose pixels are written by the view's source
//  rather than drawn by anything in the tree.
//
//  The sources are told what happened to their texture — appeared, resized,
//  gone — but never from inside the layout pass: a source reacting to a
//  resize (a browser told its new size) may well touch state views read, and
//  doing that mid-pass is how a view ends up rebuilt against half a layout.
//  The calls are queued as the pass finds them and made at `endPass`.
//

import NucleantVulkan

@MainActor
final class TextureNodeManager {

    /// One `TextureView`'s node, and what it knows of the view's source.
    @MainActor
    final class Entry {
        let texture: ViewTexture
        /// The source's identity — a view handed another object has a new
        /// source, which gets the texture while the old one is told it lost it.
        var sourceID: ObjectIdentifier
        var didChange: @MainActor (ViewTexture) -> Void
        var didDisappear: @MainActor (ViewTexture) -> Void
        /// Seen during the current pass. Anything not seen has left the tree.
        var used = true

        init(
            texture: ViewTexture,
            sourceID: ObjectIdentifier,
            didChange: @escaping @MainActor (ViewTexture) -> Void,
            didDisappear: @escaping @MainActor (ViewTexture) -> Void
        ) {
            self.texture = texture
            self.sourceID = sourceID
            self.didChange = didChange
            self.didDisappear = didDisappear
        }
    }

    private unowned let engine: NucleantRenderEngine
    /// For the pass's paint order, the scale and the image-size rule — the
    /// same ones every other per-view node follows.
    private unowned let renderNodes: RenderNodeManager

    private var entries: [RenderNodeKey: Entry] = [:]

    /// Retired this pass — out of the engine's list, GPU objects freed at
    /// `releasePending`, outside any recording.
    private var pendingDestroy: [Entry] = []

    /// Source callbacks found during the pass, made at `endPass`.
    private var notifications: [@MainActor () -> Void] = []

    init(engine: NucleantRenderEngine, renderNodes: RenderNodeManager) {
        self.engine = engine
        self.renderNodes = renderNodes
    }

    // MARK: - Layout-pass lifecycle

    func beginPass() {
        for entry in entries.values { entry.used = false }
    }

    /// The node for the `TextureView` at `key`, placed at `rect` (points) and
    /// cut to `clip`, in this pass's paint order — made if the view is new,
    /// resized if its frame outgrew the image or its scale changed. `nil`
    /// when a node could not be made (logged).
    @discardableResult
    func place(
        key: RenderNodeKey,
        rect: Rect,
        clip: Rect?,
        sourceID: ObjectIdentifier,
        didChange: @escaping @MainActor (ViewTexture) -> Void,
        didDisappear: @escaping @MainActor (ViewTexture) -> Void
    ) -> Entry? {
        let scale = renderNodes.scale
        let image = renderNodes.imageSize(for: rect)
        let entry: Entry
        var changed = false

        if let existing = entries[key] {
            entry = existing
            entry.used = true
            if entry.sourceID != sourceID {
                let lost = entry.didDisappear
                let texture = entry.texture
                notifications.append { lost(texture) }
                entry.sourceID = sourceID
                changed = true
            }
            entry.didChange = didChange
            entry.didDisappear = didDisappear
            let node = entry.texture.node
            if Int(node.width) != image.width || Int(node.height) != image.height {
                // Left at the old size on failure: the view keeps showing
                // what it had, cut by the scissor, rather than nothing.
                if engine.resizeExternalTextureNode(
                    node, id: entry.texture.container.id, width: image.width, height: image.height
                ) {
                    changed = true
                }
            }
            if entry.texture.size != rect.size || entry.texture.scale != scale {
                entry.texture.size = rect.size
                entry.texture.scale = scale
                changed = true
            }
        } else {
            let node: ExternalTextureNode<NucleantRenderNode>
            do {
                node = try engine.makeExternalTextureNode(width: image.width, height: image.height)
            } catch {
                nucleantFlushStandardOutput()
                nucleantLogError("NucleantUI: texture node (\(image.width)x\(image.height)) failed: \(error)\n")
                return nil
            }
            let container = NucleantRenderNode(
                id: Int.random(in: Int.min...Int.max),
                context: .externalTexture(node)
            )
            container.observeContext()
            engine.append(container)
            entry = Entry(
                texture: ViewTexture(node: node, container: container, engine: engine, size: rect.size, scale: scale),
                sourceID: sourceID,
                didChange: didChange,
                didDisappear: didDisappear
            )
            entries[key] = entry
            changed = true
        }

        position(entry.texture, rect: rect, clip: clip, scale: scale)
        renderNodes.composite(entry.texture.container, at: renderNodes.nextPaintOrder())

        if changed {
            // The entry's closure at the time of the call, not this one: a
            // later pass in the same frame may have replaced it.
            notifications.append { [entry] in entry.didChange(entry.texture) }
        }
        return entry
    }

    /// Point the node's slot at the frame: origin snapped to a whole pixel so
    /// texels land on pixels, the image at its own size, and a scissor that
    /// cuts it to the frame and to whatever clips the view — the image is
    /// bigger than the frame by up to a granule, and that slack is nobody's.
    private func position(_ texture: ViewTexture, rect: Rect, clip: Rect?, scale: Double) {
        let x = (rect.minX * scale).rounded(.down)
        let y = (rect.minY * scale).rounded(.down)
        texture.container.compositeRect = SIMD4(x, y, Double(texture.node.width), Double(texture.node.height))
        let visible = clip.map { rect.intersection($0) } ?? rect
        let minX = (visible.minX * scale).rounded(.down)
        let minY = (visible.minY * scale).rounded(.down)
        let maxX = (visible.maxX * scale).rounded(.up)
        let maxY = (visible.maxY * scale).rounded(.up)
        texture.container.compositeScissor = SIMD4(minX, minY, max(0, maxX - minX), max(0, maxY - minY))
    }

    /// Retire the nodes no view placed this pass, then tell the sources
    /// everything the pass did to their textures.
    func endPass() {
        for (key, entry) in entries where !entry.used {
            retire(entry)
            entries[key] = nil
        }
        let calls = notifications
        notifications.removeAll()
        for call in calls { call() }
    }

    /// Out of the engine now; the texture refuses writes from here on, and
    /// its source hears it is gone. Freed at `releasePending`.
    private func retire(_ entry: Entry) {
        let id = entry.texture.container.id
        engine.nodes.removeAll { $0.id == id }
        engine.invalidateComposite(id: id)
        entry.texture.isAttached = false
        let lost = entry.didDisappear
        let texture = entry.texture
        notifications.append { lost(texture) }
        pendingDestroy.append(entry)
    }

    /// Free everything retired since the last call — at the top of a frame,
    /// before anything is recorded.
    func releasePending() {
        guard !pendingDestroy.isEmpty else { return }
        let retired = pendingDestroy
        pendingDestroy.removeAll()
        for entry in retired {
            entry.texture.node.destroyResources(engine)
        }
    }

    func destroyAll() {
        for entry in entries.values { retire(entry) }
        entries.removeAll()
        let calls = notifications
        notifications.removeAll()
        for call in calls { call() }
        releasePending()
    }
}
