//
//  PaintBounds.swift
//  NucleantSwiftUI
//
//  How big a command can paint. An automatic render node's image is the
//  bounds of what its view actually drew — not the view's frame, which a
//  glow, a shadow stroke or an `.offset` overrun freely — so every command
//  has to say, conservatively, where its pixels can land. Over-estimating
//  costs a few transparent pixels; under-estimating cuts the drawing.
//

extension Path {
    /// The box the elements lie in — control points included, which bounds
    /// the curve they control.
    var boundingBox: Rect? {
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        func include(_ p: Point) {
            if p.x < minX { minX = p.x }
            if p.x > maxX { maxX = p.x }
            if p.y < minY { minY = p.y }
            if p.y > maxY { maxY = p.y }
        }
        for element in elements {
            switch element {
            case .move(let p), .line(let p):
                include(p)
            case .cubic(let c1, let c2, let end):
                include(c1); include(c2); include(end)
            case .close:
                break
            case .rect(let r, _, _):
                include(Point(x: r.minX, y: r.minY)); include(Point(x: r.maxX, y: r.maxY))
            case .ellipse(let c, let rx, let ry):
                include(Point(x: c.x - rx, y: c.y - ry)); include(Point(x: c.x + rx, y: c.y + ry))
            }
        }
        guard minX <= maxX, minY <= maxY else { return nil }
        return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

extension Rect {
    /// The smallest rect holding both.
    func union(_ other: Rect) -> Rect {
        let x0 = Swift.min(minX, other.minX)
        let y0 = Swift.min(minY, other.minY)
        let x1 = Swift.max(maxX, other.maxX)
        let y1 = Swift.max(maxY, other.maxY)
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Grown by `amount` on every side.
    func expanded(by amount: Double) -> Rect {
        Rect(x: minX - amount, y: minY - amount, width: width + 2 * amount, height: height + 2 * amount)
    }

    /// Whether any area is shared — touching edges do not count.
    func intersects(_ other: Rect) -> Bool {
        minX < other.maxX && other.minX < maxX && minY < other.maxY && other.minY < maxY
    }

    /// The box around this rect's corners under `transform`.
    func applying(_ transform: Transform) -> Rect {
        guard !transform.isIdentity else { return self }
        let corners = [
            transform.apply(to: Point(x: minX, y: minY)),
            transform.apply(to: Point(x: maxX, y: minY)),
            transform.apply(to: Point(x: minX, y: maxY)),
            transform.apply(to: Point(x: maxX, y: maxY)),
        ]
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return Rect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}

extension DrawCommand {
    /// Where this command can put pixels, in the list's coordinates — after
    /// its transform, inside its clip. `nil` when it paints nothing.
    var paintBounds: Rect? {
        let box: Rect
        let transform: Transform
        let clip: Rect?
        switch self {
        case .shape(let draw):
            // `Color.clear` is a shape with nothing visible — the renderer
            // skips it, and so does the image it would otherwise size.
            let fills = draw.fill.map { !$0.isClear } ?? false
            let strokes = (draw.stroke.map { !$0.isClear } ?? false) && draw.strokeStyle.lineWidth > 0
            guard fills || strokes else { return nil }
            // The path's own box, not just `bounds`: a custom `Shape` may
            // draw past the rect it was given. A stroke reaches half its
            // width outside the path, and a miter join up to the miter
            // limit (ThorVG's default is 4) times that.
            var rect = draw.path.boundingBox.map { $0.union(draw.bounds) } ?? draw.bounds
            if strokes {
                let reach = draw.strokeStyle.lineWidth * (draw.strokeStyle.lineJoin == .miter ? 2 : 0.5)
                rect = rect.expanded(by: reach)
            }
            box = rect
            transform = draw.transform
            clip = draw.clip
        case .text(let draw):
            // Glyphs overshoot the layout box a little — descenders, an
            // italic shear — so give them room in proportion to the size.
            box = draw.frame.expanded(by: draw.font.size * 0.5)
            transform = draw.transform
            clip = draw.clip
        case .image(let draw):
            box = draw.frame
            transform = draw.transform
            clip = draw.clip
        }
        // Anti-aliasing touches the pixel outside the edge.
        var result = box.applying(transform).expanded(by: 1)
        if let clip {
            result = result.intersection(clip)
        }
        guard result.width > 0, result.height > 0 else { return nil }
        return result
    }
}

extension DisplayList {
    init(commands: [DrawCommand]) {
        self.init()
        for command in commands { append(command) }
    }

    /// The box every command in the list can paint in, or `nil` for a list
    /// that paints nothing.
    var paintBounds: Rect? {
        var result: Rect?
        for command in commands {
            guard let bounds = command.paintBounds else { continue }
            result = result.map { $0.union(bounds) } ?? bounds
        }
        return result
    }
}

extension DrawCommand {
    /// The same command cut to `rect` as well as to its own clip. A rounded
    /// clip that holds `rect` entirely is replaced by it — the rounding lies
    /// outside; one that does not is the caller's problem to avoid.
    func clipped(to rect: Rect) -> DrawCommand {
        func narrowed(_ clip: Rect?, _ radius: Double) -> (Rect, Double) {
            guard let clip else { return (rect, 0) }
            if radius > 0, clip.insetBy(radius).contains(rect) { return (rect, 0) }
            return (clip.intersection(rect), radius)
        }
        switch self {
        case .shape(var draw):
            (draw.clip, draw.clipCornerRadius) = narrowed(draw.clip, draw.clipCornerRadius)
            return .shape(draw)
        case .text(var draw):
            (draw.clip, draw.clipCornerRadius) = narrowed(draw.clip, draw.clipCornerRadius)
            return .text(draw)
        case .image(var draw):
            (draw.clip, draw.clipCornerRadius) = narrowed(draw.clip, draw.clipCornerRadius)
            return .image(draw)
        }
    }
}

extension Rect {
    /// Whether `other` lies entirely inside.
    func contains(_ other: Rect) -> Bool {
        other.minX >= minX && other.maxX <= maxX && other.minY >= minY && other.maxY <= maxY
    }
}
