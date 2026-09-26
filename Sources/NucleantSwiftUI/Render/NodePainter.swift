//
//  NodePainter.swift
//  NucleantSwiftUI
//
//  How the automatic per-view nodes get their pixels. They are the engine's
//  copy-target images (`RenderNodeManager.ImageEntry`) and own no canvas —
//  a fresh ThorVG wg canvas costs ~70ms whatever its size, a VkImage
//  microseconds — so they are filled through one shared canvas node, the
//  painter: at the end of a pass every image whose content changed is drawn
//  into the painter side by side (tallest first on shelves, a granule of
//  gutter between, so what a paint's anti-aliasing puts past its bounds
//  lands in the gap) and told where in it its content lies; the engine's
//  frame draws the painter and then, in list order, copies each region out
//  into its image. Turning one knob then rasterizes that knob, and nothing
//  else on screen.
//
//  The painter is a canvas node in the engine's list — never composited,
//  ordered before the images, as a `.shader` layer's canvas is before its
//  effect. The window's width; the window's height, or taller for a pass
//  that needs it. What does not fit even a painter at its tallest waits
//  for the next frame.
//
//  An image whose list changed in a few commands is repainted only where
//  they touch (`damage`): the commands reaching into that rect, cut to it,
//  copied into that region of the image.
//

import NucleantVulkan
import Dispatch

@MainActor
final class NodePainter {
    typealias ImageEntry = RenderNodeManager.ImageEntry

    private unowned let engine: NucleantRenderEngine
    private let nodes: RenderNodeManager

    /// Backing-store pixels per point.
    var scale: Double = 1 {
        didSet {
            canvas?.renderer.scale = scale
        }
    }

    /// Rows the painter may grow to for one pass: wgpu's default limit on
    /// a 2D texture. Past it, what is left waits for the next frame.
    static let maxHeight = 8192

    /// The painter's canvas node, made on first use.
    private var canvas: RenderNodeManager.CanvasNode?
    private var warned = false

    /// Entries with `pending` content, painted at the end of the pass — or
    /// at the next frame, for what the painter had no room for.
    private var pending: [ImageEntry] = []

    /// The entries painted last, whose copies the frame records — until it
    /// has run, the painter holds their content and is not drawn over.
    private var painted: [ImageEntry] = []

    /// Whether this frame's painter content is spoken for: set by a paint,
    /// cleared by `frameWillDraw`.
    private var paintedThisFrame = false

    init(engine: NucleantRenderEngine, nodes: RenderNodeManager) {
        self.engine = engine
        self.nodes = nodes
    }

    // MARK: - Per image

    /// What `entry` should hold — `content` in the image's own coordinates,
    /// its origin at window pixel `origin`. Nothing to do when that is what
    /// it holds; otherwise painted at the end of the pass — the part that
    /// changed, when the rest can be kept.
    func schedule(_ entry: ImageEntry, content: DisplayList, origin: SIMD2<Double>) {
        if entry.content != content {
            // The same image with a few commands changed — a label in a
            // panel — repaints the part they touch, not the panel.
            if let held = entry.content, entry.pending == nil, entry.pixelOrigin == origin {
                entry.damage = damage(from: held, to: content, in: entry)
            } else {
                entry.damage = nil
            }
            if entry.pending == nil { pending.append(entry) }
            entry.pending = content
        }
        entry.pixelOrigin = origin
    }

    /// The part of the image that painting `new` over what `old` painted
    /// changes: the bounds of the commands that differ, found from the
    /// ends — a list that changed in one place shares a prefix and a
    /// suffix with what it was. `nil` when the whole image is to be
    /// painted: nothing to compare, or a rounded clip cuts through the
    /// damaged area, which the partial paint's rectangular clip could not
    /// reproduce.
    private func damage(from old: DisplayList, to new: DisplayList, in entry: ImageEntry) -> Rect? {
        let before = old.commands, after = new.commands
        let shorter = min(before.count, after.count)
        var prefix = 0
        while prefix < shorter, before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix, before[before.count - 1 - suffix] == after[after.count - 1 - suffix] {
            suffix += 1
        }
        var damage: Rect?
        for command in before[prefix..<(before.count - suffix)] {
            guard let bounds = command.paintBounds else { continue }
            damage = damage.map { $0.union(bounds) } ?? bounds
        }
        for command in after[prefix..<(after.count - suffix)] {
            guard let bounds = command.paintBounds else { continue }
            damage = damage.map { $0.union(bounds) } ?? bounds
        }
        guard var damage else {
            // Changed in ways that paint nothing — an empty image stays.
            return Rect(x: 0, y: 0, width: 0, height: 0)
        }
        let image = Rect(x: 0, y: 0, width: Double(entry.width) / scale, height: Double(entry.height) / scale)
        damage = damage.intersection(image)
        guard damage.width > 0, damage.height > 0 else { return Rect(x: 0, y: 0, width: 0, height: 0) }
        // Whole pixels, so the clip edge has no partial coverage.
        let x0 = (damage.minX * scale).rounded(.down) / scale
        let y0 = (damage.minY * scale).rounded(.down) / scale
        let x1 = (damage.maxX * scale).rounded(.up) / scale
        let y1 = (damage.maxY * scale).rounded(.up) / scale
        damage = Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        // Not worth a partial paint if it is nearly the whole image.
        if damage.width * damage.height > image.width * image.height * 0.6 { return nil }
        for command in after {
            guard let bounds = command.paintBounds, bounds.intersects(damage) else { continue }
            let radius: Double
            let clip: Rect?
            switch command {
            case .shape(let draw): radius = draw.clipCornerRadius; clip = draw.clip
            case .text(let draw): radius = draw.clipCornerRadius; clip = draw.clip
            case .image(let draw): radius = draw.clipCornerRadius; clip = draw.clip
            }
            if radius > 0, let clip, !clip.insetBy(radius).contains(damage) { return nil }
        }
        return damage
    }

    /// The pixels an entry's pending paint covers: its damaged part, or
    /// the whole image.
    private func paintSize(of entry: ImageEntry) -> (width: Int, height: Int) {
        guard let damage = entry.damage else { return (entry.width, entry.height) }
        return (Int((damage.width * scale).rounded()), Int((damage.height * scale).rounded()))
    }

    /// The region an entry's paint lands in, in image pixels.
    private func paintRegion(of entry: ImageEntry) -> (x: Int, y: Int, width: Int, height: Int) {
        let size = paintSize(of: entry)
        guard let damage = entry.damage else { return (0, 0, size.width, size.height) }
        return (Int((damage.minX * scale).rounded()), Int((damage.minY * scale).rounded()), size.width, size.height)
    }

    /// What to draw for an entry, with the paint region's corner at the
    /// origin: everything for a whole image; for a damaged part, the
    /// commands that reach into it, cut to it.
    private func paintList(of entry: ImageEntry) -> DisplayList {
        guard let pending = entry.pending else { return DisplayList() }
        guard let damage = entry.damage else { return pending }
        var commands: [DrawCommand] = []
        for command in pending.commands {
            guard let bounds = command.paintBounds, bounds.intersects(damage) else { continue }
            commands.append(command.clipped(to: damage))
        }
        return DisplayList(commands: commands).translated(dx: -damage.minX, dy: -damage.minY)
    }

    // MARK: - The pass

    /// Paint every image with new content: packed into the painter, the
    /// painter made tall enough for them, and each told where its content
    /// lies — for the frame, which draws the painter and copies each region
    /// out. Called at the end of the pass, after the nodes no view pulled
    /// were retired.
    func paintPending() {
        pending.removeAll { $0.pending == nil }
        // No frame ran since the last paint (the copies are still pending):
        // the painter is about to be drawn over, so those images are
        // painted again — whole, their content never arrived.
        let painterInUse = !painted.isEmpty
        for entry in painted where entry.node.pendingCopy != nil {
            entry.node.pendingCopy = nil
            entry.damage = nil
            if entry.pending == nil {
                entry.pending = entry.content
                pending.append(entry)
            }
            entry.content = nil
        }
        painted.removeAll(keepingCapacity: true)
        guard !pending.isEmpty else { return }
        let started = PerfTrace.isVerbose ? DispatchTime.now().uptimeNanoseconds : 0
        let entries = pending.sorted { a, b in
            let (aw, ah) = paintSize(of: a)
            let (bw, bh) = paintSize(of: b)
            return ah != bh ? ah > bh : aw > bw
        }
        pending.removeAll(keepingCapacity: true)
        let window = nodes.imageSize(for: Rect(origin: .zero, size: nodes.windowSize))
        let packed = pack(entries, width: window.width, maxHeight: Self.maxHeight)
        pending = packed.rest
        // The window's height unless the pass needs more — and back to it
        // afterwards, so a pass that paints one knob is not drawing a
        // canvas sized for the pass that painted everything.
        let granule = RenderNodeManager.granule
        let height = max(window.height, (packed.height + granule - 1) / granule * granule)
        guard let painter = painter(width: window.width, height: height), !packed.placed.isEmpty else {
            for entry in entries {
                entry.pending = nil
                entry.damage = nil
            }
            pending.removeAll()
            return
        }
        // The last frame's copies read the painter; the draw must not
        // overtake them.
        if painterInUse { engine.waitForPreviousFrame() }

        painter.renderer.render(packed: packed.placed.map { (list: paintList(of: $0.entry), x: $0.x, y: $0.y) })
        painter.node.dirty = true
        painter.container.needsRender = true
        // Before every image copying out of it, whatever their order.
        nodes.composite(painter.container, at: -1)
        // Read once: a tracked property of a generic node instantiates its
        // key path on every access.
        let source = painter.node.image
        var partial = 0
        for item in packed.placed {
            let entry = item.entry
            let region = paintRegion(of: entry)
            entry.node.pendingCopy = ImageCopy(
                source: source,
                sourceX: item.x, sourceY: item.y,
                x: region.x, y: region.y, width: region.width, height: region.height
            )
            entry.container.needsRender = true
            if entry.damage != nil { partial += 1 }
            entry.content = entry.pending
            entry.pending = nil
            entry.damage = nil
            PerfTrace.nodesDrawn += 1
        }
        painted = packed.placed.map(\.entry)
        paintedThisFrame = true
        PerfTrace.trace("painter: \(packed.placed.count) images (\(partial) partial), \(painter.width)x\(painter.height), in \(PerfTrace.millis(since: started))")
    }

    /// Once per frame, after any layout pass and before the engine draws:
    /// paint what the painter had no room for last time — unless this
    /// frame's pass painted, in which case the painter is spoken for.
    func frameWillDraw() {
        defer { paintedThisFrame = false }
        guard !paintedThisFrame, !pending.isEmpty else { return }
        paintPending()
    }

    /// Lay `entries` (tallest first) out on shelves `width` wide, with a
    /// granule between neighbours, and no taller than `maxHeight`; the
    /// rest is what did not fit. An entry with nothing to paint is done at
    /// once.
    private func pack(
        _ entries: [ImageEntry],
        width: Int,
        maxHeight: Int
    ) -> (placed: [(entry: ImageEntry, x: Int, y: Int)], height: Int, rest: [ImageEntry]) {
        let gutter = RenderNodeManager.granule
        var placed: [(entry: ImageEntry, x: Int, y: Int)] = []
        var rest: [ImageEntry] = []
        var x = 0, y = 0, shelf = 0
        for entry in entries {
            let (w, h) = paintSize(of: entry)
            guard w > 0, h > 0 else {
                // The change painted nothing: the image is right as it is.
                entry.content = entry.pending
                entry.pending = nil
                entry.damage = nil
                continue
            }
            guard w <= width else {
                entry.pending = nil
                entry.damage = nil
                continue
            }
            if x > 0, x + w > width {
                x = 0
                y += shelf + gutter
                shelf = 0
            }
            guard y + h <= maxHeight else {
                rest.append(entry)
                continue
            }
            placed.append((entry, x, y))
            x += w + gutter
            shelf = max(shelf, h)
        }
        return (placed, placed.isEmpty ? 0 : y + shelf, rest)
    }

    // MARK: - The painter's canvas

    /// The painter at `width × height` — retargeted when that changed, made
    /// on first use: a canvas node pulled from the manager like any other,
    /// composited nowhere.
    private func painter(width: Int, height: Int) -> RenderNodeManager.CanvasNode? {
        if let canvas {
            guard canvas.width != width || canvas.height != height else { return canvas }
            if nodes.resize(canvas, width: width, height: height) { return canvas }
            nodes.retire(canvas)
            self.canvas = nil
        }
        let started = PerfTrace.isVerbose ? DispatchTime.now().uptimeNanoseconds : 0
        guard let canvas = nodes.acquire(width: width, height: height) else {
            if !warned {
                warned = true
                nucleantFlushStandardOutput()
                nucleantLogError("NucleantSwiftUI: painter canvas (\(width)x\(height)) failed — per-view nodes are off\n")
            }
            return nil
        }
        canvas.container.compositesToWindow = false
        canvas.container.needsRender = false
        self.canvas = canvas
        PerfTrace.trace("painter canvas \(width)x\(height): \(PerfTrace.millis(since: started))")
        return canvas
    }

    /// Give the painter's canvas back to the manager; nothing is pending
    /// after this.
    func destroy() {
        pending.removeAll()
        painted.removeAll()
        if let canvas {
            nodes.retire(canvas)
            self.canvas = nil
        }
    }
}
